// 16 票:**引导执行器**的纯逻辑断言(ADR 0012)。不起任何子进程、不碰 launchctl、不写真 `~/.a2`。
//
// ============================================================================
// 夹具从哪来 —— 这是本套件最要紧的一条设计
// ============================================================================
// 解析用例喂的**不是手抄的 JSON**,是 `kernel/contract/golden/` 里那批**真金标样本**
// (读法与 `Tests/A2ContractTests/GoldenSampleLoader` 同一条:`#filePath` 推仓库根,不经环境注入)。
// 于是:
//   * 内核改了 `ServiceStatusResult` 的形状 → 这批用例当场红,**不必**为它多建两个 Swift 镜像类型
//     (`ServiceStatusResult` / `ServiceChangeResult` 的镜像豁免因此得以维持,理由见 `A2ContractMirror`);
//   * 非法样本(第四种 state、缺 binPath)拿来验**fail-closed**:壳宁可报错,也不猜。
//
// 起真子进程那一关不在这里,在 `.app` 出包的 **APP11** 冒烟(只读的 `service status`,一次性 A2_HOME)。

import Foundation
import Testing
import A2Contract
import A2Panel

// ============================================================================
// 金标样本 → 一次「命令执行结果」
// ============================================================================

enum BootstrapGolden {

    /// 本文件位于 `<root>/Tests/A2PanelTests/`。
    static var goldenDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // A2PanelTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <root>
            .appendingPathComponent("kernel/contract/golden", isDirectory: true)
    }

    static func text(_ file: String) throws -> String {
        try String(contentsOf: goldenDirectory.appendingPathComponent(file), encoding: .utf8)
    }

    /// 金标里的 **result 片段** → CLI `--json` 真正吐出来的那条**成功包封**。
    /// (包封本身是已镜像的契约,双端金标钉着;这里只是把 result 装进去。)
    static func success(_ file: String, exitCode: Int32 = 0) throws -> A2BootstrapRun {
        let result = try text(file)
        let line = "{\"v\":1,\"id\":\"018f7a20-9c31-7d42-b6a8-5e1f3c8d7042\",\"ok\":true,"
            + "\"result\":\(result)}"
        return A2BootstrapRun(exitCode: exitCode, standardOutput: line)
    }

    /// 金标里那份**整条失败包封**,原样当 stdout。
    static func failure(_ file: String, exitCode: Int32) throws -> A2BootstrapRun {
        A2BootstrapRun(exitCode: exitCode, standardOutput: try text(file))
    }

    /// 卸载的变更结果。
    ///
    /// ⚠️ 如实记账:金标里**没有** uninstall 的样本(15 票补的是 install 那侧的四份)。
    ///   所以这里只手工搭 `actions` 那层外壳,`status` 那半边仍然是真金标
    ///   (`service-status-not-installed.json`)—— 契约漂了照样红。
    ///   两个动作名取自 `service-change-result.schema.json` 的封闭词表。
    static func uninstallChange() throws -> A2BootstrapRun {
        let status = try text("service-status-not-installed.json")
        let line = "{\"v\":1,\"id\":\"018f7a20-9c31-7d42-b6a8-5e1f3c8d7042\",\"ok\":true,"
            + "\"result\":{\"status\":\(status),"
            + "\"actions\":[\"supervisor_unloaded\",\"unit_removed\"]}}"
        return A2BootstrapRun(exitCode: 0, standardOutput: line)
    }
}

// ============================================================================
// ① 白名单
// ============================================================================

@Suite("16 引导白名单(ADR 0012 第 3 条:四条,一条不多)")
struct A2BootstrapWhitelistTests {

