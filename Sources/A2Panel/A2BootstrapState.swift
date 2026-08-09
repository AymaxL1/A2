// A2Panel —— 引导的**面板本地状态**与两处呈现文案(16 票 / ADR 0012)。纯数据,零 AppKit、零 I/O。
//
// ============================================================================
// 为什么它不住在 `A2PanelState` 里
// ============================================================================
// `A2PanelState` 是**内核事件流的投影**:每一个字段都能追溯到"内核说过的某句话"
// (快照 + 七族事件),这是它能被 `A2PanelProjection` 单测钉死的前提。
// 而这里的东西一件都不是内核说的:
//   * 嵌入 bin 在不在 —— 问的是自己的 `.app`;
//   * 嵌入 bin 的版本 —— 问的是嵌入 bin 自己(`a2 version`);
//   * 服务装没装 —— 问的是系统 supervisor(`a2 service status`,不经 daemon);
//   * 在途 / 上次失败 / 用户谢绝过没有 —— 纯粹是这个进程自己的记忆。
// 把它们塞进投影层,「投影 = 内核事实」这条口径当场破掉,而破掉之后再想验"投影对不对"就无从谈起。
// 所以它们单独一份,与 `A2PanelState` **并列**喂给 `A2MenuModelBuilder.build(state:bootstrap:)`。
//
// ============================================================================
// 首启弹框的触发判据为什么必须是纯函数
// ============================================================================
// 它是本票唯一一处"壳自己决定要不要打扰用户"的地方 —— ADR 0012 第 2 条那条边界
// (「显式点击」而非「自动路径」)就落在这一个布尔值上。藏进 AppDelegate 的 if 里就只有人眼能审;
// 拆成纯函数之后,四个输入的**全部 32 种组合**都是可断言的(见 `A2BootstrapDecisionTests`)。

import Foundation

// ============================================================================
// 引导菜单动作(**不是**能力调用 —— 它不经 UDS,也没有 capability id)
// ============================================================================

/// 菜单里那两个引导项各自会发起的动作。
///
/// 与能力项的分野必须一眼可见:能力项落到 `capabilityID` + `params`,经 `A2PanelSession` 走 UDS;
/// 引导项落到本枚举,经内嵌 bin 起子进程。**两条路互不相通**,菜单模型里也是两个字段。
public enum A2BootstrapMenuAction: String, Sendable, Equatable, CaseIterable {
    /// 「安装并启动内核」/「启动内核」/「升级内核 vX→vY」——**同一条幂等命令**,只是标题随状态变。
    case install
    /// 「停止并卸载内核服务」。
    case uninstall

    /// 本动作发的那条白名单命令。
    public var command: A2BootstrapCommand {
        switch self {
        case .install:   return .serviceInstall
        case .uninstall: return .serviceUninstall
        }
    }

    /// 菜单右侧角标 = **这一项到底会跑什么**(与能力项的能力 id 角标同一个位置、同一种用意:
    /// 让不读 Swift 的人也能一眼核对)。
    public var badge: String { command.displayCommand }

    /// 点下去要先弹的确认框。`nil` = 不弹。
    ///
    /// **是数据不是逻辑**:渲染器只做「有就弹、批准了才发」,它自己不判断哪个动作危险 ——
    /// 那样判断就会散落在两个渲染器里各写一遍。
    public var confirmation: A2BootstrapConfirmation? {
        switch self {
        case .install:
            // 装:首启那次已经有说明框了,菜单项本身是用户主动去点的,不再多一道。
            return nil
        case .uninstall:
            return A2BootstrapConfirmation(
                title: "停止并卸载 a2 内核服务?",
                body: [
                    "这会停掉常驻内核并移除 launchd 用户服务 com.a2.kernel。",
                    "",
                    "只拆服务 —— ~/.a2 里的数据(订阅、插件、日志)与 ~/.a2/bin/a2 那份内核拷贝都留下,",
                    "要清理请显式删它们。",
                    // 「先还原系统代理」这句得留余地:菜单里那一项只在**连得上内核**时才有
                    //   (它是一条能力调用),而卸载往往正好发生在连不上的时候。给两条路。
                    "系统代理若还被 a2 接管着,请先还原:菜单里的「关闭系统代理(还原)」——",
                    "菜单上没有那一项(面板此刻没连上内核)时,在终端敲 a2 proxy off。",
                    "",
                    "随时可以从菜单再装回来。",
                ].joined(separator: "\n"),
                confirmTitle: "停止并卸载",
                cancelTitle: "取消")
        }
    }
}

/// 一个确认框的文案(纯数据 → 可断言)。
public struct A2BootstrapConfirmation: Sendable, Equatable {
    public let title: String
    public let body: String
    public let confirmTitle: String
    /// **默认按钮**:取消。与 dangerous 确认器同一条规矩 —— 沉默不是同意。
    public let cancelTitle: String

