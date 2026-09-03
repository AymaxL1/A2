// A2Panel —— **URL 转发与降级兜底**(url-router 施工 03 票,spec §2②③ / §6.1 / §7 / §9)。
//
// ============================================================================
// 这个文件的全部职责,以及它**明确不做**的事
// ============================================================================
// 用户点了一条链接 → 系统把 A2 Panel 拉起来 → 壳做且只做两件机械事:
//   ① 把那条 URL **原样**(一个字节不改、一个字段不看)交给内核的 `url-router.route`;
//   ② 内核不可达时,把同一条 URL 原样交给「最后已知的兜底浏览器」,并弹一条**节流**通知。
//
// **03 研究票的四条硬边界是红线**(ADR 0008 第 5 条修订的豁免正文,定性「哑管道 + 断电开关」):
//   ① 不解析 URL 内容    —— 本文件里 URL 只有一个类型:`String`。既不建 `URL`、不取 host/scheme,
//                          也不做任何长度/前缀/编码判断。要开的那一条与用户点的那一条**逐字节相同**。
//   ② 不做域名匹配        —— 分流域名表压根不在壳的知识里(快照的 `urlRouter` 节只给一个 bundle id)。
//   ③ 唯一分支条件 = 内核可达与否 —— 见 `A2URLRouteOutcome`:壳只认「内核接走了 / 没接走」,
//                          而"没接走"是连接失败、1.5s 超时或内核明说拒绝。分支与 URL 本身无关。
//   ④ 配置知识只来自内核推送快照,永不读内核文件 —— 兜底身份来自 `observe(_:)` 落盘的那份
//                          UserDefaults(源头是快照),再退一步是硬编码的 Safari。本文件不含
//                          `~/.a2` 的任何路径,也没有任何文件读。
// 有反向断言守着这四条(`Tests/A2PanelTests/A2URLForwarderTests`:既验行为,也把本文件的源码
// 拿去 grep 禁忌记号)。
//
// ============================================================================
// 为什么"失败"与"不可达"分开记,却走同一条兜底
// ============================================================================
// 兜底动作**只有一条**(交给兜底浏览器),对两种收场一模一样 —— 那正是边界③要的:壳不因 URL 是什么
// 而改主意。区别只在**要不要打扰用户**:通知的原文是「A2 内核未运行……」,内核明明在跑却弹它就是撒谎,
// 而那种失败在内核那侧已经如实入了审计与日志(`a2 url-router status` 查得到)。
// 于是:兜底一律做,通知只在**内核不可达**那一种收场上发,且节流。

import Foundation

// ============================================================================
// 常量与词表
// ============================================================================

/// URL 分流在壳这一侧的全部常量。**禁止各处各写一份**(键名写错一次,兜底就永远读不到用户配的值)。
public enum A2URLRouter {

    /// 转发用的能力 id。壳与 CLI 走**同一条能力面**(spec §6.1「转发零新帧」)。
    public static let routeCapability = "url-router.route"

    /// 壳侧调用超时(spec §6.1:**含连接**)。到点即视为内核不可达,进兜底。
    public static let forwardTimeout: TimeInterval = 1.5

    /// 兜底浏览器落在壳自己的 UserDefaults(`com.a2.panel` 域)里的键名(spec §6.2)。
    public static let fallbackBrowserDefaultsKey = "urlRouter.fallbackBrowserBundleID"

    /// **最终缺省**:壳从未收到过任何快照时用它(03 研究票 Answer 第 1 条)。
    /// macOS 上 Safari 删不掉,所以这一条永远有个真实的落点。
    public static let hardcodedFallbackBrowserBundleID = "com.apple.Safari"

    /// 节流通知的两行文字。合起来即 spec §7 的原句「A2 内核未运行,链接已交给兜底浏览器」
    /// (有断言钉着这句话,改文案会当场红)。
    public static let unreachableNoticeTitle = "A2 内核未运行"
    public static let unreachableNoticeBody = "链接已交给兜底浏览器"

    /// 同一条 URL 在这么短的时间里再来一次 = 同一次点击的重复投递,忽略。
    ///
    /// 为什么需要:kAEGetURL 与 `application(_:open:)` 是同一件事的两条投递路,谁先谁后由 AppKit 定
    /// (装了自己的 Apple Event handler 之后通常只走前者,但这依赖版本行为,壳两条都挂着)。
    /// 判据是**字符串相等**,不是"看看这两条 URL 是不是同一个网站"—— 与边界①②不冲突。
    public static let duplicateEventWindow: TimeInterval = 0.5

    /// 同一条 URL 交给「系统缺省 handler」这一最后手段之后的**熄火窗**。
    ///
    /// 这是防打转的阀门:A2 Panel 自己就可能**是**系统默认浏览器,那时把 URL 交回给系统缺省
    /// 等于原地弹回自己。正常机器走不到这一级(前两级是用户配的兜底与删不掉的 Safari),
    /// 但真走到了,壳宁可让这一条链接打不开,也不能让机器转圈。
    public static let systemDefaultCooldown: TimeInterval = 10
}