    @Test("16 白名单逐字对照 ADR 0012 —— 多一条少一条都要在这里当场红")
    func argumentsAreExactlyTheFour() {
        let table = A2BootstrapCommand.allCases.map { $0.arguments }
        #expect(table == [
            ["service", "install", "--copy-to-home", "--json"],
            ["service", "uninstall", "--json"],
            ["service", "status", "--json"],
            ["version", "--json"],
        ])
    }

    @Test("16 白名单只有四条(枚举本身就是那份名单,没有第二处构造 argv 的地方)")
    func whitelistHasFourEntries() {
        #expect(A2BootstrapCommand.allCases.count == 4)
    }

    @Test("16 每条都走机读面(`--json`),一条散文都不解析")
    func everyCommandIsMachineReadable() {
        for command in A2BootstrapCommand.allCases {
            #expect(command.arguments.contains("--json"), "\(command) 少了 --json")
        }
    }

    @Test("16 白名单里没有任何改状态的第五条(只碰 service 三条 + version)")
    func noCommandOutsideTheServiceSurface() {
        for command in A2BootstrapCommand.allCases {
            let head = command.arguments[0]
            #expect(head == "service" || head == "version",
                    "白名单里混进了 `\(head)` —— 要加命令得先改 ADR 0012")
        }
    }

    @Test("16 菜单角标 = 会跑的那条命令(去掉 --json)")
    func badgeShowsTheRealCommand() {
        #expect(A2BootstrapMenuAction.install.badge == "a2 service install --copy-to-home")
        #expect(A2BootstrapMenuAction.uninstall.badge == "a2 service uninstall")
    }

    @Test("16 两个菜单动作各自绑死一条命令(装 = 幂等 install,卸 = uninstall)")
    func menuActionsMapToCommands() {
        #expect(A2BootstrapMenuAction.install.command == .serviceInstall)
        #expect(A2BootstrapMenuAction.uninstall.command == .serviceUninstall)
    }
}

// ============================================================================
// ② 解析(喂真金标)
// ============================================================================

@Suite("16 机读面解析(夹具 = kernel/contract/golden 的真样本)")
struct A2BootstrapReadingTests {

    @Test("16 service status:三种服务态逐一解得动,binPath 取到的是盘上 unit 指的那个",
          arguments: [
            ("service-status-not-installed.json",
             A2BootstrapServiceFacts.State.notInstalled, "/Users/alice/.local/bin/a2"),
            ("service-status-installed-not-running.json",
             A2BootstrapServiceFacts.State.installedNotRunning, "/home/alice/.local/bin/a2"),
            ("service-status-running.json",
             A2BootstrapServiceFacts.State.running, "/Users/alice/.local/bin/a2"),
          ])
    func statusSamplesParse(_ file: String,
                            _ expected: A2BootstrapServiceFacts.State,
                            _ binPath: String) throws {
        let run = try BootstrapGolden.success(file)
        let facts = try #require(try A2BootstrapReading.serviceStatus(run).get())
        #expect(facts.state == expected)
        #expect(facts.binPath == binPath)
    }

    @Test("16 service install --copy-to-home:actions 原样取出(bin_copied 在场),状态跟着走")
    func copyToHomeSampleParses() throws {
        let run = try BootstrapGolden.success("service-change-copy-to-home.json")
        let change = try #require(try A2BootstrapReading.serviceChange(run).get())
        #expect(change.actions == ["bin_copied", "unit_written", "supervisor_loaded"])
        #expect(change.status.state == .running)
        // unit 指的是 `$A2_HOME/bin/a2` 的拷贝,**不是** .app 里那份(ADR 0012 第 4 条)。
        #expect(change.status.binPath == "/Users/alice/.a2/bin/a2")
    }

    @Test("16 升级样本:换了 bin 就重启,`kernel_restarted` 如实在 actions 里")
    func binUpgradedSampleParses() throws {
        let run = try BootstrapGolden.success("service-change-bin-upgraded.json")
        let change = try #require(try A2BootstrapReading.serviceChange(run).get())
        #expect(change.actions.contains("bin_copied"))
        #expect(change.actions.contains("kernel_restarted"))
    }

    @Test("16 幂等样本:actions 是空数组,壳原样呈现(不替它编一句「已完成」)")
    func idempotentSampleParses() throws {
        let run = try BootstrapGolden.success("service-change-idempotent.json")
        let change = try #require(try A2BootstrapReading.serviceChange(run).get())
        #expect(change.actions.isEmpty)
    }

