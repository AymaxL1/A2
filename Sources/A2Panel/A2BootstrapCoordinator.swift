// A2Panel —— 引导操作的**编排**(16 票 / ADR 0012)。零 AppKit。
//
// ============================================================================
// 它只做三件事(多一件都是薄壳铁律的缺口)
// ============================================================================
//   ① **在途守卫**:同一时刻至多一个引导操作在跑。第二次点击直接丢弃,不排队 ——
//      排队会让用户在毫不知情的情况下连装两次;而这两条命令本来就都是幂等的,重来一次的代价是零。
//   ② **线程纪律**:子进程在后台跑,状态变更与回调**一律投回主线程**。
//      状态因此是主线程独占的,不需要锁,也不会出现"菜单读到一半状态被改了"。
//   ③ **原样转达**:成功就把事实存下来,失败就把内核的话存下来。这里不重试、不兜底、不美化。
//
// 「装完要不要再问一次 status」是编排,不是业务:每次引导操作收场后重问一次
// `service status`(白名单里那条只读命令),让菜单的下一帧说的是**盘上的事实**而不是我们的推断。
//
// ============================================================================
// 为什么两个调度器要能注入
// ============================================================================
// 门禁里**绝不许**真装服务、真碰 launchctl,所以引导链路的验证只能靠注入:
//   * `runner` 注入 → 不起子进程,喂夹具 JSON;
//   * 两个调度器注入成"就地同步执行" → 用例不用 sleep、不用 expectation,断言完全确定性。
// 真跑时它们分别是后台队列与主队列,与会话那侧(专用线程 + `DispatchQueue.main.async`)同一种姿势。

import Foundation

/// 引导操作的编排者。**主线程独占**:所有状态读写都发生在 `deliver` 投递的那一侧。
public final class A2BootstrapCoordinator {

    /// 「把这块活扔到某处执行」。真跑时:后台队列 / 主队列;测试时:就地同步执行。
    public typealias Scheduler = (@escaping () -> Void) -> Void

    /// 当前的引导状态。**只在主线程读写**(菜单渲染也在主线程,故不需要锁)。
    public private(set) var state: A2BootstrapState

    private let runner: A2BootstrapRunner?
    /// `<A2_HOME>/run/kernel.sock`。**每次拿到服务态答案时顺手重看一眼这个文件在不在** ——
    /// 首启判据要它,而"启动那一刻看过一次"在一个会重连、会被引导操作改变的进程里撑不住。
    private let socketPath: String?
    private let execute: Scheduler
    private let deliver: Scheduler
    private let onChange: (A2BootstrapState) -> Void
    private var lifecycleInFlight = false
    private var isShuttingDown = false

    /// - Parameters:
    ///   - runner: 执行缝。`nil` = 没有内嵌 bin → 引导功能整体隐藏,本类型此后什么都不做。
    ///   - execute: 跑子进程的地方(默认后台队列)。
    ///   - deliver: 结果落地的地方(默认主队列)。
    ///   - onChange: 状态变了(每次都在 `deliver` 那一侧调用)。
    public init(runner: A2BootstrapRunner?,
                socketPath: String? = nil,
                firstRunPromptDismissed: Bool = false,
                execute: @escaping Scheduler = { work in
                    DispatchQueue.global(qos: .userInitiated).async(execute: work)
                },
                deliver: @escaping Scheduler = { work in DispatchQueue.main.async(execute: work) },
                onChange: @escaping (A2BootstrapState) -> Void) {
        self.runner = runner
        self.socketPath = socketPath
        self.execute = execute
        self.deliver = deliver
        self.onChange = onChange
        self.state = A2BootstrapState(
            embeddedBinAvailable: runner != nil,
            firstRunPromptDismissed: firstRunPromptDismissed,
            socketPresent: A2BootstrapCoordinator.socketExists(socketPath))
    }