/// 一次转发的收场。**壳的唯一分支依据**(边界③),与 URL 内容无关。
public enum A2URLRouteOutcome: Sendable, Equatable {
    /// 内核接走了(它已经开了)。壳什么都不用做 —— 尤其不许"再开一次以防万一"。
    case routed
    /// 内核在,但这次调用被拒(如实带上包封里的 code/message)。链接仍要打得开,所以照样兜底,
    /// 但**不弹**那条说"内核未运行"的通知。
    case refused(code: String, message: String)
    /// 内核不可达:连不上、连接断了,或 `forwardTimeout` 到点还没答复。
    case unreachable(String)
}

// ============================================================================
// 四个注入口(全部是"机械动作",没有一个带判断)
// ============================================================================

/// 把 URL 原样交给内核的那条通道(实现者是 `A2PanelSession`)。
public protocol A2URLRouteForwarding: AnyObject {
    /// **原样**转发,`completion` 恰好被调用一次、可能在任意线程。
    /// 实现者必须保证不悬着:超时(含连不上)要以 `.unreachable` 收场。
    func routeURL(_ url: String, completion: @escaping (A2URLRouteOutcome) -> Void)
}

/// 把 URL 交给某个浏览器(实现者在 A2PanelMacOS 里调 `NSWorkspace`)。
public protocol A2FallbackBrowserOpening: AnyObject {
    /// 交给指定 bundle id 的 app。返回**有没有真的交出去**(解析不到那个 app 就是 false)。
    func open(_ url: String, withBundleID bundleID: String) -> Bool
    /// 最后手段:交给系统缺省 handler(不指定 app)。
    func openWithSystemDefault(_ url: String) -> Bool
}

/// 弹一条用户可见通知(实现者用 `UNUserNotificationCenter`,**best-effort**:没授权就静默跳过)。
public protocol A2URLRouterNotifying: AnyObject {
    func notifyFallback(title: String, body: String)
}

/// 兜底浏览器身份的**持久化**(壳自己的 UserDefaults 域;内核宕着、重启之后也还在)。
public protocol A2URLRouterDefaultsStoring: AnyObject {
    func fallbackBrowserBundleID() -> String?
    func setFallbackBrowserBundleID(_ bundleID: String)
}

/// `UserDefaults` 版实现(壳跑起来时用的那份;测试一律注入假件,**绝不碰真 defaults**)。
public final class A2UserDefaultsURLRouterStore: A2URLRouterDefaultsStoring {
    private let defaults: UserDefaults

    /// 缺省 `.standard` —— 在 `.app` 里那就是 `com.a2.panel` 域(spec §6.2 指定的落点)。
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func fallbackBrowserBundleID() -> String? {
        let stored = defaults.string(forKey: A2URLRouter.fallbackBrowserDefaultsKey)
        // 空白值按"没有"算:一个空 bundle id 打不开任何东西,而这时还有硬编码那一级可用。
        guard let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return stored
    }

    public func setFallbackBrowserBundleID(_ bundleID: String) {
        defaults.set(bundleID, forKey: A2URLRouter.fallbackBrowserDefaultsKey)
    }
}

// ============================================================================
// 转发器
// ============================================================================

/// 收到 URL 之后那条完整的路:转发 → (不成)兜底 → (且不可达)节流通知。
///
/// **线程**:`handle` 从主线程来(AppKit 的事件),`routeURL` 的 completion 可能在会话线程或看门狗线程,
/// `observe` 在主线程。所以内部三样状态(节流位、去重记号、熄火记号)统统上锁;锁里**不做 I/O**。
public final class A2URLForwarder {

    private let router: A2URLRouteForwarding
    private let opener: A2FallbackBrowserOpening
    private let notifier: A2URLRouterNotifying
    private let defaults: A2URLRouterDefaultsStoring
    private let log: (String) -> Void
    private let now: () -> Date

    private let lock = NSLock()
    /// 「内核不可达」那条通知,自上一次重连以来发过没有(spec §9 的节流位)。
    private var noticeSent = false
    /// 上一次看到的连接态 —— 只为认出"断→连"那一帧(那一帧 = 会话重新拿到了快照)。
    private var lastConnection: A2PanelConnection?
    /// 最近一条被受理的 URL 与时刻(去重用,见 `A2URLRouter.duplicateEventWindow`)。
    private var lastAdmitted: (url: String, at: Date)?
    /// 最近一条交给系统缺省 handler 的 URL 与时刻(防打转,见 `A2URLRouter.systemDefaultCooldown`)。
    private var lastSystemDefault: (url: String, at: Date)?

    public init(router: A2URLRouteForwarding,
                opener: A2FallbackBrowserOpening,
                notifier: A2URLRouterNotifying,
                defaults: A2URLRouterDefaultsStoring,
                log: @escaping (String) -> Void = { _ in },
                now: @escaping () -> Date = Date.init) {
        self.router = router
        self.opener = opener
        self.notifier = notifier
        self.defaults = defaults
        self.log = log
        self.now = now
    }

    // MARK: - 收到一条 URL