    public init(title: String, body: String, confirmTitle: String, cancelTitle: String) {
        self.title = title
        self.body = body
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
    }
}

// ============================================================================
// 首启说明框
// ============================================================================

/// 首启那一次的说明框文案(ADR 0012 第 2 条:说清**装什么**、**怎么卸**,两个按钮)。
///
/// 文案本身是契约的一部分:装 launchd 用户服务、建 `~/.a2`、开机自启与崩溃自愈归系统 supervisor
/// —— 这三件事若不写在弹框里,用户点的就不是一次知情的同意。用例逐条核验它们在场。
///
/// ⚠️ **正文里不许出现 Markdown**(`**粗体**` 之类):它进的是 `NSAlert.informativeText`,
///    那是**纯文本**,星号会原样画在屏幕上。要强调就用「」引号或破折号 —— 有断言钉着。
public enum A2BootstrapPrompt {
    public static let title = "把 a2 内核装成常驻服务?"

    public static let body = [
        "A2 Panel 只是内核的一个客户端。要让它有东西可连,得先把内核装成常驻服务。",
        "",
        "点「安装并启动」会做这三件事:",
        "  · 装一个 launchd 用户服务 com.a2.kernel(开机自启、崩溃自愈都归系统托管,面板不做进程监督)",
        "  · 建 ~/.a2(订阅、插件、日志、socket 都在里面),并把这个 .app 里那份内核拷进 ~/.a2/bin/a2",
        "  · unit 指向那份拷贝,而不是 .app 里的 —— 所以之后挪走、改名甚至删掉 .app,服务照跑",
        "",
        "怎么卸:菜单「高级 → 停止并卸载内核服务」,或在终端敲 a2 service uninstall。",
        "面板不会把 a2 装进 PATH,也不写你的 shell 配置。",
        "",
        "选「稍后」就不再自动问了 —— 菜单里那一项常驻,想装随时点。",
    ].joined(separator: "\n")

    public static let installTitle = "安装并启动"
    /// **默认按钮**:稍后。壳不隐式改变系统状态,连"手滑回车"也不该改。
    public static let laterTitle = "稍后"
}

// ============================================================================
// 面板本地的引导状态
// ============================================================================

/// 引导相关的**面板本地状态**。菜单模型是 (`A2PanelState`, 本类型) 的纯函数。
///
/// (16 票 CR 尾款:原先这里还有个 `A2BootstrapOperation = A2BootstrapMenuAction` 的别名。
///  删了 —— 它不带任何类型安全,只是给同一件事起了第二个名字,读代码的人得多查一次。)
public struct A2BootstrapState: Sendable, Equatable {

    /// 内嵌 bin 在不在。**false = 引导功能整体隐藏**(dev / 测试态),菜单保持 10 票原样。
    public var embeddedBinAvailable: Bool
    /// 内嵌 bin 自报的版本(启动时问一次并缓存,不轮询 —— ADR 0012 第 5 条)。
    public var embeddedKernelVersion: String?
    /// 最近一次 `service status` 读到的服务态。`nil` = 还没问到(或问失败了)。
    public var serviceState: A2BootstrapServiceFacts.State?
    /// 在途操作。非 nil 时菜单项一律禁用,并出一条「安装中…」的 info 行。
    public var inFlight: A2BootstrapMenuAction?
    /// 最近一次引导失败(成功一次就清空)。如实进菜单,含退出码语义。
    public var lastFailure: A2BootstrapFailure?
    /// 用户在首启说明框上点过「稍后」(UserDefaults 标记的投影)。**此后不再自动弹**。
    public var firstRunPromptDismissed: Bool
    /// **本次启动里用户已经用过引导面**(点过任意一个引导项)。
    ///
    /// 16 票 CR 抓到的真缺陷:首启判据只看"服务装没装",而它在会话中途会**重新成立** ——
    /// 用户从「高级」卸掉服务、或一次安装失败之后,`serviceState` 回到 `not_installed`,
    /// 说明框就会当场蹦出来问「装回去?」。那既不是"首启",也不是用户此刻想要的。
    /// 一旦用户自己点过引导项,说明框的使命(告诉他这东西是什么)就已经完成 —— 从此闭嘴。
    public var hasUsedBootstrap: Bool
    /// `<A2_HOME>/run/kernel.sock` 这个文件在不在(首启判据之一,见下)。
    public var socketPresent: Bool