    @Test("16 version:取得到版本号(升级检测的另一半)")
    func versionSampleParses() throws {
        let run = try BootstrapGolden.success("version-result.json")
        #expect(try A2BootstrapReading.version(run).get() == "0.1.0")
    }

    @Test("16 fail-closed:内核加了第四种 state 而壳没跟 —— 报错,不当成「未安装」去装一遍")
    func fourthStateIsRejected() throws {
        let run = try BootstrapGolden.success("invalid-service-status-fourth-state.json")
        guard case let .failure(failure) = A2BootstrapReading.serviceStatus(run) else {
            Issue.record("未知服务态必须被拒"); return
        }
        #expect(failure.message.contains("degraded"))
    }

    @Test("16 fail-closed:缺 binPath 的 status 直接判失败(那是 15 票新增的必填字段)")
    func missingBinPathIsRejected() throws {
        let run = try BootstrapGolden.success("invalid-service-status-missing-bin-path.json")
        guard case let .failure(failure) = A2BootstrapReading.serviceStatus(run) else {
            Issue.record("缺 binPath 必须被拒"); return
        }
        #expect(failure.message.contains("binPath"))
    }

    @Test("16 失败包封原样透传:退出码 6 + service_self_copy_unsupported(开发态那条)")
    func selfCopyUnsupportedIsCarriedThrough() throws {
        let run = try BootstrapGolden.failure("response-service-self-copy-unsupported.json", exitCode: 6)
        guard case let .failure(failure) = A2BootstrapReading.serviceChange(run) else {
            Issue.record("失败包封必须解析成失败"); return
        }
        #expect(failure.code == "service_self_copy_unsupported")
        #expect(failure.exitCode == 6)
        // 菜单里那一行:内核的原话 + 退出码语义 + 「这个 bin 不能自装」的白话。
        #expect(failure.displayLine.contains("service_self_copy_unsupported"))
        #expect(failure.displayLine.contains("退出码 6"))
        #expect(failure.displayLine.contains("这个 bin 不能自装"))
    }

    @Test("16 平台不支持那条也照样透传(壳不为任何一条失败编说辞)")
    func unsupportedPlatformIsCarriedThrough() throws {
        let run = try BootstrapGolden.failure("response-service-unsupported-platform.json", exitCode: 6)
        guard case let .failure(failure) = A2BootstrapReading.serviceStatus(run) else {
            Issue.record("失败包封必须解析成失败"); return
        }
        #expect(failure.code == "service_unsupported_platform")
    }

    @Test("16 stdout 是空的(bin 起不来 / 被拦下)—— 报错,不当成成功")
    func emptyOutputIsFailure() {
        let run = A2BootstrapRun(exitCode: -1, standardOutput: "",
                                 standardError: "dyld: Library not loaded")
        guard case let .failure(failure) = A2BootstrapReading.serviceStatus(run) else {
            Issue.record("空输出必须判失败"); return
        }
        #expect(failure.message.contains("没有机读输出"))
        #expect(failure.message.contains("dyld"), "stderr 的第一行要带出来,否则用户无从查起")
    }

    @Test("16 stdout 不是 JSON(机读面被散文污染)—— 报错")
    func proseOutputIsFailure() {
        let run = A2BootstrapRun(exitCode: 0, standardOutput: "a2 服务运行中(supervisor launchd)")
        guard case .failure = A2BootstrapReading.serviceStatus(run) else {
            Issue.record("散文必须判失败"); return
        }
    }

    // ⚠️ 名字改准了(16 票 CR):这条**不是**双端对账 —— 它读不到 `exit-codes.ts`,
    //    内核真改了语义它也不会红。它是**本表自身的变更探测器**:谁顺手改了这几句措辞,
    //    就得来这里改用例;改不动就说明他没想清楚要改什么。
    //    敢留这份拷贝的依据是 0–6 在内核侧明写「数值在此一次登记、后续不改」。
    @Test("16 退出码语义表的变更探测器(壳侧第三份拷贝;真对账要金标出机读码表,不在本票范围)")
    func exitCodeMeaningTableIsPinned() {
        #expect(A2BootstrapFailure.exitCodeMeaning(0) == "成功")
        #expect(A2BootstrapFailure.exitCodeMeaning(1) == "用法错")
        #expect(A2BootstrapFailure.exitCodeMeaning(2) == "被拒")
        #expect(A2BootstrapFailure.exitCodeMeaning(3) == "超时")
        #expect(A2BootstrapFailure.exitCodeMeaning(4) == "daemon 不可达")
        #expect(A2BootstrapFailure.exitCodeMeaning(5) == "路走通了、事没办成")
        #expect(A2BootstrapFailure.exitCodeMeaning(6) == "协议·校验错")
        #expect(A2BootstrapFailure.exitCodeMeaning(42) == "未预期的退出码")
    }
}

