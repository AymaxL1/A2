// PluginProxy —— 代理插件的域逻辑(内核生命周期编排 + proxy.status)。
// 依赖边:PluginProxy → AAPluginSDK, AAContracts, AAUISystem。
//
// 铁律(01 票验收项,06 票继续把守):PluginProxy 绝不依赖任何 Host* target(AAHostRuntime / AAHostMacOS / AAHostTestKit)。
// 这条边界由编译期强制——本 target 不得 `import` 任何 Host* 模块,check.sh 以「仅给 SDK/Contracts/UISystem
// 的 -I 编译成功」+「源码级 grep 守卫」双重把关。所有特权副作用(拉起/回收子进程、真 HTTP)都压到 Host Port
// 协议(ProcessPort/HTTPPort,定义在 SDK)之后,由宿主注入真实现;插件只面向协议编程,永不直连 macOS。
//
// 06 票:ProxyPlugin 持有注入的 ProcessPort/HTTPPort(+ 内核句柄),暴露 capabilities()(供宿主注册)
//   与 launchKernel()/reclaimKernel()(经 ProcessPort 拉起/回收内核)。业务面(读状态)归插件,特权面(进程)归宿主。
//
// 07 票:再注入 NetworkConfigPort,暴露 proxy.system.enable / proxy.system.disable 两条 normal 能力
//   (接管/还原系统代理)。接管前快照存于本插件(lock 保护),供 disable 与宿主退出还原按快照精确复原。
//   端口复用 06 的 RESTClient:enable 时读 mihomo mixed-port,把系统代理指向 127.0.0.1:<mixed-port>。

import AAContracts
import AAPluginSDK
import AAUISystem
import Foundation

/// 代理插件。宿主在装配期注入真 ProcessPort/HTTPPort/NetworkConfigPort + 内核配置;插件负责编排内核生命周期、
/// 状态查询与系统代理接管/还原。
///
/// `@unchecked Sendable`:可变状态是 `handle` 与 `proxySnapshot`,全程由 `lock` 串行化保护;其余为不可变注入。
/// 这样 `capabilities()` 产出的 `@Sendable` handler 可安全从宿主的多连接处理线程并发调用。
public final class ProxyPlugin: @unchecked Sendable {
    private let processPort: any ProcessPort
    private let restClient: MihomoRESTClient
    /// 系统代理读写边界(宿主注入真 networksetup 实现;测试/ E2E 注入假件)。
    private let networkConfigPort: any NetworkConfigPort
    /// 内核可执行路径(从宿主注入,宿主从 env/配置读)。nil = 未配置内核 → 不拉起,proxy.status 如实报未运行。
    private let kernelPath: String?
    /// 拉起内核的参数(默认 fake stub 约定 `--port <控制端口>`;真 mihomo 的参数/配置形态入库时由用户决定)。
    private let kernelArgs: [String]

    private let lock = NSLock()
    /// 当前内核句柄(经 ProcessPort 拉起后置入;回收后清空)。读写均在 lock 内。
    private var handle: ProcessHandle?
    /// 接管前的系统代理快照(enable 首次接管时捕获;disable / 退出还原后清空)。读写均在 lock 内。
    /// nil = 当前未接管系统代理。Codable 可持久化(08 崩溃自愈复用)。
    private var proxySnapshot: SystemProxySnapshot?

    /// - Parameters:
    ///   - processPort: 子进程生命周期 Port(宿主注入真实现;测试注入假件)。
    ///   - httpPort: HTTP Port(REST 客户端压其后)。
    ///   - networkConfigPort: 系统代理读写 Port(宿主注入真 networksetup;测试/E2E 注入假件)。
    ///   - kernelPath: 内核可执行路径;nil = 不拉起。
    ///   - controlPort: mihomo external-controller 端口(RESTClient 读它;默认参数也把它传给内核)。
    ///   - kernelArgs: 覆盖默认拉起参数(缺省 `["--port", "<controlPort>"]`,对齐 fake stub)。
    public init(processPort: any ProcessPort,
                httpPort: any HTTPPort,
                networkConfigPort: any NetworkConfigPort,
                kernelPath: String?,
                controlPort: Int,
                kernelArgs: [String]? = nil) {
        self.processPort = processPort
        self.networkConfigPort = networkConfigPort
        self.kernelPath = kernelPath
        self.kernelArgs = kernelArgs ?? ["--port", String(controlPort)]
        self.restClient = MihomoRESTClient(http: httpPort, port: controlPort)
    }