    /// socket **只看文件在不在**:壳不连它、不探端口 —— 那是会话那侧的事,这里只要一个事实。
    private static func socketExists(_ path: String?) -> Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - 启动时问一次(不轮询)

    /// 问内嵌 bin 的版本 + 问一次服务态。**各一次**,此后只有用户点了才会再问
    /// (ADR 0012 第 5 条:不后台自查、不静默替换)。
    public func probe() {
        guard let runner else { return }
        run { runner.run(.version) } then: { [weak self] output in
            guard let self else { return }
            if case let .success(version) = A2BootstrapReading.version(output) {
                self.state.embeddedKernelVersion = version
            }
            // 版本问不出来**不算失败**:那只影响"要不要提示升级"这一件事,
            //   而它宁可不提示,也不该在菜单上挂一条与用户此刻要做的事无关的报错。
            self.publish()
        }
        refreshServiceStatus()
    }

    /// 重问一次服务态。**三个时刻**会调它,全部事件驱动、无定时器:
    ///   ① 启动时(`probe`);② 每次引导操作收场后;③ 面板从断连翻到连上的那一帧
    ///     (判据 `A2BootstrapDecision.shouldRefreshServiceState`,由装配层调用)。
    ///
    /// ③ 是 16 票 CR 补的:少了它,"用户在面板之外把服务装上了"这条路上,面板手里的服务态
    /// 会永久陈旧,「高级 → 停止并卸载」就一直错误地置灰在「服务尚未安装」上。
    public func refreshServiceStatus() {
        guard let runner else { return }
        run { runner.run(.serviceStatus) } then: { [weak self] output in
            guard let self else { return }
            switch A2BootstrapReading.serviceStatus(output) {
            case let .success(facts):
                self.state.serviceState = facts.state
                if facts.state == .installedNotRunning && !self.isShuttingDown {
                    self.startInstalledService()
                }
            case .failure:
                // 问不出来就是问不出来 —— 保留上一次的答案会让菜单说一句已经不成立的话。
                self.state.serviceState = nil
            }
            // 顺手把 socket 的事实也刷新到同一帧上:首启判据同时看这两样,
            //   让它们**在同一次投递里**一起变,判据就不会读到一半新一半旧的输入。
            self.state.socketPresent = A2BootstrapCoordinator.socketExists(self.socketPath)
            self.publish()
        }
        refreshMihomoStatus()
    }

    /// 用户打开 Panel 就是在显式启动 A2:只拉起已安装服务,不安装、不升级、不改 unit。
    private func startInstalledService() {
        guard let runner, !lifecycleInFlight else { return }
        lifecycleInFlight = true
        run { runner.run(.serviceStart) } then: { [weak self] output in
            guard let self else { return }
            self.lifecycleInFlight = false
            switch A2BootstrapReading.serviceChange(output) {
            case let .success(change):
                self.state.serviceState = change.status.state
                self.state.lastFailure = nil
            case let .failure(failure):
                self.state.lastFailure = failure
            }
            self.publish()
        }
    }

    /// Panel 的安全退出链:必要时先还原系统代理,再停 a2；unit 与用户数据全部保留。
    public func shutdownForQuit(restoreSystemProxy: Bool,
                                completion: @escaping (Result<Void, A2BootstrapFailure>) -> Void) {
        guard let runner, !lifecycleInFlight else {
            completion(.failure(A2BootstrapFailure(
                code: nil, message: "内嵌内核执行器不可用,无法安全停止 A2", exitCode: 5)))
            return
        }
        isShuttingDown = true
        lifecycleInFlight = true

        func finish(_ result: Result<Void, A2BootstrapFailure>) {
            self.lifecycleInFlight = false
            if case .failure = result { self.isShuttingDown = false }
            completion(result)
        }
        func stopService() {
            self.run { runner.run(.serviceStop) } then: { output in
                switch A2BootstrapReading.serviceChange(output) {
                case let .success(change):
                    self.state.serviceState = change.status.state
                    self.publish()
                    finish(.success(()))
                case let .failure(failure):
                    finish(.failure(failure))
                }
            }
        }

        guard restoreSystemProxy else { stopService(); return }
        run { runner.run(.proxyOff) } then: { output in
            switch A2BootstrapReading.commandSucceeded(output) {
            case .success: stopService()
            case let .failure(failure): finish(.failure(failure))
            }
        }
    }