    public init(embeddedBinAvailable: Bool = false,
                embeddedKernelVersion: String? = nil,
                serviceState: A2BootstrapServiceFacts.State? = nil,
                inFlight: A2BootstrapMenuAction? = nil,
                lastFailure: A2BootstrapFailure? = nil,
                firstRunPromptDismissed: Bool = false,
                hasUsedBootstrap: Bool = false,
                socketPresent: Bool = false) {
        self.embeddedBinAvailable = embeddedBinAvailable
        self.embeddedKernelVersion = embeddedKernelVersion
        self.serviceState = serviceState
        self.inFlight = inFlight
        self.lastFailure = lastFailure
        self.firstRunPromptDismissed = firstRunPromptDismissed
        self.hasUsedBootstrap = hasUsedBootstrap
        self.socketPresent = socketPresent
    }

    /// 没有内嵌 bin 的那一态 —— 也是**缺省态**:`swift build` 的裸壳、纯逻辑测试、旗舰 e2e 的无头替身
    /// 全都落在这里,于是它们看到的菜单与 10 票逐字相同(既有 golden 一个字节都不动)。
    public static let hidden = A2BootstrapState()

    /// 首启说明框:弹,还是不弹?(转发到纯函数,见下)
    public var shouldPresentFirstRunPrompt: Bool {
        A2BootstrapDecision.shouldPresentFirstRunPrompt(
            embeddedBinAvailable: embeddedBinAvailable,
            serviceState: serviceState,
            socketPresent: socketPresent,
            userDeclined: firstRunPromptDismissed,
            hasUsedBootstrap: hasUsedBootstrap)
    }
}

// ============================================================================
// 触发判据(**纯函数**,五个输入)
// ============================================================================

public enum A2BootstrapDecision {

    /// 首启说明框弹不弹。五个条件**全部成立**才弹,任一不成立就闭嘴。
    ///
    /// 逐条理由:
    ///   ① **嵌入 bin 在** —— 不在就没有执行器,弹了也没有能点的按钮(dev / 测试态);
    ///   ② **用户没谢绝过** —— 点过「稍后」就不再纠缠(ADR 0012 第 2 条的原话),菜单项常驻可随时再装;
    ///   ③ **本次启动还没用过引导面** —— 用户自己点过引导项之后,说明框的使命已尽。
    ///      这一条是 16 票 CR 补的:少了它,「卸载完成」「安装失败」这类**会话中途**回到
    ///      `not_installed` 的时刻会让说明框重新蹦出来问「装回去?」—— 那已经不是"首启",
    ///      而是壳在追着用户问。判据里必须有一条记得"你已经在用这个面了"。
    ///   ④ **服务确实未安装** —— `installed_not_running` / `running` 都不该弹说明框
    ///      (那时用户早就知道这东西是什么了);**`nil` 也不弹** —— 问不出服务态时闭嘴,
    ///      宁可少弹一次,也不在一个连状态都读不到的机器上劝人装东西;
    ///   ⑤ **socket 文件不在** —— 有 socket 意味着有内核在跑(哪怕它不是 launchd 装的,
    ///      比如开发者手工 `a2 daemon run`)。那时弹框会劝他把自己那份顶掉,是纯粹的添乱。
    public static func shouldPresentFirstRunPrompt(embeddedBinAvailable: Bool,
                                                   serviceState: A2BootstrapServiceFacts.State?,
                                                   socketPresent: Bool,
                                                   userDeclined: Bool,
                                                   hasUsedBootstrap: Bool) -> Bool {
        guard embeddedBinAvailable else { return false }
        guard !userDeclined else { return false }
        guard !hasUsedBootstrap else { return false }
        guard serviceState == .notInstalled else { return false }
        guard !socketPresent else { return false }
        return true
    }

    /// 连接态从「断」翻到「连」的**那一帧** —— 唯一该重问一次服务态的时刻。
    ///
    /// 为什么需要它(16 票 CR 抓到的真缺陷):`serviceState` 只在启动时与每次引导操作收场后刷新。
    /// 于是"用户在**面板之外**装了服务"(终端敲 `a2 service install`、或另一台机同步过来)这条路上,
    /// 面板手里那份服务态会**永久陈旧**地停在 `not_installed` —— 「高级 → 停止并卸载」就一直
    /// 置灰在「服务尚未安装」上,而服务其实正跑着。用户从面板里再也卸不掉它。
    ///
    /// 修法只有一次读、且是**事件驱动**的:面板连上内核 = 有人把内核跑起来了,这一帧重问一次。
    /// 不轮询、不定时(ADR 0012 第 5 条不破)。断→断(换个断开原因)、连→连都不触发。
    public static func shouldRefreshServiceState(previous: A2PanelConnection,
                                                 current: A2PanelConnection) -> Bool {
        if case .connected = current, case .disconnected = previous { return true }
        return false
    }
}
