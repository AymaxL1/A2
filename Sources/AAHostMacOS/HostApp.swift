// AAHostMacOS —— 宿主 GUI 入口。菜单栏常驻(accessory)+ 能力注册表 + UDS server。
//
// 入口用 @main @MainActor struct(顶层代码非 MainActor 上下文,不能在 main.swift 顶层构造 @MainActor 对象;S1/S2 已验证)。
// socket 路径读 Contracts 常量(AAPaths),父目录启动时自建,旧 socket 由 server bind 前 unlink。
//
// dangerous 确认异步入主线程队列；UDS 立即返回 pending/requestId，GUI 决定由 result 查询读取。

import AppKit
import AAContracts
import AAHostRuntime
import AAPluginSDK
import PluginProxy

/// dangerous 确认的 test-only 自动化档位(读环境变量 `AA_CONFIRM_AUTO`)。
///
/// 仅在 `AA_TESTING` 编译中存在；生产二进制不包含读取该环境变量的代码。
#if AA_TESTING
private enum AutoConfirm {
    case approve       // AA_CONFIRM_AUTO=approve → 回调直接返 true(不弹窗)
    case deny          // AA_CONFIRM_AUTO=deny    → 回调直接返 false(不弹窗)
    case interactive   // 未设 → 走真 NSAlert(生产缺省)

    /// 每次确认时按需读取(进程级环境变量,后台线程读取安全)。
    static func current() -> AutoConfirm {
        switch ProcessInfo.processInfo.environment["AA_CONFIRM_AUTO"] {
        case "approve": return .approve
        case "deny":    return .deny
        default:        return .interactive
        }
    }
}
#endif

/// 宿主日志助手:每行后 fflush(stdout 重定向到文件时为块缓冲,不 flush 会看不到实时日志)。
/// 串行化避免多线程 print 交错(accept/handle 都在后台线程)。
private let hostLogQueue = DispatchQueue(label: "aa.host.log")
func hostLog(_ msg: String) {
    hostLogQueue.sync {
        print("[AAHost] \(msg)")
        fflush(stdout)
    }
}

/// 启动期致命错误:打印明确 stderr + 非零退出。宿主宁可快速失败,也不「状态栏活着却无 UDS 监听」带病常驻
/// (那样 E2E 只能靠超时暴露)。退出码 1=启动失败。
func hostFatal(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("[AAHost] 致命错误: \(msg)\n".utf8))
    exit(1)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // registry 在 applicationDidFinishLaunching 里构造(需注入引用 self 的确认回调,故不能在属性初始化时建)。
    var registry: Registry!
    var server: UDSServer!
    var statusItem: NSStatusItem!
    /// 代理插件(V1 内封栈:宿主静态装配,不搞动态加载)。持有内核句柄,随宿主启停。
    var proxyPlugin: ProxyPlugin!
    /// test/dev seam:SIGUSR1 → 优雅退出的 DispatchSource(exercise applicationWillTerminate→reclaimKernel→terminate 完整回收路径)。
    var gracefulQuitSource: DispatchSourceSignal?
    private struct ConfirmationRequest {
        let descriptor: CapabilityDescriptor
        let input: JSONValue?
        let completion: @Sendable (Bool) -> Void
    }
    private var confirmationQueue: [ConfirmationRequest] = []
    private var confirmationInFlight = false

    /// 可选无人值守自动拒绝定时器秒数(手动/真机跑用,防夜里留挂着的对话框)。读 `AA_AUTO_DENY_SECONDS`。
    /// 仅在 `.interactive`(真弹窗)分支生效;headless 门禁用的是 `AA_CONFIRM_AUTO`(不弹窗),二者不冲突。
    ///
    /// ⚠️ **test-only,与 `AA_CONFIRM_AUTO` 同口径:12/13 真机分发前必须移除或编译期门控**。
    ///    方向上安全(缺省 nil = 不自动决定;设了也只会到点 deny,绝不自动批准),但不该随产品出厂。
    let autoDenySeconds: Double? = {
#if AA_TESTING
        if let s = ProcessInfo.processInfo.environment["AA_AUTO_DENY_SECONDS"], let v = Double(s) { return v }
#endif
        return nil
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0a) V1 内封栈:构造真 Host Port(ProcessPort/HTTPPort)→ 装配 ProxyPlugin(注入)→ 经 ProcessPort 拉起内核。
        //     内核可执行路径从 env 读:E2E 指向 fake stub;真实指向将来入库的 mihomo(锁版入库是用户决策,留用户)。
        //     未配置 AA_MIHOMO_KERNEL_PATH → 不拉起任何进程(绝不下载/启动真 mihomo),proxy.status 会如实报未运行。
        let processPort = SystemProcessPort()   // 反孤儿退出钩子在此进程级安装一次(atexit + 信号)
        let httpPort = SocketHTTPPort()
        let env = ProcessInfo.processInfo.environment
        let controlPort = Int(env["AA_MIHOMO_CONTROL_PORT"] ?? "") ?? 9090
        let kernelPath: String?
        var kernelArgs: [String]
