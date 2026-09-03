// 03 票 —— **URL 转发 / 降级兜底 / 节流通知**的纯逻辑断言,外加四条硬边界的反向证明。
//
// 缝在 `A2URLForwarder`:四个注入口(转发通道、兜底执行件、通知件、持久化)全是假件,于是
//   * 门禁**永远不会**真开一个浏览器窗口、真弹一条系统通知、真写 `com.a2.panel` 的 UserDefaults;
//   * "内核不可达"这种最要紧的分支不必真去杀一个内核就能逐条验。
//
// 真机那半边(系统真把链接交给 A2 Panel、真弹通知)是人工验收项(spec §13 第 3 条),
// 与本组不重叠:这里钉的是**壳收到 URL 之后的每一条分支**,那里看的是「链接真的开了没有」。

import Foundation
import Testing
import A2Contract
import A2Panel

// ============================================================================
// 假件
// ============================================================================

/// 假的转发通道:记下**原样字符串**,按脚本收场。
private final class FakeRouter: A2URLRouteForwarding {
    var forwarded: [String] = []
    var outcome: A2URLRouteOutcome = .routed
    /// 不收场(模拟「发出去了还没回来」)—— 用来验壳悬着的时候不会自作主张兜底。
    var settles = true

    func routeURL(_ url: String, completion: @escaping (A2URLRouteOutcome) -> Void) {
        forwarded.append(url)
        if settles { completion(outcome) }
    }
}

/// 假的兜底执行件:记下每一次交接,只认 `resolvable` 里那些 bundle id。
private final class FakeOpener: A2FallbackBrowserOpening {
    var resolvable: Set<String> = ["com.apple.Safari"]
    var opened: [(url: String, bundleID: String)] = []
    var systemDefault: [String] = []
    var systemDefaultSucceeds = true

    func open(_ url: String, withBundleID bundleID: String) -> Bool {
        guard resolvable.contains(bundleID) else { return false }
        opened.append((url: url, bundleID: bundleID))
        return true
    }

    func openWithSystemDefault(_ url: String) -> Bool {
        systemDefault.append(url)
        return systemDefaultSucceeds
    }
}

/// 假的通知件:只数数、只记文案(不碰 UNUserNotificationCenter)。
private final class FakeNotifier: A2URLRouterNotifying {
    var notices: [(title: String, body: String)] = []
    func notifyFallback(title: String, body: String) { notices.append((title: title, body: body)) }
}

/// 假的持久化:内存字典 + 写次数(验「只在变了的时候写」)。
private final class FakeStore: A2URLRouterDefaultsStoring {
    var value: String?
    var writes = 0
    init(_ value: String? = nil) { self.value = value }
    func fallbackBrowserBundleID() -> String? { value }
    func setFallbackBrowserBundleID(_ bundleID: String) { value = bundleID; writes += 1 }
}

/// 可拨的表(去重窗与熄火窗都要精确验)。
private final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// 壳日志的收集处(脱敏断言的对象:这里面**永远不该出现 URL**)。
private final class LogBox {
    var lines: [String] = []
    var joined: String { lines.joined(separator: "\n") }
}

/// 一套接好的假件 + 被测对象。
private final class Rig {
    let router: FakeRouter
    let opener: FakeOpener
    let notifier: FakeNotifier
    let store: FakeStore
    let clock: FakeClock
    let logs: LogBox
    let forwarder: A2URLForwarder

    init(stored: String? = nil) {
        let router = FakeRouter()
        let opener = FakeOpener()
        let notifier = FakeNotifier()
        let store = FakeStore(stored)
        let clock = FakeClock()
        let logs = LogBox()
        self.router = router
        self.opener = opener
        self.notifier = notifier
        self.store = store
        self.clock = clock
        self.logs = logs
        self.forwarder = A2URLForwarder(
            router: router, opener: opener, notifier: notifier, defaults: store,
            log: { logs.lines.append($0) }, now: { clock.now })
    }
}

@Suite("03 URL 转发 / 降级兜底 / 节流通知")
struct A2URLForwarderTests {

    /// 一份「已经拿到过快照」的状态(connected + urlRouter 节)。
    private static func connected(_ bundleID: String = "com.google.Chrome") -> A2PanelState {
        A2PanelState(connection: .connected,
                     urlRouter: A2URLRouterSnapshot(fallbackBrowserBundleID: bundleID))
    }

    private static func disconnected(_ bundleID: String = "com.google.Chrome") -> A2PanelState {
        A2PanelState(connection: .disconnected("与内核断开,正在重连"),
                     urlRouter: A2URLRouterSnapshot(fallbackBrowserBundleID: bundleID))
    }

