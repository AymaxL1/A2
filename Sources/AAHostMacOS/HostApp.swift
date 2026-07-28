// AAHostMacOS —— 宿主 GUI 入口。菜单栏常驻(accessory)+ 能力注册表 + UDS server。
//
// 入口用 @main @MainActor struct(顶层代码非 MainActor 上下文,不能在 main.swift 顶层构造 @MainActor 对象;S1/S2 已验证)。
// socket 路径读 Contracts 常量(AAPaths),父目录启动时自建,旧 socket 由 server bind 前 unlink。
//
// 04 票:宿主向 Registry 注入 dangerous 确认回调(真 GUI 确认)。实现照 S2 spike 已真机点验的线程模型:
//   后台连接处理线程需弹窗时 `DispatchQueue.main.sync` 同步切主线程 → `NSApp.activate` → critical `NSAlert`
//   `runModal` → 「确认执行」=true /「取消」=false,再把 Bool 带回后台线程写响应(无死锁)。

import AppKit
import AAContracts
import AAHostRuntime
import AAPluginSDK
import PluginProxy

/// dangerous 确认的 test-only 自动化档位(读环境变量 `AA_CONFIRM_AUTO`)。
///
/// ⚠️ **test-only,12/13 真机分发前必须移除或编译期门控**:headless check.sh 靠它无人值守跑 deny/approve 两分支
///    (不弹窗、即时返回),绝不能让生产默认放行。安全缺省是 `.interactive`——未设该变量时走真 NSAlert,
///    人不点就阻塞(天然 fail-safe,不会静默批准)。
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

    /// 可选无人值守自动拒绝定时器秒数(手动/真机跑用,防夜里留挂着的对话框)。读 `AA_AUTO_DENY_SECONDS`。
    /// 仅在 `.interactive`(真弹窗)分支生效;headless 门禁用的是 `AA_CONFIRM_AUTO`(不弹窗),二者不冲突。
    ///
    /// ⚠️ **test-only,与 `AA_CONFIRM_AUTO` 同口径:12/13 真机分发前必须移除或编译期门控**。
    ///    方向上安全(缺省 nil = 不自动决定;设了也只会到点 deny,绝不自动批准),但不该随产品出厂。
    let autoDenySeconds: Double? = {
        if let s = ProcessInfo.processInfo.environment["AA_AUTO_DENY_SECONDS"], let v = Double(s) { return v }
        return nil
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0a) V1 内封栈:构造真 Host Port(ProcessPort/HTTPPort)→ 装配 ProxyPlugin(注入)→ 经 ProcessPort 拉起内核。
        //     内核可执行路径从 env 读:E2E 指向 fake stub;真实指向将来入库的 mihomo(锁版入库是用户决策,留用户)。
        //     未配置 AA_MIHOMO_KERNEL_PATH → 不拉起任何进程(绝不下载/启动真 mihomo),proxy.status 会如实报未运行。
        let processPort = SystemProcessPort()   // 反孤儿退出钩子在此进程级安装一次(atexit + 信号)
        let httpPort = SocketHTTPPort()
        let env = ProcessInfo.processInfo.environment
        let kernelPath = env["AA_MIHOMO_KERNEL_PATH"]                 // nil = 不拉起内核
        let controlPort = Int(env["AA_MIHOMO_CONTROL_PORT"] ?? "") ?? 9090
        // 默认拉起参数 `--port <控制端口>`(对齐 fake stub);E2E 可经 AA_MIHOMO_KERNEL_EXTRA_ARGS 追加(如 --ignore-sigterm)。
        // 真 mihomo 的参数/配置形态(-d/-f + config 里的 external-controller)入库时由用户决定,留用户。
        var kernelArgs = ["--port", String(controlPort)]
        if let extra = env["AA_MIHOMO_KERNEL_EXTRA_ARGS"], !extra.isEmpty {
            kernelArgs += extra.split(separator: " ").map(String.init)
        }
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
        let plugin = ProxyPlugin(processPort: processPort, httpPort: httpPort,
                                 networkConfigPort: networkConfigPort,
                                 kernelPath: kernelPath, controlPort: controlPort, kernelArgs: kernelArgs,
                                 stateStore: stateStore, reaper: processPort)
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
            hostLog("未配置 AA_MIHOMO_KERNEL_PATH,不拉起内核;proxy.status 将如实报未运行。"
                    + "真 mihomo 锁版入库留用户决策。")
        }

        // 0b) 构造注册表:demo 能力 + 插件能力(proxy.status),并注入 dangerous 确认回调。
        //     回调 @Sendable:被后台连接处理线程调用,内部再切主线程弹窗。捕获 weak self 避免互持。
        //     插件产 [PluginCapability](只依赖 SDK/Contracts),宿主零成本适配成 Registry 的 Capability(handler 形状一致)。
        let pluginCaps = plugin.capabilities().map { Capability(descriptor: $0.descriptor, handler: $0.handler) }
        registry = Registry(capabilities: Registry.demoCapabilities + pluginCaps,
                            confirmDangerous: { [weak self] descriptor in
            self?.confirmDangerous(descriptor) ?? false
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
        switch AutoConfirm.current() {
        case .approve: hostLog("dangerous 确认模式: AA_CONFIRM_AUTO=approve(test-only 自动批准,不弹窗)")
        case .deny:    hostLog("dangerous 确认模式: AA_CONFIRM_AUTO=deny(test-only 自动拒绝,不弹窗)")
        case .interactive:
            hostLog("dangerous 确认模式: interactive(真 NSAlert 确认)"
                    + (autoDenySeconds.map { " · AA_AUTO_DENY_SECONDS=\($0)s 自动拒绝" } ?? ""))
        }
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

    /// dangerous 确认回调实现。从后台连接处理线程(经 Registry.invoke → 注入的 @Sendable 闭包)同步调用。
    /// `nonisolated`:@Sendable 闭包处于非隔离上下文,不能同步调 @MainActor 方法;故本入口与切主线程桥都是 nonisolated,
    ///   真正的 @MainActor 弹窗代码(showConfirmAlert)在主线程上经 `MainActor.assumeIsolated` 访问。
    ///
    /// ⚠️ **test-only env seam(`AA_CONFIRM_AUTO`)**:approve→true / deny→false,均不弹窗、即时返回,
    ///    供 headless check.sh 无人值守跑两分支;未设 → 走真 NSAlert(生产缺省,fail-safe)。
    ///    **12/13 真机分发前必须移除或编译期门控**(见 `AutoConfirm` 注释),绝不能让生产默认放行。
    nonisolated private func confirmDangerous(_ descriptor: CapabilityDescriptor) -> Bool {
        switch AutoConfirm.current() {
        case .approve:
            hostLog("AA_CONFIRM_AUTO=approve → 自动批准(test-only,不弹窗)[\(descriptor.id)]")
            return true
        case .deny:
            hostLog("AA_CONFIRM_AUTO=deny → 自动拒绝(test-only,不弹窗)[\(descriptor.id)]")
            return false
        case .interactive:
            return confirmDangerousOnMain(descriptor)
        }
    }

    /// 后台线程入口:同步切回主线程弹窗并取回结果(阻塞本连接直到用户/自动决定)。照 S2 已真机点验的模型。
    /// 主线程内用 `MainActor.assumeIsolated` 进入 @MainActor 隔离域调 showConfirmAlert(此时确在主线程,断言成立)。
    nonisolated private func confirmDangerousOnMain(_ descriptor: CapabilityDescriptor) -> Bool {
        let approved: Bool
        if Thread.isMainThread {
            approved = MainActor.assumeIsolated { self.showConfirmAlert(descriptor) }
        } else {
            approved = DispatchQueue.main.sync {
                MainActor.assumeIsolated { self.showConfirmAlert(descriptor) }
            }
        }
        hostLog("dangerous 确认结果 [\(descriptor.id)]: \(approved ? "approved" : "denied")")
        return approved
    }

    /// 主线程弹 dangerous 确认框(critical NSAlert)。accessory app 弹窗前必须 activate 带到前台。
    /// 支持 `AA_AUTO_DENY_SECONDS` 定时自动拒绝(定时器须加进 `.modalPanel` 模式,否则模态循环里不触发)。
    ///
    /// 已知限制(记债,本票不改逻辑):并发的两个 dangerous 调用会在主线程嵌套 `runModal`,
    /// auto-deny 定时器的 `stopModal` 停的是**最内层**模态会话,理论上可能误关到另一个弹窗。
    /// 属性是 fail-safe——最坏只会**多 deny**,绝不会误批(误关等价于该会话被拒)。
    /// 将来 dangerous 进入真实业务用例(如 10 票换订阅源)时,应把 dangerous 确认**串行化**
    /// (同一时刻只允许一个确认 modal,如用串行队列/信号量把并发确认排队),从根上消除嵌套 modal。
    private func showConfirmAlert(_ descriptor: CapabilityDescriptor) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "确认执行危险能力:\(descriptor.id)"
        alert.informativeText = "\(descriptor.summary)\n\n这是 dangerous 档能力,确认只在宿主 GUI 完成,CLI 不会代你决定。"
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