// ============================================================================
// ③ 定位内嵌 bin
// ============================================================================

@Suite("16 定位内嵌 bin(找不到 = 引导整块隐藏,那是常态不是异常)")
struct A2EmbeddedKernelTests {

    @Test("16 资源名与打包脚本一致(`Contents/Resources/a2`)")
    func resourceNameIsPinned() {
        #expect(A2EmbeddedKernel.resourceName == "a2")
    }

    @Test("16 没有 bundle 资源目录(swift build / swift test 的常态)→ nil")
    func noResourceDirectoryMeansHidden() {
        #expect(A2EmbeddedKernel.locate(resourceURL: nil) == nil)
    }

    @Test("16 资源目录里没有那个文件 → nil")
    func missingFileMeansHidden() throws {
        let dir = try TemporaryDirectory()
        #expect(A2EmbeddedKernel.locate(resourceURL: dir.url) == nil)
    }

    @Test("16 文件在但**没有执行位** → 也当没有(跑不起来的那份不该露出入口)")
    func nonExecutableMeansHidden() throws {
        let dir = try TemporaryDirectory()
        try dir.write(A2EmbeddedKernel.resourceName, permissions: 0o644)
        #expect(A2EmbeddedKernel.locate(resourceURL: dir.url) == nil)
    }

    @Test("16 文件在且可执行 → 给出绝对路径")
    func executableIsFound() throws {
        let dir = try TemporaryDirectory()
        let path = try dir.write(A2EmbeddedKernel.resourceName, permissions: 0o755)
        let located = try #require(A2EmbeddedKernel.locate(resourceURL: dir.url))
        #expect(located.path == path)
    }
}

/// 一次性目录(测试自己清场;**绝不碰真 `~/.a2`**)。
final class TemporaryDirectory {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("a2-panel-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    @discardableResult
    func write(_ name: String, permissions: Int) throws -> String {
        let path = url.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: permissions])
        return path
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

// ============================================================================
// ④ 编排(在途守卫 / 线程投递 / 状态流转)
// ============================================================================

/// 假 runner:按命令吐夹具,并记下**每一条真的被发出去的命令**。
final class RecordingRunner: A2BootstrapRunner {
    var responses: [A2BootstrapCommand: A2BootstrapRun] = [:]
    private(set) var issued: [A2BootstrapCommand] = []

    func run(_ command: A2BootstrapCommand) -> A2BootstrapRun {
        issued.append(command)
        return responses[command] ?? A2BootstrapRun(exitCode: 127, standardOutput: "")
    }
}

@Suite("16 引导编排(注入 runner + 同步调度 → 断言完全确定性)")
struct A2BootstrapCoordinatorTests {

    /// 就地同步执行 —— 用例因此不用 sleep、不用 expectation。
    private static let inline: A2BootstrapCoordinator.Scheduler = { work in work() }

    private func makeCoordinator(_ runner: RecordingRunner?,
                                 dismissed: Bool = false,
                                 socketPath: String? = nil)
        -> (A2BootstrapCoordinator, Box) {
        let box = Box()
        let coordinator = A2BootstrapCoordinator(
            runner: runner,
            socketPath: socketPath,
            firstRunPromptDismissed: dismissed,
            execute: Self.inline, deliver: Self.inline,
            onChange: { box.states.append($0) })
        return (coordinator, box)
    }

    final class Box { var states: [A2BootstrapState] = [] }