    /// 收到一条 URL(**原样字符串**,来自 kAEGetURL 或 `application(_:open:)`)。
    ///
    /// 日志脱敏(spec §7):**这里到收场为止,一个字节的 URL 都不进日志** —— query 与 fragment 里
    /// 常有令牌与私事,壳既然不看它,就更没有理由把它写下来。
    public func handle(_ url: String) {
        guard admit(url) else {
            log("忽略一条重复投递的 URL 事件(同一条,\(A2URLRouter.duplicateEventWindow) 秒内)")
            return
        }
        log("收到一条 URL,转给内核 \(A2URLRouter.routeCapability)")
        router.routeURL(url) { [weak self] outcome in
            self?.settle(url, outcome)
        }
    }

    /// 会话状态变了(每次 `didUpdate` 都可以喂进来,幂等)。两件事:
    ///   * 快照里的兜底身份**顺手落盘**(spec §6.2:投影路径顺手写,不另开通道);
    ///   * 「断→连」那一帧重置通知节流位 —— 那一帧的含义正是"会话重新拿到了全量快照"。
    public func observe(_ state: A2PanelState) {
        if let bundleID = state.urlRouter?.fallbackBrowserBundleID { persist(bundleID) }

        lock.lock()
        let previous = lastConnection
        lastConnection = state.connection
        let reconnected = state.connection == .connected && previous != .connected
        if reconnected { noticeSent = false }
        lock.unlock()

        if reconnected { log("内核可达,兜底通知的节流位已重置") }
    }

    // MARK: - 收场

    private func settle(_ url: String, _ outcome: A2URLRouteOutcome) {
        switch outcome {
        case .routed:
            // 内核已经开了。**这里什么都不做**是重点:再"保险起见"开一次就是两个标签页。
            log("内核已接走这条链接")
        case let .refused(code, message):
            log("内核拒绝了这次转发:\(code) \(message);仍按兜底把链接交出去")
            fallback(url, notify: false)
        case let .unreachable(reason):
            log("内核不可达(\(reason)),走兜底")
            fallback(url, notify: true)
        }
    }

    /// 机械兜底:取兜底身份 → 交出去 → (需要且没发过时)弹一条通知。
    ///
    /// 三级顺序是"越来越退让",每一级都不看 URL 一个字节:
    ///   ① 最后已知快照里那个 bundle id(没有则硬编码 Safari);
    ///   ② 那个 app 解析不到时,退到硬编码 Safari(macOS 上删不掉的那一个);
    ///   ③ 还不行才交给系统缺省 handler —— **链接永远打得开**,代价见 `systemDefaultCooldown`。
    private func fallback(_ url: String, notify: Bool) {
        let configured = defaults.fallbackBrowserBundleID() ?? A2URLRouter.hardcodedFallbackBrowserBundleID
        var handedOver = opener.open(url, withBundleID: configured)
        if handedOver {
            log("已交给兜底浏览器 \(configured)")
        } else if configured != A2URLRouter.hardcodedFallbackBrowserBundleID,
                  opener.open(url, withBundleID: A2URLRouter.hardcodedFallbackBrowserBundleID) {
            handedOver = true
            log("兜底浏览器 \(configured) 打不开(app 不在?),已退到 \(A2URLRouter.hardcodedFallbackBrowserBundleID)")
        } else if admitSystemDefault(url) {
            handedOver = opener.openWithSystemDefault(url)
            log(handedOver
                ? "两级兜底都解析不到 app,已把链接交给系统缺省 handler"
                : "两级兜底都解析不到 app,系统缺省 handler 也没接住 —— 这条链接没能打开")
        } else {
            log("同一条链接刚交给过系统缺省 handler:多半是本机把 A2 Panel 设成了默认浏览器、链接又弹了回来。这一次不再交出去,以免打转")
        }

        guard notify else { return }
        lock.lock()
        let shouldNotify = !noticeSent
        noticeSent = true
        lock.unlock()
        guard shouldNotify else { return }
        // best-effort:没授权就静默跳过(授权仪式是人工项,不在 03 票)。
        notifier.notifyFallback(title: A2URLRouter.unreachableNoticeTitle,
                                body: A2URLRouter.unreachableNoticeBody)
        log("已弹一条兜底通知;内核恢复之前后续兜底静默")
    }

    private func persist(_ bundleID: String) {
        // 只在**变了**的时候写:UserDefaults 的每次写都会落盘,而这条路每次状态更新都会走一遍。
        guard defaults.fallbackBrowserBundleID() != bundleID else { return }
        defaults.setFallbackBrowserBundleID(bundleID)
        log("快照里的兜底浏览器已落盘:\(bundleID)")
    }

    // MARK: - 两道纯机械的闸(都只做字符串相等 + 看表)

    private func admit(_ url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let at = now()
        if let last = lastAdmitted, last.url == url,
           at.timeIntervalSince(last.at) < A2URLRouter.duplicateEventWindow {
            return false
        }
        lastAdmitted = (url, at)
        return true
    }

    private func admitSystemDefault(_ url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let at = now()
        if let last = lastSystemDefault, last.url == url,
           at.timeIntervalSince(last.at) < A2URLRouter.systemDefaultCooldown {
            return false
        }
        lastSystemDefault = (url, at)
        return true
    }
}
