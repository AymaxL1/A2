// 04 票 —— 机械执行器:行为断言 + **源码级反向断言**。
//
// ============================================================================
// 为什么这一族测试里没有一次真的系统调用
// ============================================================================
// 真调一次 `NSWorkspace.setDefaultApplication(…)` 会**真的改掉跑门禁这台机器的默认浏览器**,
// 并在跑测试的人脸上弹两个系统框。所以执行动作全程走 `A2DefaultHandlerSetting` 协议,
// 这里注入的是一个只会说话不会动手的假件 —— 真机弹框那趟旅程归 06 票的人工项。
//
// ============================================================================
// 两类断言各挡一类事故
// ============================================================================
//   * **行为**:帧进来 → 逐 scheme 调 → 收齐了才回执 → NSError 原样带出来。
//     最容易悄悄错掉的是"收齐"那一步:两个 scheme 是两次独立的异步回调,
//     只报先回来的那一个,或者同一条回执发两遍,都不会让别的断言变红。
//   * **源码**:执行器代码里**不许出现旧 LS API 的记号**,也不许出现任何"判断这是不是用户取消"
//     的写法。后者是 04 票的零判断红线:壳一旦认得 domain/code,就等于让它替内核决定收场。

import Foundation
import Testing
import A2Contract
@testable import A2Panel

@Suite("04 机械执行器(执行指令帧 → 系统 API → 原样回执)")
struct A2URLRouterExecutorTests {

    // MARK: - 假件

    /// 一个**不会动手**的默认 handler 设置件:按剧本立刻回调,并记下被调过什么。
    private final class FakeSetter: A2DefaultHandlerSetting, @unchecked Sendable {
        /// bundle id → app 位置。查不到 = 目标 app 不在这台机器上。
        let installed: [String: URL]
        /// scheme → 这次调用要回的错误(nil = 成了)。
        let errors: [String: NSError]
        /// 是否**不回调**(验"壳不自己设第二个钟":内核那侧的窗兜着,壳这边就是不收场)。
        let silent: Bool

        private let lock = NSLock()
        private(set) var calls: [(application: URL, scheme: String)] = []

        init(installed: [String: URL], errors: [String: NSError] = [:], silent: Bool = false) {
            self.installed = installed
            self.errors = errors
            self.silent = silent
        }

        func locateApplication(bundleID: String) -> URL? { installed[bundleID] }

        func setDefaultApplication(
            at applicationURL: URL, toOpenURLsWithScheme scheme: String,
            completion: @escaping @Sendable ((any Error)?) -> Void
        ) {
            lock.lock()
            calls.append((applicationURL, scheme))
            lock.unlock()
            guard !silent else { return }
            completion(errors[scheme])
        }
    }

    private static let panelURL = URL(fileURLWithPath: "/Applications/A2 Panel.app")

    private static func command(
        id: String = "exec-1", bundleID: String = "com.a2.panel",
        schemes: [A2URLRouterScheme] = [.http, .https]
    ) -> A2URLRouterExecuteCommand {
        A2URLRouterExecuteCommand(
            id: id, op: .setDefaultHandler, schemes: schemes, bundleID: bundleID, timeoutSeconds: 120)
    }

    /// 跑一帧,把回执取出来(假件是同步回调的,所以这里不必等)。
    private func run(
        _ command: A2URLRouterExecuteCommand, with setter: FakeSetter
    ) -> A2URLRouterExecutorReportParams? {
        let box = Box()
        A2URLRouterExecutorRunner(setter: setter).run(command) { box.value = $0 }
        return box.value
    }

    private final class Box: @unchecked Sendable {
        var value: A2URLRouterExecutorReportParams?
    }

    // MARK: - 行为

    @Test("两个 scheme 都成 → outcome=confirmed,逐 scheme 各一条 ok")
    func bothSchemesSucceed() throws {
        let setter = FakeSetter(installed: ["com.a2.panel": Self.panelURL])

        let report = try #require(run(Self.command(), with: setter))

        #expect(report.execution == "exec-1")
        #expect(report.outcome == .confirmed)
        #expect(report.perScheme[.http]?.ok == true)
        #expect(report.perScheme[.https]?.ok == true)
        // 帧上写了哪些 scheme 就调哪些,一次不多一次不少,而且**解析出来的 app 位置是同一个**。
        #expect(setter.calls.map(\.scheme) == ["http", "https"])
        #expect(setter.calls.allSatisfy { $0.application == Self.panelURL })
    }