    @Test("16 没有内嵌 bin:嵌入态为 false,且**一条命令都不发**")
    func noRunnerMeansNoCommands() {
        let (coordinator, box) = makeCoordinator(nil)
        coordinator.probe()
        coordinator.refreshServiceStatus()
        #expect(coordinator.perform(.install) == false)
        #expect(coordinator.state.embeddedBinAvailable == false)
        #expect(box.states.isEmpty, "什么都没做就不该有状态变更")
    }

    @Test("16 启动时各问一次:version + service status,**就这两条**(不轮询)")
    func probeAsksOnce() throws {
        let runner = RecordingRunner()
        runner.responses[.version] = try BootstrapGolden.success("version-result.json")
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-not-installed.json")
        let (coordinator, _) = makeCoordinator(runner)

        coordinator.probe()

        #expect(runner.issued == [.version, .serviceStatus])
        #expect(coordinator.state.embeddedKernelVersion == "0.1.0")
        #expect(coordinator.state.serviceState == .notInstalled)
    }

    @Test("16 版本问不出来不算失败:只是不提示升级,菜单上不挂无关的红字")
    func versionFailureIsSilent() throws {
        let runner = RecordingRunner()
        runner.responses[.version] = A2BootstrapRun(exitCode: 1, standardOutput: "")
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-running.json")
        let (coordinator, _) = makeCoordinator(runner)

        coordinator.probe()

        #expect(coordinator.state.embeddedKernelVersion == nil)
        #expect(coordinator.state.lastFailure == nil)
        #expect(coordinator.state.serviceState == .running)
    }

    @Test("16 service status 读不出来:服务态清成 nil(保留旧答案 = 菜单说一句已经不成立的话)")
    func statusFailureClearsTheFact() throws {
        let runner = RecordingRunner()
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-running.json")
        let (coordinator, _) = makeCoordinator(runner)
        coordinator.refreshServiceStatus()
        #expect(coordinator.state.serviceState == .running)

        runner.responses[.serviceStatus] = A2BootstrapRun(exitCode: 4, standardOutput: "")
        coordinator.refreshServiceStatus()
        #expect(coordinator.state.serviceState == nil)
    }

    @Test("16 装一次:发的是 `service install --copy-to-home`,收场后再问一次盘上的事实")
    func installIssuesTheWhitelistedCommand() throws {
        let runner = RecordingRunner()
        runner.responses[.serviceInstall] =
            try BootstrapGolden.success("service-change-copy-to-home.json")
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-running.json")
        let (coordinator, _) = makeCoordinator(runner)

        #expect(coordinator.perform(.install) == true)

        #expect(runner.issued == [.serviceInstall, .serviceStatus])
        #expect(coordinator.state.serviceState == .running)
        #expect(coordinator.state.inFlight == nil)
        #expect(coordinator.state.lastFailure == nil)
    }

    @Test("16 卸一次:发的是 `service uninstall`,同样收场后重问")
    func uninstallIssuesTheWhitelistedCommand() throws {
        let runner = RecordingRunner()
        runner.responses[.serviceUninstall] = try BootstrapGolden.uninstallChange()
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-not-installed.json")
        let (coordinator, _) = makeCoordinator(runner)

        coordinator.perform(.uninstall)

        #expect(runner.issued == [.serviceUninstall, .serviceStatus])
        #expect(coordinator.state.serviceState == .notInstalled)
    }

    @Test("16 失败如实落地:内核的 code / message / 退出码原样进状态,**不重试**")
    func failureIsRecordedVerbatim() throws {
        let runner = RecordingRunner()
        runner.responses[.serviceInstall] =
            try BootstrapGolden.failure("response-service-self-copy-unsupported.json", exitCode: 6)
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-not-installed.json")
        let (coordinator, _) = makeCoordinator(runner)

        coordinator.perform(.install)

        let failure = try #require(coordinator.state.lastFailure)
        #expect(failure.code == "service_self_copy_unsupported")
        #expect(failure.exitCode == 6)
        // 只发了一次 install(外加收场那次 status)—— 失败不重试。
        #expect(runner.issued.filter { $0 == .serviceInstall }.count == 1)
    }