    /// 经 ProcessPort 拉起内核(随宿主启动)。
    /// - 未配置内核路径 → 返回 false(不视为错误:proxy.status 会如实报未运行)。
    /// - 已有存活句柄 → 幂等返回 true(不重复拉起)。
    /// - 拉起失败 → 清空句柄,返回 false。
    @discardableResult
    public func launchKernel() -> Bool {
        guard let path = kernelPath else { return false }
        lock.lock(); defer { lock.unlock() }
        if let h = handle, processPort.isAlive(h) { return true }
        do {
            handle = try processPort.launch(executablePath: path, arguments: kernelArgs)
            return true
        } catch {
            handle = nil
            return false
        }
    }

    /// 经 ProcessPort 回收内核(随宿主退出;幂等)。宿主进程退出的**兜底**反孤儿由 ProcessPort 真实现的退出钩子保证,
    /// 本方法是「优雅回收」路径(如 applicationWillTerminate 主动调)。
    public func reclaimKernel() {
        lock.lock()
        let h = handle
        handle = nil
        lock.unlock()
        if let h = h { processPort.terminate(h) }
    }

    /// 当前内核句柄快照(线程安全)。
    private func currentHandle() -> ProcessHandle? {
        lock.lock(); defer { lock.unlock() }
        return handle
    }

    // ============ 系统代理接管 / 还原(07 票)============