    @Test("NSError **原样**回传:domain/code/描述三件套一个字不改、不翻译、不归类")
    func nsErrorIsSerializedVerbatim() throws {
        let failure = NSError(
            domain: "NSOSStatusErrorDomain", code: -10814,
            userInfo: [NSLocalizedDescriptionKey: "假件造的一条错误"])
        let setter = FakeSetter(installed: ["com.a2.panel": Self.panelURL], errors: ["https": failure])

        let report = try #require(run(Self.command(), with: setter))

        #expect(report.perScheme[.http]?.ok == true)
        let error = try #require(report.perScheme[.https]?.error)
        #expect(error.domain == "NSOSStatusErrorDomain")
        #expect(error.code == -10814)
        #expect(error.description == "假件造的一条错误")
    }

    @Test("一成一败:壳只说「没全成」(outcome=error),**不判断这是不是用户取消**")
    func partialFailureIsReportedAsErrorNotDenied() throws {
        // 这一条是 04 票零判断红线在行为上的落点:分辨"取消"要认得 domain/code,而那两个值
        // 要到 06 票真机才拿得到(spec §11)。在那之前壳**不猜** —— 收场归内核的映射表裁。
        let setter = FakeSetter(
            installed: ["com.a2.panel": Self.panelURL],
            errors: ["https": NSError(domain: "任意域", code: 1)])

        let report = try #require(run(Self.command(), with: setter))

        #expect(report.outcome == .error)
        #expect(report.outcome != .denied, "壳不许自作主张把失败判成「用户取消」")
        // 但**成了的那一半照样如实报**:内核靠它算出「只成了一半」并给补齐命令。
        #expect(report.perScheme[.http]?.ok == true)
    }

    @Test("目标 app 不在 → 一个系统 API 都不调、perScheme 是空的(spec §5「前置报错」的落点)")
    func missingTargetSkipsEverySystemCall() throws {
        let setter = FakeSetter(installed: [:])

        let report = try #require(run(Self.command(bundleID: "com.nonexistent.browser"), with: setter))

        #expect(report.outcome == .error)
        #expect(report.error?.contains("目标 app 不存在") == true)
        // **空表 = 压根没轮到**,与 `{ok:false}`(轮到了、没成)是两件事。
        #expect(report.perScheme[.http] == nil)
        #expect(report.perScheme[.https] == nil)
        #expect(setter.calls.isEmpty, "解析不到目标就不该调任何系统 API,更不该弹框")
    }

    @Test("收齐了才收场:只回了一个 scheme 时**一条回执都不发**(内核那侧的窗兜着)")
    func reportsOnlyAfterEverySchemeSettles() {
        // 只有 http 会回调:https 那一路永远悬着。壳**不自己设第二个钟** —— 一件事只该有一个人计时,
        // 那个人是内核(120s)。壳这边宁可什么都不说,也不发一条只说了一半的回执。
        let setter = HalfSilentSetter(application: Self.panelURL)
        let box = Box()
        A2URLRouterExecutorRunner(setter: setter).run(Self.command()) { box.value = $0 }
        #expect(box.value == nil)
    }