    @Test("16 在途守卫:第二次点击直接丢弃(不排队 —— 排队 = 用户毫不知情地连装两次)")
    func inFlightGuardDropsTheSecondClick() throws {
        // 让第一条 install 在"执行中"停住:调度器把活攥在手里,不跑。
        var pending: [() -> Void] = []
        let runner = RecordingRunner()
        runner.responses[.serviceInstall] =
            try BootstrapGolden.success("service-change-install.json")
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-running.json")
        let coordinator = A2BootstrapCoordinator(
            runner: runner, socketPath: nil,
            execute: { work in pending.append(work) },
            deliver: Self.inline,
            onChange: { _ in })

        #expect(coordinator.perform(.install) == true)
        #expect(coordinator.state.inFlight == .install)
        // 在途期间的第二次点击(以及点了别的引导项)一律不发。
        #expect(coordinator.perform(.install) == false)
        #expect(coordinator.perform(.uninstall) == false)
        #expect(runner.issued.isEmpty, "活还攥在调度器手里,一条都不该发出去")

        while !pending.isEmpty { pending.removeFirst()() }
        #expect(coordinator.state.inFlight == nil)
        #expect(runner.issued == [.serviceInstall, .serviceStatus])
        // 收场之后又能点了。
        #expect(coordinator.perform(.install) == true)
    }

    @Test("16 线程纪律:命令在 execute 那侧跑,状态只在 deliver 那侧变")
    func workRunsOnExecuteAndLandsOnDeliver() throws {
        var executed = 0, delivered = 0
        let runner = RecordingRunner()
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-running.json")
        let coordinator = A2BootstrapCoordinator(
            runner: runner, socketPath: nil,
            execute: { work in executed += 1; work() },
            deliver: { work in delivered += 1; work() },
            onChange: { _ in })

        coordinator.refreshServiceStatus()

        #expect(executed == 1)
        #expect(delivered == 1)
        #expect(coordinator.state.serviceState == .running)
    }

    @Test("16 发起时清掉上一轮的失败(菜单不该同时显示「安装中…」和上一轮的红字)")
    func performClearsTheStaleFailure() throws {
        var pending: [() -> Void] = []
        let runner = RecordingRunner()
        runner.responses[.serviceInstall] =
            try BootstrapGolden.failure("response-service-operation-failed.json", exitCode: 5)
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-not-installed.json")
        let coordinator = A2BootstrapCoordinator(
            runner: runner, socketPath: nil,
            execute: { work in pending.append(work) }, deliver: Self.inline,
            onChange: { _ in })

        coordinator.perform(.install)
        while !pending.isEmpty { pending.removeFirst()() }
        #expect(coordinator.state.lastFailure != nil)

        coordinator.perform(.install)
        #expect(coordinator.state.lastFailure == nil, "刚发起时旧失败就该清掉")
        #expect(coordinator.state.inFlight == .install)
    }

    @Test("16 「稍后」写进状态(标记的持久化归调用方,判据只认这一个布尔)")
    func dismissMarksTheState() {
        let runner = RecordingRunner()
        let (coordinator, _) = makeCoordinator(runner)
        #expect(coordinator.state.firstRunPromptDismissed == false)
        coordinator.markFirstRunPromptDismissed()
        #expect(coordinator.state.firstRunPromptDismissed == true)
    }

    @Test("16 「已谢绝」标记进得来(上次启动点过「稍后」,这次启动就不该再弹)")
    func dismissedFlagIsSeeded() {
        let (coordinator, _) = makeCoordinator(RecordingRunner(), dismissed: true)
        #expect(coordinator.state.firstRunPromptDismissed == true)
    }

    @Test("16 socket 探测只看文件在不在,且**跟着每次 service status 一起刷新**(不是启动时看一眼就算)")
    func socketPresenceRefreshesWithServiceStatus() throws {
        let dir = try TemporaryDirectory()
        let socket = dir.url.appendingPathComponent("kernel.sock").path
        let runner = RecordingRunner()
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-not-installed.json")
        let (coordinator, _) = makeCoordinator(runner, socketPath: socket)

        // 启动那一刻文件还不在。
        #expect(coordinator.state.socketPresent == false)

        // 有人把内核跑起来了 → socket 落地 → 下一次问服务态时,这个事实必须跟着更新。
        try dir.write("kernel.sock", permissions: 0o600)
        coordinator.refreshServiceStatus()
        #expect(coordinator.state.socketPresent == true,
                "socket 的事实必须与服务态在同一次投递里一起变,否则首启判据会读到一半新一半旧")