    /// 重问一次 mihomo 托管事实(14 票)。时机与服务态同一套:事件驱动、无定时器。
    /// 问不出来就 `nil` —— 保留旧答案会让「尚未配置节点」这类提示说一句已经不成立的话。
    public func refreshMihomoStatus() {
        guard let runner else { return }
        run { runner.run(.mihomoStatus) } then: { [weak self] output in
            guard let self else { return }
            switch A2BootstrapReading.mihomoStatus(output) {
            case let .success(facts): self.state.mihomoFacts = facts
            case .failure:            self.state.mihomoFacts = nil
            }
            self.publish()
        }
    }

    // MARK: - 用户点了

    /// 发起一次引导操作。在途时**直接丢弃**(见文件头①)。
    ///
    /// - Parameter purge: 只有卸载用得上,而且**只可能来自用户在确认框里亲手勾的那一下**
    ///   (17 票;默认 false)。编排层对它不作任何判断 —— 勾了就换白名单里的另一条命令,
    ///   删什么、拒不拒绝全在内核里,壳不含业务逻辑(ADR 0008 第 5 条)。
    ///
    /// 返回值:真的发出去了没有。渲染器不看它 —— 它是给用例断言在途守卫用的。
    @discardableResult
    public func perform(_ action: A2BootstrapMenuAction, purge: Bool = false) -> Bool {
        guard let runner, state.inFlight == nil else { return false }
        state.inFlight = action
        // 上一次的失败在**这一次发起时**就清掉:菜单不该同时显示"安装中…"和上一轮的红字。
        state.lastFailure = nil
        // **用户已经在用引导面了** —— 首启说明框的使命(告诉他这东西是什么)就此完成。
        //   这一句是 16 票 CR 的核心修复:没有它,卸载收场 / 安装失败之后服务态回到
        //   `not_installed`,说明框会在会话中途蹦出来问「装回去?」。
        state.hasUsedBootstrap = true
        publish()

        run { runner.run(action.command(purge: purge)) } then: { [weak self] output in
            guard let self else { return }
            // 两族命令的 result 形状不同,按动作分读:服务面读 `ServiceChange`,mihomo 面读 `MihomoChange`。
            switch action {
            case .install, .uninstall:
                switch A2BootstrapReading.serviceChange(output) {
                case let .success(facts):
                    self.state.serviceState = facts.status.state
                    self.state.lastFailure = nil
                case let .failure(failure):
                    self.state.lastFailure = failure
                }
            case .restartMihomo:
                switch A2BootstrapReading.mihomoChange(output) {
                case let .success(facts):
                    self.state.mihomoFacts = facts
                    self.state.lastFailure = nil
                case let .failure(failure):
                    self.state.lastFailure = failure
                }
            }
            self.state.inFlight = nil
            self.publish()
            // 收场后重问一次盘上的事实(见文件头)。失败那一路也问 —— 装了一半是什么样,得如实说。
            self.refreshServiceStatus()
        }
        return true
    }

    /// 用户在首启说明框上点了「稍后」。**此后不再自动弹**(标记的持久化归调用方)。
    public func markFirstRunPromptDismissed() {
        state.firstRunPromptDismissed = true
        publish()
    }

    // MARK: - 助手

    /// 后台跑一条命令,结果投回 `deliver` 那一侧。
    private func run(_ work: @escaping () -> A2BootstrapRun,
                     then handle: @escaping (A2BootstrapRun) -> Void) {
        execute { [deliver] in
            let output = work()
            deliver { handle(output) }
        }
    }

    private func publish() { onChange(state) }
}