    /// 接管系统代理(enable):读内核 mixed-port → 首次接管前快照 → 把各服务三类代理指向 127.0.0.1:<mixed-port>。
    /// - 内核端口未就绪(内核未运行 / 控制面未起 / REST 读不到 mixed-port)→ 返回业务失败(capability_failed → 退出码 5),不崩。
    /// - 幂等:已接管(已有快照)时不覆盖首次快照,只重放接管(再指向内核端口,无害)。
    /// - `normal` 档:零 GUI 确认(由 Registry 路由,safe/normal 直执行)。
    public func enableSystemProxy() -> Result<JSONValue, WireError> {
        // ① 读内核 mixed-port(端口复用 06 的 RESTClient)。读不到即内核端口未就绪 → 业务失败(不接管、不崩)。
        guard let cfg = try? restClient.configs(), let port = cfg.mixedPort else {
            return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                      detail: "无法接管系统代理:内核端口未就绪(mihomo 未运行或控制面未就绪,读不到 mixed-port)"))
        }
        let host = "127.0.0.1"
        let controller = SystemProxyController(net: networkConfigPort)
        lock.lock(); defer { lock.unlock() }
        do {
            // 接管:takeover 内部保证「凡被指向内核端口的服务,其接管前状态都并入快照」——含接管后新出现的服务
            //   (修重放漏洞:否则新服务被接管却不进快照,还原遍历不到→永久指向死端口)。既有快照的服务保持首次原状态
            //   不被覆盖(幂等:重复 enable 不改「最初」)。故直接把返回快照赋回。
            proxySnapshot = try controller.takeover(host: host, port: port, into: proxySnapshot)
            return .success(.object([
                "enabled": .bool(true),
                "host": .string(host),
                "port": .number(Double(port))
            ]))
        } catch {
            return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                      detail: "接管系统代理失败: \(error)"))
        }
    }

    /// 还原系统代理(disable):按接管前快照精确还原(含「原本第三方代理」),随后清空快照。
    /// - 未接管过(无快照)→ no-op 成功(幂等:restored=false)。
    /// - `normal` 档:零 GUI 确认。
    public func disableSystemProxy() -> Result<JSONValue, WireError> {
        let controller = SystemProxyController(net: networkConfigPort)
        lock.lock(); defer { lock.unlock() }
        guard let snapshot = proxySnapshot else {
            // 从未接管 → 无需还原(幂等成功)。
            return .success(.object(["enabled": .bool(false), "restored": .bool(false)]))
        }
        do {
            try controller.restore(snapshot)
            proxySnapshot = nil
            return .success(.object(["enabled": .bool(false), "restored": .bool(true)]))
        } catch {
            return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                      detail: "还原系统代理失败: \(error)"))
        }
    }

    /// 宿主退出时的系统代理还原(优雅退出路径:applicationWillTerminate 调)。
    /// 若曾接管则按快照精确还原;**先还原、成功后才清快照;还原失败记 stderr 并保留快照**——退出路径不外抛,
    /// 但绝不静默丢快照(还原失败这件事对 08 崩溃自愈的持久化前提很重要:保留的快照可供下次启动自愈)。
    /// 未接管则 no-op。**调用顺序(宿主)**:先本方法还原系统代理,再 reclaimKernel 停内核——确保退出后网络立即直连。
    public func restoreSystemProxyOnExit() {
        lock.lock()
        let snapshot = proxySnapshot
        lock.unlock()
        guard let snapshot = snapshot else { return }
        let controller = SystemProxyController(net: networkConfigPort)
        do {
            try controller.restore(snapshot)
            lock.lock(); proxySnapshot = nil; lock.unlock()   // 成功后才清
        } catch {
            // 不静默:记日志、保留快照(08 崩溃自愈可据此复原;进程即将退出,残留快照不影响本世代)。
            FileHandle.standardError.write(Data("[PluginProxy] 宿主退出还原系统代理失败(保留快照供 08 自愈): \(error)\n".utf8))
        }
    }

    /// 暴露给宿主注册的能力集:
    ///   * `proxy.status`(safe 只读:内核状态);
    ///   * `proxy.system.enable`(normal:接管系统代理;cliAlias `aa proxy on`);
    ///   * `proxy.system.disable`(normal:还原系统代理;cliAlias `aa proxy off`)。
    /// handler 每次调用时读「当前状态」——故内核死亡/重启、接管/还原都能被如实反映。
    public func capabilities() -> [PluginCapability] {
        let processPort = self.processPort
        let restClient = self.restClient
        return [
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.status",
                    risk: .safe,
                    summary: "报告 mihomo 内核运行状态(safe 只读:是否存活 / 模式 / 监听端口 / 当前节点 / 版本)",
                    schemaSummary: "input: {} → output: { running: Bool, apiReachable?, version?, mode?, mixedPort?, node? }",
                    parameters: []
                ),
                handler: { [weak self] _ in
                    let h = self?.currentHandle() ?? nil
                    // 内核未运行也返回 .success(running:false)——如实呈现,退出码 0,绝不报错。
                    return .success(ProxyStatus.statusJSON(processPort: processPort, handle: h, rest: restClient))
                }
            ),
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.system.enable",
                    risk: .normal,
                    summary: "接管系统代理:把各网络服务的 HTTP/HTTPS/SOCKS 指向本机 mihomo 混合端口(normal 可逆,零 GUI 确认)",
                    schemaSummary: "input: {} → output: { enabled: true, host, port }",
                    parameters: [],
                    cliAlias: ["proxy", "on"]
                ),
                handler: { [weak self] _ in
                    guard let self = self else {
                        return .failure(WireError(code: WireErrorCode.capabilityFailed, detail: "插件已释放"))
                    }
                    return self.enableSystemProxy()
                }
            ),
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.system.disable",
                    risk: .normal,
                    summary: "还原系统代理:按接管前快照精确还原各网络服务代理设置(含原本的第三方代理;normal 可逆,零 GUI 确认)",
                    schemaSummary: "input: {} → output: { enabled: false, restored: Bool }",
                    parameters: [],
                    cliAlias: ["proxy", "off"]
                ),
                handler: { [weak self] _ in
                    guard let self = self else {
                        return .failure(WireError(code: WireErrorCode.capabilityFailed, detail: "插件已释放"))
                    }
                    return self.disableSystemProxy()
                }
            )
        ]
    }

    /// 占位/边界佐证:证明 PluginProxy 触达 AAUISystem(依赖边 SDK/Contracts/UISystem 全连通,且无需任何 Host*)。
    public static func riskBadge(for raw: String) -> String {
        let level = RiskLevel.parse(raw) ?? PluginSDK.defaultRisk
        return UISystem.badge(for: level)
    }
}