        // 反向也成立:socket 没了(内核停了),下一次刷新如实翻回去。
        try FileManager.default.removeItem(atPath: socket)
        coordinator.refreshServiceStatus()
        #expect(coordinator.state.socketPresent == false)
    }

    // ========================================================================
    // 16 票 CR:首启说明框不许在会话中途蹦出来
    // ========================================================================

    @Test("16 用户一点引导项,`hasUsedBootstrap` 立刻置位(不必等它跑完 —— 人已经在用这个面了)")
    func performLatchesImmediately() throws {
        var pending: [() -> Void] = []
        let runner = RecordingRunner()
        runner.responses[.serviceInstall] =
            try BootstrapGolden.success("service-change-install.json")
        let coordinator = A2BootstrapCoordinator(
            runner: runner, socketPath: nil,
            execute: { work in pending.append(work) }, deliver: Self.inline,
            onChange: { _ in })

        #expect(coordinator.state.hasUsedBootstrap == false)
        coordinator.perform(.install)
        #expect(coordinator.state.hasUsedBootstrap == true, "发起那一刻就该置位,而不是收场时")
        pending.removeAll()
    }

    @Test("16 回归:**从「高级」卸掉服务之后,首启说明框不许再弹**(服务态确实回到了未安装)")
    func uninstallDoesNotResurrectTheFirstRunPrompt() throws {
        let runner = RecordingRunner()
        runner.responses[.serviceUninstall] = try BootstrapGolden.uninstallChange()
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-not-installed.json")
        // 一台"装着服务、socket 在、没谢绝过"的机器:卸载之前判据本来就不成立。
        let (coordinator, _) = makeCoordinator(runner)

        coordinator.perform(.uninstall)

        // 卸完之后,首启判据的另外四个条件**全部重新成立**了 ——
        //   有内嵌 bin、没谢绝过、服务未安装、socket 不在。少了「用过引导面」那一条,
        //   说明框会当场蹦出来问「装回去?」。这条断言就是钉住它。
        #expect(coordinator.state.serviceState == .notInstalled)
        #expect(coordinator.state.socketPresent == false)
        #expect(coordinator.state.firstRunPromptDismissed == false)
        #expect(coordinator.state.embeddedBinAvailable == true)
        #expect(coordinator.state.shouldPresentFirstRunPrompt == false,
                "刚被用户亲手卸掉的东西,壳不许回头问他要不要装回去")
    }

    @Test("16 回归:安装失败之后也不许弹(服务态同样停在未安装)")
    func failedInstallDoesNotResurrectTheFirstRunPrompt() throws {
        let runner = RecordingRunner()
        runner.responses[.serviceInstall] =
            try BootstrapGolden.failure("response-service-self-copy-unsupported.json", exitCode: 6)
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-not-installed.json")
        let (coordinator, _) = makeCoordinator(runner)

        coordinator.perform(.install)

        #expect(coordinator.state.lastFailure != nil)
        #expect(coordinator.state.serviceState == .notInstalled)
        #expect(coordinator.state.shouldPresentFirstRunPrompt == false,
                "刚失败一次就再弹一遍说明框,是在追着用户问")
    }

    @Test("16 但「还没动过手」的机器照弹:置位只在用户真的点过之后")
    func untouchedMachineStillPrompts() throws {
        let runner = RecordingRunner()
        runner.responses[.version] = try BootstrapGolden.success("version-result.json")
        runner.responses[.serviceStatus] =
            try BootstrapGolden.success("service-status-not-installed.json")
        let (coordinator, _) = makeCoordinator(runner)

        coordinator.probe()

        #expect(coordinator.state.hasUsedBootstrap == false, "启动时问一问不算「用过引导面」")
        #expect(coordinator.state.shouldPresentFirstRunPrompt == true)
    }
}