    // ========================================================================
    // 边界①:原样转发 —— 壳不解析、不改写 URL
    // ========================================================================

    @Test("03 转发的是**原样字符串**:query / fragment / 空格 / 中文 / 已编码的 # 一个字节都不动")
    func forwardsVerbatim() {
        let cases = [
            "https://example.com/a?q=hello world&x=1#片段",
            "https://Example.COM/PATH/../x?a=%23&b=#frag%2Fment",
            "http://user:pw@example.com:8080/a%20b?x=1#",
            "HTTPS://claude.ai/chat?token=abc123#top",
            "customscheme://not-even-http/xyz",
        ]
        for raw in cases {
            let rig = Rig()
            rig.forwarder.handle(raw)
            #expect(rig.router.forwarded == [raw], "转发的必须与收到的逐字节相同")
        }
    }

    @Test("03 内核接走了:壳什么都不做 —— 不兜底、不通知(绝不「保险起见再开一次」)")
    func routedDoesNothingElse() {
        let rig = Rig()
        rig.router.outcome = .routed

        rig.forwarder.observe(Self.connected())
        rig.forwarder.handle("https://example.com/a")

        #expect(rig.opener.opened.isEmpty)
        #expect(rig.opener.systemDefault.isEmpty)
        #expect(rig.notifier.notices.isEmpty)
    }

    @Test("03 壳的日志里**没有 URL**:query 与 fragment 尤其(脱敏在源头做,不靠过滤器)")
    func logsNeverCarryTheURL() {
        let rig = Rig()
        rig.router.outcome = .unreachable("连不上")
        let url = "https://example.com/secret?token=abc123#fragment-secret"

        rig.forwarder.observe(Self.connected())
        rig.forwarder.handle(url)

        #expect(!rig.logs.lines.isEmpty, "该有日志(否则这条断言是空的)")
        #expect(!rig.logs.joined.contains("token=abc123"))
        #expect(!rig.logs.joined.contains("fragment-secret"))
        #expect(!rig.logs.joined.contains("example.com"))
    }

    // ========================================================================
    // 边界③:唯一分支条件 = 内核可达与否
    // ========================================================================

    @Test("03 内核不可达:用快照落盘的兜底浏览器把**同一条 URL** 交出去,并弹一条通知")
    func unreachableFallsBackAndNotifies() {
        let rig = Rig()
        rig.opener.resolvable = ["com.google.Chrome", "com.apple.Safari"]
        rig.router.outcome = .unreachable("超时")
        let url = "https://example.com/a?q=1#f"

        rig.forwarder.observe(Self.connected("com.google.Chrome"))   // 落盘一次
        rig.forwarder.observe(Self.disconnected())                   // 内核走了
        rig.forwarder.handle(url)

        #expect(rig.opener.opened.count == 1)
        #expect(rig.opener.opened.first?.bundleID == "com.google.Chrome")
        #expect(rig.opener.opened.first?.url == url, "兜底交出去的也必须是原样那一条")
        #expect(rig.notifier.notices.count == 1)
    }

    @Test("03 内核在、但这次调用被拒:照样兜底(链接永远打得开),但**不弹**「内核未运行」")
    func refusedFallsBackWithoutNotice() {
        let rig = Rig()
        rig.router.outcome = .refused(code: "url_router_open_failed", message: "那个 app 不在")

        rig.forwarder.observe(Self.connected())
        rig.forwarder.handle("https://example.com/a")

        #expect(rig.opener.opened.count == 1)
        #expect(rig.notifier.notices.isEmpty, "内核明明在跑,弹「内核未运行」就是撒谎")
    }

    @Test("03 转发还没收场时壳不自作主张:没有兜底、没有通知(收场由发起方计时,见 A2URLRouteTicket)")
    func pendingForwardDoesNotFallBack() {
        let rig = Rig()
        rig.router.settles = false

        rig.forwarder.handle("https://example.com/a")

        #expect(rig.router.forwarded.count == 1)
        #expect(rig.opener.opened.isEmpty)
        #expect(rig.notifier.notices.isEmpty)
    }

    // ========================================================================
    // 节流通知(spec §9 的降级故事)
    // ========================================================================