#if AA_TESTING
        if let fakePath = env["AA_MIHOMO_KERNEL_PATH"], !fakePath.isEmpty {
            kernelPath = fakePath
            kernelArgs = ["--port", String(controlPort)]
        } else {
            kernelPath = nil
            kernelArgs = []
        }
        if let extra = env["AA_MIHOMO_KERNEL_EXTRA_ARGS"], !extra.isEmpty {
            kernelArgs += extra.split(separator: " ").map(String.init)
        }
#else
        kernelPath = MihomoKernelResource.executablePath
#if AA_E2E
        let dataDirectory = env["AA_MIHOMO_DATA_DIR"] ?? AAPaths.socketDirectoryURL.appendingPathComponent("mihomo", isDirectory: true).path
#else
        let dataDirectory = AAPaths.socketDirectoryURL.appendingPathComponent("mihomo", isDirectory: true).path
#endif
        do {
            try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
        } catch {
            hostFatal("mihomo 数据目录创建失败: \(error.localizedDescription)")
        }
        kernelArgs = ["-d", dataDirectory, "-f", MihomoKernelResource.defaultConfigPath,
                      "-ext-ctl", "127.0.0.1:\(controlPort)"]
#endif
        // 07 票:系统代理读写 Port。缺省为真 networksetup;test-only env seam AA_NETWORKSETUP_FAKE_STATE 指定
        //   文件后端假件(E2E 用,绝不碰真设置)。与 AA_CONFIRM_AUTO / AA_MIHOMO_KERNEL_PATH 同口径,12/13 前按需门控。
        let networkConfigPort: any NetworkConfigPort
        if let statePath = env["AA_NETWORKSETUP_FAKE_STATE"], !statePath.isEmpty {
            networkConfigPort = FileBackedNetworkConfigPort(statePath: statePath)
            hostLog("系统代理后端: 文件后端假件(test-only)\(statePath) —— 绝不碰真 networksetup")
        } else {
            networkConfigPort = NetworkSetupPort()
            hostLog("系统代理后端: 真 networksetup(per-service;仅在 proxy.system.enable/disable 被调用时触达)")
        }
        // 08:接管态持久化路径 —— 生产缺省 AAPaths.takeoverStatePath;test-only env seam AA_TAKEOVER_STATE_PATH 覆盖到临时区
        //   (E2E 绝不污染真实 AppSupport)。reaper 复用 SystemProcessPort(它兼作 ProcessReaper,按原始 pid 跨世代回收)。
        let takeoverStatePath = env["AA_TAKEOVER_STATE_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? AAPaths.takeoverStatePath
        let stateStore = FileTakeoverStateStore(path: takeoverStatePath)
        hostLog("接管态持久化: \(takeoverStatePath)")
        // 10:订阅持久化目录 + 订阅源拉取真实现。生产缺省 AAPaths.subscriptionsDirectory;test-only env seam
        //   AA_SUBSCRIPTION_DIR 覆盖到 $BUILD 临时区(E2E 绝不污染真实 AppSupport;与 AA_TAKEOVER_STATE_PATH 同口径,12/13 前按需门控)。
        let subscriptionDir = env["AA_SUBSCRIPTION_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? AAPaths.subscriptionsDirectory
        let subscriptionStore = FileSubscriptionStore(baseDir: subscriptionDir)
        let subscriptionSource = RealSubscriptionSourcePort()
        hostLog("订阅持久化目录: \(subscriptionDir)(源拉取: file:// / http(s):// 真实现)")
        let plugin = ProxyPlugin(processPort: processPort, httpPort: httpPort,
                                 networkConfigPort: networkConfigPort,
                                 kernelPath: kernelPath, controlPort: controlPort, kernelArgs: kernelArgs,
                                 stateStore: stateStore, reaper: processPort,
                                 subscriptionStore: subscriptionStore, subscriptionSource: subscriptionSource)
        self.proxyPlugin = plugin

        // 0c) 崩溃自愈:正常服务前先跑一次。读持久化接管态 → 判定 → 执行(reap 孤儿 / 恢复接管 / 还原快照 / 清标记)。
        //     强杀(kill -9)后的残留接管在此被检测并复原,系统代理绝不滞留「指向死端口」的断网态。
        let healReport = plugin.selfHeal()
        hostLog("崩溃自愈: \(healReport.logLine)")

        // 0d) 拉起内核 —— 若自愈已(为恢复接管)重启内核则跳过,避免重复拉起;否则按常规拉起(clean/用户改过/还原快照/无标记路径)。
        if healReport.kernelRelaunched {
            hostLog("mihomo 内核已由自愈(恢复接管)拉起,跳过常规拉起。")
        } else if let kp = kernelPath {
            if plugin.launchKernel() {
                hostLog("mihomo 内核已拉起(随宿主启停): \(kp) · 控制端口 \(controlPort)")
            } else {
                hostLog("mihomo 内核拉起失败: \(kp)(proxy.status 将如实报未运行)")
            }
        } else {
            hostLog("测试构建未配置 fake mihomo,不拉起内核")
        }

        // 0d') 10 票(F3)重启后机械补齐:内核确认拉起之后,若清单有激活订阅,让内核从其物化配置重载
        //      (best-effort,有界就绪轮询,失败不阻断启动;不改 08 判定,只在其后追加一步)。仅在有内核时做(否则 reload 无意义)。
        //      自愈重启分支与常规拉起分支都覆盖:两者都已让内核起来。放在 server.start() 之前——故 socket 出现即代表恢复已跑完。
        if healReport.kernelRelaunched || kernelPath != nil {
            if plugin.reloadActiveSubscriptionIfAny() {
                hostLog("重启恢复: 已让内核重载当前激活订阅的配置(catalog 与内核对齐)")
            } else {
                hostLog("重启恢复: 无激活订阅或重载未成功(不阻断启动)")
            }
        }

        // 0b) 构造注册表:demo 能力 + 插件能力(proxy.status),并注入 dangerous 确认回调。
        //     回调 @Sendable:被后台连接处理线程调用,内部再切主线程弹窗。捕获 weak self 避免互持。
        //     插件产 [PluginCapability](只依赖 SDK/Contracts),宿主零成本适配成 Registry 的 Capability(handler 形状一致)。
        let pluginCaps = plugin.capabilities().map { Capability(descriptor: $0.descriptor, handler: $0.handler) }
        registry = Registry(capabilities: Registry.demoCapabilities + pluginCaps,
                            confirmDangerous: { [weak self] descriptor, input, completion in
            guard let self else { completion(false); return }
            self.confirmDangerous(descriptor, input, completion: completion)
        })

        // 1) socket 路径与父目录(路径常量集中在 Contracts.AAPaths);父目录建不出即快速失败,不带病常驻
        let sockPath = AAPaths.socketPath
        do {
            try FileManager.default.createDirectory(at: AAPaths.socketDirectoryURL, withIntermediateDirectories: true)
        } catch {
            hostFatal("socket 父目录创建失败(\(AAPaths.socketDirectoryURL.path)): \(error.localizedDescription)")
        }
        hostLog("socket 路径: \(sockPath)")

        // 2) 启动 UDS server(bind 前 unlink 旧 socket 在 server.start() 内做);启动失败即快速失败
        server = UDSServer(socketPath: sockPath, registry: registry)
        do {
            try server.start()
            hostLog("UDS server 已监听: \(sockPath)")
        } catch {
            hostFatal("UDS server 启动失败: \(error.localizedDescription)")
        }

        // 3) 菜单栏项(只读展示已注册能力)
        setupStatusItem()

        NSApp.setActivationPolicy(.accessory) // 无 Dock 图标,菜单栏常驻
#if AA_TESTING
        switch AutoConfirm.current() {
        case .approve: hostLog("dangerous 确认模式: AA_CONFIRM_AUTO=approve(test-only 自动批准,不弹窗)")
        case .deny:    hostLog("dangerous 确认模式: AA_CONFIRM_AUTO=deny(test-only 自动拒绝,不弹窗)")
        case .interactive:
            hostLog("dangerous 确认模式: interactive(真 NSAlert 确认)"
                    + (autoDenySeconds.map { " · AA_AUTO_DENY_SECONDS=\($0)s 自动拒绝" } ?? ""))
        }
#else
        hostLog("dangerous 确认模式: interactive(生产构建不读取 AA_CONFIRM_AUTO)")
#endif
        // test/dev seam:SIGUSR1 → 优雅退出。用 DispatchSource(非 raw handler,安全)在主线程调 NSApp.terminate,
        //   完整走 applicationWillTerminate → reclaimKernel → ProcessPort.terminate 的回收路径(供 headless E2E 验证
        //   「terminate 对 SIGTERM-忽略型内核仍 SIGKILL 兜底、无孤儿」)。须先 SIG_IGN 让默认处置不抢先杀进程。
        //   不与 SystemProcessPort 的 SIGTERM/SIGINT/SIGHUP raw handler 冲突(信号号不同)。12/13 分发前按需保留/门控。
        signal(SIGUSR1, SIG_IGN)
        let quitSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        quitSource.setEventHandler { NSApp.terminate(nil) }
        quitSource.resume()
        self.gracefulQuitSource = quitSource

        hostLog("启动完成。")
    }

    /// 宿主优雅退出(菜单退出 / NSApplication.terminate)时:先还原系统代理,再回收内核。
    /// **顺序(07 票)**:还原系统代理(disable)→ 停内核(reclaim)——确保退出后网络立即直连(不留指向已死内核端口的系统代理)。
    /// 被 kill/pkill 的强制退出由 SystemProcessPort 的 atexit/信号钩子兜底回收内核(零孤儿);但系统代理还原需运行
    /// networksetup(非 async-signal-safe),不能在信号处理器里做——那条硬杀路径下的代理复原归 08 票崩溃自愈
    /// (重启后检测上一世代快照 + 内核指向死端口并清理)。本方法覆盖优雅退出路径。
    func applicationWillTerminate(_ notification: Notification) {
        proxyPlugin?.restoreSystemProxyOnExit()   // ① 先还原系统代理(若曾接管)
        proxyPlugin?.reclaimKernel()              // ② 再停内核
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡"
        let menu = NSMenu()
        menu.addItem(withTitle: "AA 能力注册表", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for cap in registry.list() {
            // 只读项:nil action → 自动 disabled
            menu.addItem(withTitle: "\(cap.id)  ·  \(cap.risk.rawValue)  ·  \(cap.summary)",
                         action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // ============ dangerous 宿主确认(注入进 Registry 的回调实现)============

    /// dangerous 确认回调实现。非隔离入口只负责入队并立即返回；弹窗由主线程串行处理。
    ///
    /// ⚠️ **test-only env seam(`AA_CONFIRM_AUTO`)**:approve→true / deny→false,均不弹窗、即时返回,
    ///    供 headless check.sh 无人值守跑两分支;未设 → 走真 NSAlert(生产缺省,fail-safe)。
    ///    该分支受 `AA_TESTING` 编译期门控，生产构建不可达。
    nonisolated private func confirmDangerous(_ descriptor: CapabilityDescriptor, _ input: JSONValue?,
                                               completion: @escaping @Sendable (Bool) -> Void) {
        // F2:把本次请求的 input 关键字段落一行日志(证明 input 到达确认层,消除盲批;E2E 可 grep `[confirm] <id> ...`)。
        hostLog("[confirm] \(descriptor.id) \(Self.renderInput(input))")
#if AA_TESTING
        switch AutoConfirm.current() {
        case .approve:
            hostLog("AA_CONFIRM_AUTO=approve → 自动批准(test-only,不弹窗)[\(descriptor.id)]")
            completion(true)
            return
        case .deny:
            hostLog("AA_CONFIRM_AUTO=deny → 自动拒绝(test-only,不弹窗)[\(descriptor.id)]")
            completion(false)
            return
        case .interactive:
            break
        }
#endif
        // 入队后立即返回；UDS 请求收到 pending/requestId，
        // 模态框生命周期不再与客户端 socket 超时耦合。
        DispatchQueue.main.async { [weak self] in
            guard let self else { completion(false); return }
            self.confirmationQueue.append(ConfirmationRequest(descriptor: descriptor, input: input,
                                                               completion: completion))
            self.showNextConfirmationIfNeeded()
        }
    }

    /// 把 input 渲染成一行可读摘要(通用:input 是 object 就列键值,别硬编码只认某能力)。用于确认日志与 GUI 确认框。
    nonisolated static func renderInput(_ input: JSONValue?) -> String {
        guard let input = input else { return "(无 input)" }
        guard let obj = input.objectValue else { return "input=\(input)" }
        if obj.isEmpty { return "(空 input)" }
        let pairs = obj.keys.sorted().map { key -> String in
            let v = obj[key]
            let vs = v?.stringValue ?? v.map { "\($0)" } ?? "null"
            return "\(key)=\(vs)"
        }
        return pairs.joined(separator: " ")
    }

    /// 主线程一次展示一个确认；结束后在后台完成 pending invocation，避免能力 handler 占用 UI 线程。
    private func showNextConfirmationIfNeeded() {
        guard !confirmationInFlight, !confirmationQueue.isEmpty else { return }
        confirmationInFlight = true
        let request = confirmationQueue.removeFirst()
        let approved = showConfirmAlert(request.descriptor, request.input)
        hostLog("dangerous 确认结果 [\(request.descriptor.id)]: \(approved ? "approved" : "denied")")
        confirmationInFlight = false
        DispatchQueue.global(qos: .userInitiated).async { request.completion(approved) }
        showNextConfirmationIfNeeded()
    }

    /// 主线程弹 dangerous 确认框(critical NSAlert)。accessory app 弹窗前必须 activate 带到前台。
    /// 支持 `AA_AUTO_DENY_SECONDS` 定时自动拒绝(定时器须加进 `.modalPanel` 模式,否则模态循环里不触发)。
    ///
    /// 主线程队列保证同一时刻只有一个 `runModal`，auto-deny 只作用于当前会话。
    /// F2:把本次请求的 input 关键字段渲染进确认框——用户看得见批的是哪个源/替换哪条,不再盲批。
    private func showConfirmAlert(_ descriptor: CapabilityDescriptor, _ input: JSONValue?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "确认执行危险能力:\(descriptor.id)"
        let inputLine = AppDelegate.renderInput(input)
        alert.informativeText = "\(descriptor.summary)\n\n本次请求参数:\(inputLine)\n\n这是 dangerous 档能力,确认只在宿主 GUI 完成,CLI 不会代你决定。"
        alert.addButton(withTitle: "确认执行") // .alertFirstButtonReturn
        alert.addButton(withTitle: "取消")      // .alertSecondButtonReturn

        var timer: Timer?
        if let secs = autoDenySeconds {
            let t = Timer(timeInterval: secs, repeats: false) { _ in
                hostLog("自动拒绝计时到(\(secs)s),关闭弹窗")
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
            }
            RunLoop.main.add(t, forMode: .modalPanel)
            RunLoop.main.add(t, forMode: .default)
            timer = t
        }

        let resp = alert.runModal()
        timer?.invalidate()
        return resp == .alertFirstButtonReturn // 只有「确认执行」= true;其余(含定时自动拒绝)= false
    }
}

// 债务口径:此 @main 只是 vfsoverlay 过桥用(check.sh 单独把本库 target 编成可执行冒烟)。
// AAHostMacOS 终态是「库」(Host Port 的 macOS 实现);GUI 宿主终态是 XcodeGen app 壳(LSUIElement)。
// 归 12 票:@main 移进 app 壳、AppDelegate 转 public,本 target 保持库(见 Package.swift 同口径注释)。
@main
@MainActor
struct AAHostMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
