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
    /// 接管态清单持久化边界(08 崩溃自愈):enable 成功写、disable/正常退出还原成功清除;缺省 Noop(不持久化)。
    private let stateStore: any TakeoverStateStore
    /// 跨世代孤儿回收边界(08 崩溃自愈):据持久化的旧 pid 探活/reap 上一世代残留内核;缺省 Noop(不回收)。
    private let reaper: any ProcessReaper
    /// 内核可执行路径(从宿主注入,宿主从 env/配置读)。nil = 未配置内核 → 不拉起,proxy.status 如实报未运行。
    private let kernelPath: String?
    /// 拉起内核的参数(默认 fake stub 约定 `--port <控制端口>`;真 mihomo 的参数/配置形态入库时由用户决定)。
    private let kernelArgs: [String]
    /// 订阅管理域状态机(10 票):list/activate/update/add,经注入的 SubscriptionStore/SubscriptionSourcePort +
    /// 06 的 RESTClient(reloadConfig)。缺省注入 Noop(不持久化 / 拉取即报未配置),不改 06/07/08 既有构造点。
    private let subscriptionManager: SubscriptionManager

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
    ///   - stateStore: 接管态清单持久化(08;缺省 Noop = 不持久化,不改 06/07 既有行为)。
    ///   - reaper: 跨世代孤儿回收(08;缺省 Noop = 不回收)。
    ///   - subscriptionStore: 订阅清单/配置持久化(10;缺省 Noop = 不持久化 → list 空、activate/update/add 因无源/无路径而业务失败,不改既有构造点)。
    ///   - subscriptionSource: 订阅源拉取(10;缺省 Noop = fetch 恒报「未配置订阅源」→ add/update 业务失败)。
    public init(processPort: any ProcessPort,
                httpPort: any HTTPPort,
                networkConfigPort: any NetworkConfigPort,
                kernelPath: String?,
                controlPort: Int,
                kernelArgs: [String]? = nil,
                stateStore: any TakeoverStateStore = NoopTakeoverStateStore(),
                reaper: any ProcessReaper = NoopProcessReaper(),
                subscriptionStore: any SubscriptionStore = NoopSubscriptionStore(),
                subscriptionSource: any SubscriptionSourcePort = NoopSubscriptionSourcePort()) {
        self.processPort = processPort
        self.networkConfigPort = networkConfigPort
        self.stateStore = stateStore
        self.reaper = reaper
        self.kernelPath = kernelPath
        self.kernelArgs = kernelArgs ?? ["--port", String(controlPort)]
        let rest = MihomoRESTClient(http: httpPort, port: controlPort)
        self.restClient = rest
        self.subscriptionManager = SubscriptionManager(store: subscriptionStore, source: subscriptionSource, restClient: rest)
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

    /// 10 票(F3):重启后机械补齐——若订阅清单有激活项,让内核从其物化配置重载(best-effort,失败不阻断启动)。
    /// 宿主在内核确认拉起之后调用;委托订阅状态机(带有界就绪轮询)。
    @discardableResult
    public func reloadActiveSubscriptionIfAny() -> Bool {
        subscriptionManager.reloadActiveIfAny()
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
            // 事务边界：先捕获全部受影响服务，再持久化完整最终还原快照，最后才开始系统写入。
            let previousSnapshot = proxySnapshot
            let plan = try controller.prepareTakeover(into: proxySnapshot)
            let pid = handle.flatMap { processPort.processID($0) } ?? 0
            try persistTakeover(snapshot: plan.snapshot, kernelPort: port, kernelPID: pid,
                                kernelExecutablePath: kernelExecutablePath(pid: pid))
            proxySnapshot = plan.snapshot
            do {
                try controller.applyTakeover(plan, host: host, port: port)
            } catch {
                // 写入可能部分落地，只回滚到“本次调用前”状态。首次 enable 回滚成功后清标记；
                // 重复 enable 回滚后既有接管仍生效，因此保留合并后的快照和标记。
                do {
                    try controller.restore(plan.rollbackSnapshot)
                    if previousSnapshot == nil {
                        try clearTakeover()
                        proxySnapshot = nil
                    } else {
                        proxySnapshot = plan.snapshot
                    }
                } catch let rollbackError {
                    return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                              detail: "接管系统代理失败: \(error);回滚亦失败: \(rollbackError)(已保留接管标记供下次启动自愈)"))
                }
                return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                          detail: "接管系统代理失败: \(error)(已回滚)"))
            }
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
            // 08:正常还原成功即清除持久化标记(表示无残留接管;下次启动为 clean)。清除幂等,失败不崩。
            try clearTakeover()
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
            // 08:正常退出还原成功 → 清除持久化标记(下次启动为 clean,无残留)。
            try clearTakeover()
            lock.lock(); proxySnapshot = nil; lock.unlock()   // 还原与清标记都成功后才清内存快照
        } catch {
            // 不静默:记日志、**保留快照与持久化标记**(08 崩溃自愈可据此复原;进程即将退出,残留快照不影响本世代)。
            FileHandle.standardError.write(Data("[PluginProxy] 宿主退出还原系统代理失败(保留快照/持久化标记供 08 自愈): \(error)\n".utf8))
        }
    }

    // ============ 崩溃自愈(08 票)============

    /// 崩溃自愈:宿主启动早期、正常服务前跑一次。**采集真实信号 → 调 `CrashRecovery.decide` 拿决策 → 按决策执行**——
    /// 让被测的纯函数就是真实决策路径(消除「测过但真实路径不同」的缝)。
    /// **硬不变式**:任一路径后系统代理都不指向死端口。自愈只经既有 Port(生产真件 / E2E 假件),不额外触达真系统。
    ///
    /// 两条安全铁律:
    ///   * **reap 前身份核验**(修 pid 复用盲杀):持久化 pid 的当前可执行路径 == 记录的内核路径才 SIGKILL,否则不杀。
    ///   * **只有 restore/恢复真正成功才清标记**(修「失败仍清标记 → 永久滞留死端口」):失败保留标记 + 记日志,下次启动重试。
    @discardableResult
    public func selfHeal() -> SelfHealReport {
        // 读持久化接管态。无 → decide 即 .clean(不读网络/内核,避免无标记时无谓触达真 networksetup)。
        let loaded = loadTakeover()
        guard case .state(let state) = loaded else {
            if case .invalid = loaded {
                return SelfHealReport(decision: .deferred, reapedOrphanPID: nil, kernelRelaunched: false)
            }
            let decision = CrashRecovery.decide(hasPersistedMarker: false,
                                                proxyStillPointsAtKernelPort: false,
                                                kernelPortHealthy: false,
                                                kernelHealthilyRestartable: false)
            return SelfHealReport(decision: decision, reapedOrphanPID: nil, kernelRelaunched: false)  // .clean
        }

        // —— 孤儿清理(还 06 债)+ 身份核验(修盲杀)——
        // 仅当持久化 pid 的**当前可执行路径**逐字节等于记录的内核路径时,才认定它是我方上世代残留内核并 SIGKILL;
        // 否则(pid 已复用 / 读不到路径 / EPERM 非本用户进程)一律**不杀**,记日志——网络仍经下面的 restore/repoint 自愈,不冒杀错风险。
        var reapedPID: Int32? = nil
        if state.kernelPID > 0 {
            let currentPath = reaper.executablePath(pid: state.kernelPID)
            if CrashRecovery.isOurKernel(currentPath: currentPath, expectedPath: state.kernelExecutablePath) {
                reaper.reap(pid: state.kernelPID)
                reapedPID = state.kernelPID
                waitForOrphanGone(pid: state.kernelPID)   // 有界等待其消失,便于新内核干净重启(端口释放)
            } else if reaper.isProcessAlive(pid: state.kernelPID) {
                selfHealLog("跳过 reap:pid \(state.kernelPID) 身份不符(当前路径=\(currentPath ?? "nil") ≠ 记录内核路径 \(state.kernelExecutablePath)),不杀无辜进程")
            }
        }

        // —— 采集信号:读当前系统代理。读**失败**要区别于「用户改过」:保守 deferred(保留标记、不清、不误判)——待下次启动重试。——
        let controller = SystemProxyController(net: networkConfigPort)
        let currentServices: [ServiceProxyState]
        do {
            currentServices = try controller.capture().services
        } catch {
            selfHealLog("读当前系统代理失败(\(error)),保守保留标记待下次启动重试(不误判用户改过、不清标记)")
            return SelfHealReport(decision: .deferred, reapedOrphanPID: reapedPID, kernelRelaunched: false)
        }
        let proxyPoints = CrashRecovery.systemProxyPointsAt(host: "127.0.0.1", port: state.kernelPort, services: currentServices)

        // —— 残留接管才试着把健康内核带回来(有副作用,只在确认残留时做);「能否健康重启」= 重启后 REST 可读到 mixed-port。——
        var healthyPort: Int? = nil
        var relaunched = false
        if proxyPoints, kernelPath != nil, launchKernel() {
            relaunched = true
            healthyPort = pollForMixedPort()   // REST 就绪即得 mixed-port;超时 nil
        }

        // —— 决策(纯函数单一真源;真实信号喂进去)。启动早期无「受本世代管理且健康」的内核(旧的已 reap)→ kernelPortHealthy=false。——
        let decision = CrashRecovery.decide(
            hasPersistedMarker: true,
            proxyStillPointsAtKernelPort: proxyPoints,
            kernelPortHealthy: false,
            kernelHealthilyRestartable: healthyPort != nil
        )

        switch decision {
        case .userChangedProxy:
            // 代理已不指向我方端口(用户手动改过 / 已直连)→ 绝不覆盖用户设置,只清陈旧标记。
            do {
                try clearTakeover()
                lock.lock(); proxySnapshot = nil; lock.unlock()
                return SelfHealReport(decision: .userChangedProxy, reapedOrphanPID: reapedPID, kernelRelaunched: relaunched)
            } catch {
                selfHealLog("清除陈旧接管标记失败(\(error))，保留证据并 deferred")
                return SelfHealReport(decision: .deferred, reapedOrphanPID: reapedPID, kernelRelaunched: relaunched)
            }

        case .recoverTakeover:
            let port = healthyPort!
            // 先把「接管前原状态」播种为将来还原目标(**不是**当前指向死端口的态),再重指到存活端口。
            lock.lock(); proxySnapshot = state.snapshot; lock.unlock()
            do {
                let plan = try controller.prepareTakeover(into: state.snapshot)
                let pid = currentHandle().flatMap { processPort.processID($0) } ?? 0
                try persistTakeover(snapshot: plan.snapshot, kernelPort: port, kernelPID: pid,
                                    kernelExecutablePath: kernelExecutablePath(pid: pid))
                lock.lock(); proxySnapshot = plan.snapshot; lock.unlock()
                try controller.applyTakeover(plan, host: "127.0.0.1", port: port)
                return SelfHealReport(decision: .recoverTakeover, reapedOrphanPID: reapedPID, kernelRelaunched: true)
            } catch {
                // 重指失败 → 兜底退化为还原快照(绝不留死端口)。**只有还原真成功才清标记**。
                selfHealLog("恢复接管重指失败(\(error)),退化为还原快照")
                return finishRestore(controller: controller, snapshot: state.snapshot,
                                     reapedPID: reapedPID, relaunched: relaunched)
            }

        case .restoreSnapshot:
            // 内核不能健康重启 → 按快照精确还原(降级直连)。若刚才误起了不健康内核,回收之。**只有还原真成功才清标记**。
            reclaimKernel()
            return finishRestore(controller: controller, snapshot: state.snapshot,
                                 reapedPID: reapedPID, relaunched: relaunched)

        case .alreadyHealthy:
            // 启动早期不会走到(kernelPortHealthy=false);为完整性保留:仅校正标记(重写清单)。
            let pid = currentHandle().flatMap { processPort.processID($0) } ?? state.kernelPID
            do {
                try persistTakeover(snapshot: state.snapshot, kernelPort: state.kernelPort, kernelPID: pid,
                                    kernelExecutablePath: pid == state.kernelPID ? state.kernelExecutablePath : kernelExecutablePath(pid: pid))
            } catch {
                selfHealLog("校正接管标记失败(\(error)),保留原标记待下次重试")
            }
            return SelfHealReport(decision: .alreadyHealthy, reapedOrphanPID: reapedPID, kernelRelaunched: relaunched)

        case .clean, .deferred:
            // 二者均由前置分支提前返回；此处仅为 switch 完备。
            return SelfHealReport(decision: decision, reapedOrphanPID: reapedPID, kernelRelaunched: relaunched)
        }
    }

    /// 还原快照收尾:**成功才 clearTakeover + 清内存快照**;失败则保留标记 + 记日志,留待下次启动重试(绝不清标记留死端口)。
    private func finishRestore(controller: SystemProxyController, snapshot: SystemProxySnapshot,
                              reapedPID: Int32?, relaunched: Bool) -> SelfHealReport {
        do {
            try controller.restore(snapshot)
            try clearTakeover()                               // 只有真成功才清
            lock.lock(); proxySnapshot = nil; lock.unlock()
        } catch {
            selfHealLog("还原快照失败(\(error)),**保留持久化标记**待下次启动重试(绝不清标记以免永久滞留死端口)")
            // 保留 proxySnapshot(若上层需要)与持久化标记;不清。
            return SelfHealReport(decision: .deferred, reapedOrphanPID: reapedPID, kernelRelaunched: relaunched)
        }
        return SelfHealReport(decision: .restoreSnapshot, reapedOrphanPID: reapedPID, kernelRelaunched: relaunched)
    }

    // ============ 持久化助手(不取 lock;由调用方保证时机)============

    /// 自愈日志(写 stderr;宿主把 stdout+stderr 汇入日志文件,E2E 可 grep)。
    private func selfHealLog(_ msg: String) {
        FileHandle.standardError.write(Data("[PluginProxy][self-heal] \(msg)\n".utf8))
    }

    /// 取某 pid 的内核可执行路径(持久化用):优先经 reaper 读回真实映像路径(与 reap 时的核验口径一致),读不到回退到配置路径。
    private func kernelExecutablePath(pid: Int32) -> String {
        if pid > 0, let p = reaper.executablePath(pid: pid) { return p }
        return kernelPath ?? ""
    }

    private enum TakeoverLoad {
        case missing
        case state(TakeoverState)
        case invalid
    }

    /// 主文件不可读/损坏时尝试独立恢复副本；主副都不可用才 invalid/deferred，绝不猜测代理所有权。
    private func loadTakeover() -> TakeoverLoad {
        var primaryMissing = false
        do {
            if let data = try stateStore.load() {
                if let state = try? JSONDecoder().decode(TakeoverState.self, from: data) {
                    return .state(state)
                }
                selfHealLog("接管态主清单损坏/无法解码(\(data.count) 字节)，尝试恢复副本")
            } else {
                primaryMissing = true
            }
        } catch {
            selfHealLog("接管态主清单读取失败(\(error))，尝试恢复副本")
        }

        var recoveryMissing = false
        do {
            if let recovery = try stateStore.loadRecovery() {
                guard let state = try? JSONDecoder().decode(TakeoverState.self, from: recovery) else {
                    selfHealLog("接管态恢复副本损坏/无法解码(\(recovery.count) 字节)")
                    return .invalid
                }
                selfHealLog("已从独立恢复副本取回完整接管快照")
                return .state(state)
            } else {
                recoveryMissing = true
            }
        } catch {
            selfHealLog("接管态恢复副本读取失败(\(error))")
        }
        if primaryMissing && recoveryMissing { return .missing }
        selfHealLog("接管态主副清单均不可恢复，保留证据并 deferred；绝不猜测 loopback 代理所有权")
        return .invalid
    }

    /// 编码并原子持久化接管态。调用方决定失败时是否允许任何后续系统写入。
    private func persistTakeover(snapshot: SystemProxySnapshot, kernelPort: Int, kernelPID: Int32,
                                kernelExecutablePath: String) throws {
        let state = TakeoverState(snapshot: snapshot, kernelPort: kernelPort, kernelPID: kernelPID,
                                  kernelExecutablePath: kernelExecutablePath,
                                  active: true, takeoverAt: Date().timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try stateStore.save(data)
    }

    /// 清除持久化接管态(幂等)。
    private func clearTakeover() throws {
        try stateStore.clear()
    }

    /// 有界轮询直到 REST 可读到 mixed-port(内核重启后控制面就绪),返回端口;超时返回 nil。
    /// 用于自愈恢复接管:重启内核后要读到活的 mixed-port 才能把系统代理指向存活端口。
    private func pollForMixedPort(attempts: Int = 25, interval: TimeInterval = 0.2) -> Int? {
        for _ in 0..<attempts {
            if let cfg = try? restClient.configs(), let port = cfg.mixedPort { return port }
            Thread.sleep(forTimeInterval: interval)
        }
        return nil
    }

    /// 有界等待被 reap 的孤儿彻底消失(端口随之释放),便于新内核干净重启。
    private func waitForOrphanGone(pid: Int32, attempts: Int = 20, interval: TimeInterval = 0.1) {
        for _ in 0..<attempts {
            if !reaper.isProcessAlive(pid: pid) { return }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// 暴露给宿主注册的能力集:
    ///   * `proxy.status`(safe 只读:内核状态);
    ///   * `proxy.license`(safe 只读:随包内核的版本/许可证/GPL 全文路径/源码地址/子进程红线;cliAlias `aa proxy license`);
    ///   * `proxy.system.enable`(normal:接管系统代理;cliAlias `aa proxy on`);
    ///   * `proxy.system.disable`(normal:还原系统代理;cliAlias `aa proxy off`);
    ///   * `proxy.groups.list`(safe 只读:组/节点/当前选中;cliAlias `aa proxy groups`);
    ///   * `proxy.latency.test`(safe 只读:按组测速,超时如实标注;cliAlias `aa proxy ping`);
    ///   * `proxy.mode.set`(normal:切模式 rule/global/direct;cliAlias `aa proxy mode`);
    ///   * `proxy.node.select`(normal:按组选节点;cliAlias `aa proxy node`);
    ///   * `proxy.subscription.list`(safe:列出订阅 + 当前激活);
    ///   * `proxy.subscription.activate`(normal:激活某订阅 → 内核重载该配置生效);
    ///   * `proxy.subscription.update`(normal:更新已有源,零确认 + 失败回滚);
    ///   * `proxy.subscription.add`(dangerous:新增/替换订阅源,须经宿主 GUI 最终确认)。
    /// handler 每次调用时读/写「当前状态」——故内核死亡/重启、接管/还原、切模式/选节点、订阅切换都能被如实反映;
    /// safe/normal 均直执行(normal 零 GUI 打断),dangerous(add)的确认由 Registry.invoke 路由层强制。
    /// 内核未运行/控制面未就绪 / 订阅源不可达时,写/读经 RESTClient/SourcePort 抛错 → 收敛为业务失败(退出码 5),绝不崩。
    public func capabilities() -> [PluginCapability] {
        let processPort = self.processPort
        let restClient = self.restClient
        let subscriptionManager = self.subscriptionManager
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
            // 15 票:GPL 义务的能力面。**关于页的数据一律走这里,不许 GUI 自己去读版本号或许可证文件** ——
            //   本仓库铁律是「GUI 与 CLI 同源、薄壳无私有逻辑」;让关于页直连 MihomoKernelResource 就等于
            //   开了一条只有 GUI 能走的私有读取路径,CLI 与门禁都验不到它,GPL 义务的呈现从此无人把关。
            // **纯静态资源信息,不需要内核在跑**:handler 只读随包常量与资源路径,不碰 REST、不碰进程 ——
            //   故门禁核验它时无须起 mihomo,`.app` 里双击刚起来(内核还没就绪)也照样能看关于页。
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.license",
                    risk: .safe,
                    summary: "报告随包 mihomo 内核的版本 / 许可证 / GPL-3.0 全文路径 / 源码获取地址 / 子进程集成红线(safe 只读;纯静态资源信息,内核不必在跑)",
                    schemaSummary: "input: {} → output: { kernelVersion, license, licenseTextPath, licenseTextAvailable: Bool, sourceURL, subprocessBoundary }",
                    parameters: [],
                    cliAlias: ["proxy", "license"]
                ),
                handler: { _ in
                    let path = MihomoKernelResource.licenseTextPath
                    return .success(.object([
                        "kernelVersion": .string(MihomoKernelResource.version),
                        "license": .string(MihomoKernelResource.license),
                        "licenseTextPath": .string(path),
                        // 如实报告全文是否真的在盘上:关于页据此决定「打开全文」按钮是否可点。
                        //   licenseTextPath 是**非致命**查找(见 MihomoKernelResource.licenseTextPath):
                        //   文件不在时它返回「期望落点」而不崩,故这个布尔是真信号,不是恒 true 的摆设。
                        //   ——「打包漏了许可证」由门禁断言 APP7 在构建期抓(SHA-256 比对),不靠运行时崩溃。
                        "licenseTextAvailable": .bool(FileManager.default.fileExists(atPath: path)),
                        "sourceURL": .string(MihomoKernelResource.sourceURL),
                        "subprocessBoundary": .string(MihomoKernelResource.subprocessBoundary)
                    ]))
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
            ),
            // ============ 09 票:控制面能力包(模式/节点/组/测速)============
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.groups.list",
                    risk: .safe,
                    summary: "列出代理分组:每组的候选节点(all)与当前选中(now)(safe 只读)",
                    schemaSummary: "input: {} → output: { groups: [{ name, type, now?, all: [String] }] }",
                    parameters: [],
                    cliAlias: ["proxy", "groups"]
                ),
                handler: { _ in
                    do {
                        let groups = try restClient.groups()
                        let arr: [JSONValue] = groups.map { g in
                            .object([
                                "name": .string(g.name),
                                "type": .string(g.type),
                                "now": g.now.map { JSONValue.string($0) } ?? .null,
                                "all": .array(g.all.map { JSONValue.string($0) })
                            ])
                        }
                        return .success(.object(["groups": .array(arr)]))
                    } catch {
                        return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                                  detail: "读取代理分组失败(内核未运行或控制面未就绪): \(error)"))
                    }
                }
            ),
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.latency.test",
                    risk: .safe,
                    summary: "按组 URL 测速:返回该组逐节点延迟,超时节点如实标注(timeout=true, delayMs=null)(safe 只读)",
                    schemaSummary: "input: { group: String, timeout?: Number=5000, url?: String } → output: { group, url, results: [{ node, delayMs?, timeout }] }",
                    parameters: [
                        ParameterSpec(name: "group", type: "string", required: true, description: "目标代理分组名(必填;见 proxy.groups.list)"),
                        ParameterSpec(name: "timeout", type: "number", required: false, description: "单节点超时毫秒(可选,默认 5000)"),
                        ParameterSpec(name: "url", type: "string", required: false, description: "测试 URL(可选,默认 http://www.gstatic.com/generate_204)")
                    ],
                    cliAlias: ["proxy", "ping"]
                ),
                handler: { input in
                    let obj = input?.objectValue
                    guard let group = obj?["group"]?.stringValue else {
                        return .failure(WireError(code: WireErrorCode.invalidParams, detail: "内部错:缺 group"))
                    }
                    // 防呆(修 DoS 洞):timeout 是 JSONValue.number(Double)。裸 UDS 直连 / --timeout 1e300 可传超大**有限**数,
                    // `Int(Double)` 越界会 runtime trap → 宿主崩(客户端借此 DoS 宿主)。故在宿主侧收敛:只接受 1...600000 毫秒;
                    // 非有限 / 越界 → invalid_params(退出码 6),绝不 Int(Double) 越界。缺省(未传)→ 默认 5000。
                    var timeout = 5000
                    if case let .number(n)? = obj?["timeout"] {
                        guard n.isFinite, n >= 1, n <= 600_000 else {
                            return .failure(WireError(code: WireErrorCode.invalidParams,
                                                      detail: "timeout 须为 1..600000 毫秒的有限数,得到 \(n)(拒绝越界 Int 转换以防宿主崩溃)"))
                        }
                        timeout = Int(n)   // n 已钳在 [1,600000],Int(_:) 安全不越界
                    }
                    let url = obj?["url"]?.stringValue ?? "http://www.gstatic.com/generate_204"
                    do {
                        let results = try restClient.testGroupLatency(group: group, testURL: url, timeoutMs: timeout)
                        let arr: [JSONValue] = results.map { r in
                            .object([
                                "node": .string(r.node),
                                "delayMs": r.delayMs.map { JSONValue.number(Double($0)) } ?? .null,
                                "timeout": .bool(r.timedOut)
                            ])
                        }
                        return .success(.object([
                            "group": .string(group),
                            "url": .string(url),
                            "results": .array(arr)
                        ]))
                    } catch {
                        return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                                  detail: "按组测速失败(内核未运行/控制面未就绪/分组不存在): \(error)"))
                    }
                }
            ),
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.mode.set",
                    risk: .normal,
                    summary: "切换代理模式:rule(规则)/ global(全局)/ direct(直连)(normal 可逆,零 GUI 确认)",
                    schemaSummary: "input: { mode: rule|global|direct } → output: { mode, set: true }",
                    parameters: [
                        ParameterSpec(name: "mode", type: "string", required: true,
                                      description: "目标模式,取值 rule|global|direct(必填)",
                                      allowedValues: ["rule", "global", "direct"])
                    ],
                    cliAlias: ["proxy", "mode"]
                ),
                handler: { input in
                    // mode 的取值合法性(allowedValues)已由宿主 Registry 集中校验把关;此处 input 必含合法 mode。
                    guard let mode = input?.objectValue?["mode"]?.stringValue else {
                        return .failure(WireError(code: WireErrorCode.invalidParams, detail: "内部错:缺 mode"))
                    }
                    do {
                        try restClient.setMode(mode)
                        return .success(.object(["mode": .string(mode), "set": .bool(true)]))
                    } catch {
                        return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                                  detail: "切换模式失败(内核未运行或控制面未就绪): \(error)"))
                    }
                }
            ),
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.node.select",
                    risk: .normal,
                    summary: "按组选节点:把指定分组的当前选中切到指定节点(normal 可逆,零 GUI 确认)",
                    schemaSummary: "input: { group: String, node: String } → output: { group, node, selected: true }",
                    parameters: [
                        ParameterSpec(name: "group", type: "string", required: true, description: "目标代理分组名(必填;见 proxy.groups.list)"),
                        ParameterSpec(name: "node", type: "string", required: true, description: "要选中的节点名(必填;须为该组候选之一)")
                    ],
                    cliAlias: ["proxy", "node"]
                ),
                handler: { input in
                    let obj = input?.objectValue
                    guard let group = obj?["group"]?.stringValue, let node = obj?["node"]?.stringValue else {
                        return .failure(WireError(code: WireErrorCode.invalidParams, detail: "内部错:缺 group/node"))
                    }
                    do {
                        try restClient.selectNode(group: group, node: node)
                        return .success(.object([
                            "group": .string(group),
                            "node": .string(node),
                            "selected": .bool(true)
                        ]))
                    } catch {
                        return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                                  detail: "选择节点失败(内核未运行/控制面未就绪/分组或节点不存在): \(error)"))
                    }
                }
            ),
            // ============ 10 票:订阅管理(normal 更新 + dangerous 换源)============
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.subscription.list",
                    risk: .safe,
                    summary: "列出全部订阅(id/name/source/最近更新时间)与当前激活项(safe 只读,不碰内核)",
                    schemaSummary: "input: {} → output: { active: id?|null, subscriptions: [{ id, name, source, lastUpdatedAt? }] }",
                    parameters: []
                ),
                handler: { _ in subscriptionManager.list() }
            ),
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.subscription.activate",
                    risk: .normal,
                    summary: "激活指定订阅:让内核从该订阅的物化配置重载生效(同一时刻只激活一个;normal 零 GUI 确认)",
                    schemaSummary: "input: { id: String } → output: { id, activated: true }",
                    parameters: [
                        ParameterSpec(name: "id", type: "string", required: true, description: "要激活的订阅 id(必填;见 proxy.subscription.list)")
                    ]
                ),
                handler: { input in
                    guard let id = input?.objectValue?["id"]?.stringValue else {
                        return .failure(WireError(code: WireErrorCode.invalidParams, detail: "内部错:缺 id"))
                    }
                    return subscriptionManager.activate(id: id)
                }
            ),
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.subscription.update",
                    risk: .normal,
                    summary: "更新已有订阅源:重新拉取并物化;若为激活项则重载生效,重载失败自动回滚到旧配置(normal 零 GUI 确认)",
                    schemaSummary: "input: { id: String } → output: { id, updated: true, lastUpdatedAt }",
                    parameters: [
                        ParameterSpec(name: "id", type: "string", required: true, description: "要更新的订阅 id(必填;见 proxy.subscription.list)")
                    ]
                ),
                handler: { input in
                    guard let id = input?.objectValue?["id"]?.stringValue else {
                        return .failure(WireError(code: WireErrorCode.invalidParams, detail: "内部错:缺 id"))
                    }
                    return subscriptionManager.update(id: id)
                }
            ),
            PluginCapability(
                descriptor: CapabilityDescriptor(
                    id: "proxy.subscription.add",
                    risk: .dangerous,
                    summary: "新增或替换订阅源:拉取并物化配置,upsert 进清单(同 name 覆盖=替换源);dangerous——须经宿主 GUI 最终确认,不自动激活",
                    schemaSummary: "input: { name: String, source: String } → output: { id, name, added: true }",
                    parameters: [
                        ParameterSpec(name: "name", type: "string", required: true, description: "订阅展示名(必填;归一为 id,同名覆盖=替换源)"),
                        ParameterSpec(name: "source", type: "string", required: true, description: "订阅源(必填;file:// 路径 或 http(s):// URL)")
                    ]
                ),
                handler: { input in
                    let obj = input?.objectValue
                    guard let name = obj?["name"]?.stringValue, let source = obj?["source"]?.stringValue else {
                        return .failure(WireError(code: WireErrorCode.invalidParams, detail: "内部错:缺 name/source"))
                    }
                    return subscriptionManager.add(name: name, source: source)
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
