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

import AAContracts
import AAPluginSDK
import AAUISystem
import Foundation

/// 代理插件。宿主在装配期注入真 ProcessPort/HTTPPort + 内核配置;插件负责编排内核生命周期与状态查询。
///
/// `@unchecked Sendable`:仅有的可变状态是 `handle`,全程由 `lock` 串行化保护;其余为不可变注入。
/// 这样 `capabilities()` 产出的 `@Sendable` handler 可安全从宿主的多连接处理线程并发调用。
public final class ProxyPlugin: @unchecked Sendable {
    private let processPort: any ProcessPort
    private let restClient: MihomoRESTClient
    /// 内核可执行路径(从宿主注入,宿主从 env/配置读)。nil = 未配置内核 → 不拉起,proxy.status 如实报未运行。
    private let kernelPath: String?
    /// 拉起内核的参数(默认 fake stub 约定 `--port <控制端口>`;真 mihomo 的参数/配置形态入库时由用户决定)。
    private let kernelArgs: [String]

    private let lock = NSLock()
    /// 当前内核句柄(经 ProcessPort 拉起后置入;回收后清空)。读写均在 lock 内。
    private var handle: ProcessHandle?

    /// - Parameters:
    ///   - processPort: 子进程生命周期 Port(宿主注入真实现;测试注入假件)。
    ///   - httpPort: HTTP Port(REST 客户端压其后)。
    ///   - kernelPath: 内核可执行路径;nil = 不拉起。
    ///   - controlPort: mihomo external-controller 端口(RESTClient 读它;默认参数也把它传给内核)。
    ///   - kernelArgs: 覆盖默认拉起参数(缺省 `["--port", "<controlPort>"]`,对齐 fake stub)。
    public init(processPort: any ProcessPort,
                httpPort: any HTTPPort,
                kernelPath: String?,
                controlPort: Int,
                kernelArgs: [String]? = nil) {
        self.processPort = processPort
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

    /// 暴露给宿主注册的能力集。目前:`proxy.status`(safe 只读)。
    /// handler 每次调用时读「当前句柄」——故内核死亡/重启都能被 status 如实反映。
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
            )
        ]
    }

    /// 占位/边界佐证:证明 PluginProxy 触达 AAUISystem(依赖边 SDK/Contracts/UISystem 全连通,且无需任何 Host*)。
    public static func riskBadge(for raw: String) -> String {
        let level = RiskLevel.parse(raw) ?? PluginSDK.defaultRisk
        return UISystem.badge(for: level)
    }
}