    @Test("03 节流:宕机后**首次**兜底发通知,后续静默;重连后再宕机再发一次")
    func noticeIsThrottledPerOutage() {
        let rig = Rig()
        rig.router.outcome = .unreachable("连不上")
        rig.forwarder.observe(Self.connected())

        for index in 0..<3 {
            rig.clock.advance(1)
            rig.forwarder.handle("https://example.com/\(index)")
        }
        #expect(rig.notifier.notices.count == 1)

        // 内核回来了(会话重新拿到快照 = 断→连那一帧)。
        rig.forwarder.observe(Self.disconnected())
        rig.forwarder.observe(Self.connected())

        // 又宕了:通知再来一条(且仍然只有一条)。
        rig.clock.advance(1)
        rig.forwarder.handle("https://example.com/again-1")
        rig.clock.advance(1)
        rig.forwarder.handle("https://example.com/again-2")
        #expect(rig.notifier.notices.count == 2)
    }

    @Test("03 节流位只认「断→连」那一帧:连着的状态更新一遍遍来也不会把它蹭掉")
    func repeatedConnectedStatesDoNotResetThrottle() {
        let rig = Rig()
        rig.router.outcome = .unreachable("连不上")
        rig.forwarder.observe(Self.connected())

        rig.forwarder.handle("https://example.com/1")
        // 连接态没变(还是 connected)的状态更新:代理域刷新、审计事件都会走这条路。
        rig.forwarder.observe(Self.connected())
        rig.forwarder.observe(Self.connected())
        rig.clock.advance(1)
        rig.forwarder.handle("https://example.com/2")

        #expect(rig.notifier.notices.count == 1)
    }

    @Test("03 通知文案钉死:两行合起来正是 spec §7 那一句")
    func noticeWordingIsPinned() {
        #expect("\(A2URLRouter.unreachableNoticeTitle),\(A2URLRouter.unreachableNoticeBody)"
                == "A2 内核未运行,链接已交给兜底浏览器")
    }

    // ========================================================================
    // 边界④:兜底身份只来自快照(+ 硬编码最终缺省)
    // ========================================================================

    @Test("03 快照落盘:兜底身份进 UserDefaults,且**只在变了的时候写**")
    func snapshotIsPersistedOnce() {
        let rig = Rig()

        rig.forwarder.observe(Self.connected("com.google.Chrome"))
        rig.forwarder.observe(Self.connected("com.google.Chrome"))
        #expect(rig.store.value == "com.google.Chrome")
        #expect(rig.store.writes == 1)

        rig.forwarder.observe(Self.connected("org.mozilla.firefox"))
        #expect(rig.store.value == "org.mozilla.firefox")
        #expect(rig.store.writes == 2)
    }

    @Test("03 键名与超时是契约的一部分(壳、05 票的卸载清理、spec §6 都认这几个值)")
    func constantsArePinned() {
        #expect(A2URLRouter.fallbackBrowserDefaultsKey == "urlRouter.fallbackBrowserBundleID")
        #expect(A2URLRouter.hardcodedFallbackBrowserBundleID == "com.apple.Safari")
        #expect(A2URLRouter.forwardTimeout == 1.5)
        #expect(A2URLRouter.routeCapability == "url-router.route")
    }

    @Test("03 从没拿到过快照(内核从没跑过):退到硬编码 Safari —— 链接照样打得开")
    func fallsBackToHardcodedSafariWithoutSnapshot() {
        let rig = Rig()                       // store 是空的
        rig.router.outcome = .unreachable("连不上")

        rig.forwarder.handle("https://example.com/a")

        #expect(rig.opener.opened.map { $0.bundleID } == ["com.apple.Safari"])
    }

    @Test("03 配的那个浏览器不在了:退一级到 Safari;Safari 也解析不到才交给系统缺省")
    func fallbackLaddersDown() {
        let rig = Rig(stored: "com.example.GoneBrowser")
        rig.router.outcome = .unreachable("连不上")
        rig.opener.resolvable = ["com.apple.Safari"]

        rig.forwarder.handle("https://example.com/a")
        #expect(rig.opener.opened.map { $0.bundleID } == ["com.apple.Safari"])
        #expect(rig.opener.systemDefault.isEmpty)

        // 连 Safari 都解析不到(理论上删不掉,但兜底不该假设这件事)→ 交给系统缺省。
        let last = Rig(stored: "com.example.GoneBrowser")
        last.router.outcome = .unreachable("连不上")
        last.opener.resolvable = []
        last.forwarder.handle("https://example.com/a")
        #expect(last.opener.opened.isEmpty)
        #expect(last.opener.systemDefault == ["https://example.com/a"])
    }

    @Test("03 防打转:同一条 URL 刚交给过系统缺省 handler,熄火窗内不再交第二次")
    func systemDefaultHasCooldown() {
        let rig = Rig()
        rig.router.outcome = .unreachable("连不上")
        rig.opener.resolvable = []
        let url = "https://example.com/loop"

        rig.forwarder.handle(url)
        #expect(rig.opener.systemDefault == [url])

        // A2 Panel 自己就是默认浏览器时,上面那一交会把同一条 URL 原样弹回来
        // (去重窗之外、熄火窗之内:壳宁可让这条链接打不开,也不让机器转圈)。
        rig.clock.advance(A2URLRouter.duplicateEventWindow + 0.1)
        rig.forwarder.handle(url)
        #expect(rig.opener.systemDefault == [url], "第二次不该再交出去")

        // 熄火窗过了就恢复正常(不是永久拉黑)。
        rig.clock.advance(A2URLRouter.systemDefaultCooldown)
        rig.forwarder.handle(url)
        #expect(rig.opener.systemDefault.count == 2)
    }

    // ========================================================================
    // 重复投递(kAEGetURL 与 application(_:open:) 是同一件事的两条路)
    // ========================================================================

    @Test("03 同一条 URL 的重复投递只处理一次;不同 URL 各算各的;窗口过了再来算新的一次")
    func duplicateDeliveryIsCollapsed() {
        let rig = Rig()
        rig.router.outcome = .routed

        rig.forwarder.handle("https://example.com/a")
        rig.forwarder.handle("https://example.com/a")      // 同一次点击的第二条投递
        #expect(rig.router.forwarded == ["https://example.com/a"])

        rig.forwarder.handle("https://example.com/b")      // 另一条链接,照发
        #expect(rig.router.forwarded.count == 2)

        rig.clock.advance(A2URLRouter.duplicateEventWindow + 0.01)
        rig.forwarder.handle("https://example.com/b")      // 隔了一会儿又点了一次:算新的一次
        #expect(rig.router.forwarded.count == 3)
    }

    // ========================================================================
    // 收场恰好一次(会话线程 vs 看门狗)
    // ========================================================================

    @Test("03 一张转发票只收场一次:先到的赢,后到的什么都不做")
    func ticketSettlesExactlyOnce() {
        final class Sink { var outcomes: [A2URLRouteOutcome] = [] }
        let sink = Sink()
        let ticket = A2URLRouteTicket(url: "https://example.com/a",
                                      deadline: Date().addingTimeInterval(1.5)) {
            sink.outcomes.append($0)
        }
        #expect(!ticket.isSettled)

        ticket.settle(.unreachable("看门狗到点了"))
        ticket.settle(.routed)                      // 会话线程晚了一步:必须无声无息
        ticket.settle(.refused(code: "x", message: "y"))

        #expect(sink.outcomes == [.unreachable("看门狗到点了")])
        #expect(ticket.isSettled)
    }
}