    @Test("回执**恰好一次**:两个 scheme 的 completion 都回来了也只发一条")
    func settlesExactlyOnce() {
        let setter = FakeSetter(installed: ["com.a2.panel": Self.panelURL])
        let counter = Counter()
        A2URLRouterExecutorRunner(setter: setter).run(Self.command()) { _ in counter.bump() }
        #expect(counter.value == 1)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @Test("单 scheme 的指令帧也照做(帧上写什么就是什么,壳不替内核补一个)")
    func honoursWhateverSchemesTheFrameNames() throws {
        let setter = FakeSetter(installed: ["com.a2.panel": Self.panelURL])

        let report = try #require(run(Self.command(schemes: [.https]), with: setter))

        #expect(setter.calls.map(\.scheme) == ["https"])
        #expect(report.outcome == .confirmed)
        // 没被点名的那个 scheme **不出现在表里**:壳没做那件事,就不该报它的结果。
        #expect(report.perScheme[.http] == nil)
    }

    /// 只回 http、不回 https 的设置件(验"收齐才收场")。
    private final class HalfSilentSetter: A2DefaultHandlerSetting, @unchecked Sendable {
        private let application: URL
        init(application: URL) { self.application = application }
        func locateApplication(bundleID: String) -> URL? { application }
        func setDefaultApplication(
            at applicationURL: URL, toOpenURLsWithScheme scheme: String,
            completion: @escaping @Sendable ((any Error)?) -> Void
        ) {
            if scheme == "http" { completion(nil) }
        }
    }

    // MARK: - 投影:指令帧不改任何状态

    @Test("投影:执行指令帧只产出一个「去做」的 effect,**一个字段都不改**")
    func executeEventChangesNothingInState() {
        var state = A2PanelState()
        let before = state
        let command = Self.command()

        let effect = A2PanelProjection.apply(
            .urlRouterExecute(at: "2026-09-04T02:15:00.000Z", command: command), to: &state)

        #expect(effect == .executeURLRouter(command))
        // 「内核让壳去干一件事」不是「壳的状态变了」:系统默认浏览器的权威记录在内核那边
        // (`url-router.status` 现读 LaunchServices),壳存一份只会存出第二个可能过时的真相。
        #expect(state == before)
    }

    // MARK: - 源码级反向断言(挡的是"后来的人不能怎么写")

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // A2PanelTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <root>
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 旧 LS API 那一族的记号。用它们**看不出任何症状**:命令会"成功",而系统状态没变
    /// (返回码即时给出、不含用户在弹框上点了什么)—— 那正是最坏的一种失效。
    private static let legacyLaunchServicesMarkers = [
        "LSSetDefaultHandlerForURLScheme",
        "LSSetDefaultRoleHandlerForContentType",
        "LSCopyDefaultHandlerForURLScheme",
        "kLSRolesAll",
    ]

    @Test("04 红线:执行器那两个文件里**没有一个**旧 LS API 的记号(01 研究票:结果不可感知)")
    func legacyLaunchServicesAPIsAreAbsent() throws {
        for file in ["Sources/A2Panel/A2URLRouterExecutor.swift",
                     "Sources/A2PanelMacOS/A2URLRouterMacOS.swift"] {
            let text = try Self.source(file)
            for marker in Self.legacyLaunchServicesMarkers where marker != "LSSetDefaultHandlerForURLScheme" {
                #expect(!text.contains(marker), "\(file) 里出现了 \(marker) —— 旧 LS API 全族禁用")
            }
            // 头一个记号在两份文件的**注释里**都作为"禁什么"出现过,所以判据要更准:
            // 它不许出现在**调用位置**(后面跟一个左括号)。
            #expect(!text.contains("LSSetDefaultHandlerForURLScheme("),
                    "\(file) 里出现了对旧 LS API 的调用 —— 它的结果不可感知,系统弹框就当不成确认器")
        }
    }

    @Test("04 红线:执行器走的是**新 API**,而且理由写在源码里")
    func newWorkspaceAPIIsTheOnlyPath() throws {
        let text = try Self.source("Sources/A2PanelMacOS/A2URLRouterMacOS.swift")
        #expect(text.contains("setDefaultApplication(at:"),
                "执行器必须走 NSWorkspace 的新 API(completion 在用户点完弹框之后才回调)")
        #expect(text.contains("点完系统弹框之后"), "为什么必须是新 API,这条理由要写在源码里")
    }

    /// 「壳开始判断这是不是用户取消」就绕不开的写法。命中任意一条 = 零判断红线破了。
    private static let verdictMarkers = [
        "NSUserCancelledError",   // 认这个码 = 壳在替内核判「用户取消」
        "kLSApplicationNotFound",
        ".denied",                // 壳只会报 confirmed / error(denied 归 06 票回填,且要过 CR)
        ".timeout",               // 计时归内核,壳不设第二个钟
        "NSOSStatusErrorDomain",  // 认某个具体的域 = 同上
    ]

    @Test("04 零判断:执行器不判断 NSError 是什么、不自报 denied/timeout(收场归内核裁)")
    func executorNeverJudgesTheOutcome() throws {
        let text = try Self.source("Sources/A2Panel/A2URLRouterExecutor.swift")
        for marker in Self.verdictMarkers {
            #expect(!text.contains(marker),
                    "A2URLRouterExecutor.swift 里出现了 \(marker) —— 壳一旦认得它,就等于替内核决定了收场")
        }
        // 反面:那两个词的**存在本身**是契约的一部分(06 票回填之后要用),所以它们在契约层有,
        // 只是不该在壳的执行路径上被消费。
        #expect(A2URLRouterExecutionOutcome.allCases.map(\.rawValue).contains("denied"))
        #expect(A2URLRouterExecutionOutcome.allCases.map(\.rawValue).contains("timeout"))
    }

    @Test("04 边界:执行器不解析 URL、不认得任何 bundle id、不读内核文件")
    func executorKnowsNothingItShouldNotKnow() throws {
        let text = try Self.source("Sources/A2Panel/A2URLRouterExecutor.swift")
        for marker in ["com.a2.panel", "com.apple.Safari", "URLComponents", "A2_HOME", "url-router.json"] {
            #expect(!text.contains(marker),
                    "A2URLRouterExecutor.swift 里出现了 \(marker) —— 接管的目标由内核在帧上给,壳不认得任何 bundle id")
        }
    }
}