// ============================================================================
// 会话那一侧:内核不可达时,一次点击**不会悬着**
// ============================================================================

/// 这一条有意用**真的 `A2PanelSession`**(socket 指向一个不存在的路径 = 内核不可达),
/// 因为它验的正是假件替不掉的那件事:会话线程此刻睡在重连间隔里,压根不会去看待发队列 ——
/// 收场只能由**发起方的看门狗**给出。没有它,用户点的链接会一直悬着。
@Suite("03 转发的看门狗(内核不可达时点击不悬着)")
struct A2URLRouteWatchdogTests {

    private final class OutcomeBox {
        private let lock = NSLock()
        private var stored: A2URLRouteOutcome?
        var value: A2URLRouteOutcome? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func set(_ outcome: A2URLRouteOutcome) {
            lock.lock(); stored = outcome; lock.unlock()
        }
    }

    @Test("03 连不上内核:转发在 1.5s 那一档收场成 unreachable(不是永远等下去)")
    func watchdogSettlesWhenKernelIsUnreachable() async throws {
        // 不存在的 socket 路径 —— 连接必然失败,会话会一直在"连不上 → 睡 → 再连"的循环里。
        let socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("a2-url-router-03-\(UUID().uuidString).sock")
        let session = A2PanelSession(
            configuration: .init(socketPath: socketPath,
                                 identity: A2ClientIdentity(name: "a2-panel-test", version: "0.0.0")),
            delegate: nil)
        session.start()
        defer { session.stop() }

        let box = OutcomeBox()
        let started = Date()
        session.routeURL("https://example.com/a?x=1#f") { box.set($0) }

        while box.value == nil, Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let elapsed = Date().timeIntervalSince(started)

        guard case .unreachable = box.value else {
            Issue.record("连不上内核时必须以 unreachable 收场,实际:\(String(describing: box.value))")
            return
        }
        // 收场的是**看门狗**(到点),不是别的什么先失败了 —— 所以下界卡在 1s。
        #expect(elapsed >= 1.0)
        #expect(elapsed < 5)
    }
}
