// A2PanelMacOS —— 首启说明框的**呈现面** + 「已谢绝」标记的落点(16 票 / ADR 0012 第 2 条)。
//
// ============================================================================
// 这是壳唯一一次主动打扰用户,所以三件事必须写死
// ============================================================================
// ① **文案不在这里**:装什么、怎么卸、按钮叫什么,全在 `A2BootstrapPrompt`(纯数据,有断言钉着)。
//    这个文件只负责"把那段文字放进 NSAlert"——与确认器 `A2ConfirmationPresentation` 同一种分层,
//    理由也逐字相同:藏进 AppKit 的字符串拼接里就只有人眼能审。
// ② **回车归安全那一侧**,而且这件事比看上去容易做错(16 票 CR 抓到的真缺陷):
//    `NSAlert.addButton` 的**第一个**按钮会自动拿到 `\r`。只给第二个按钮补一句
//    `keyEquivalent = "\r"` 是**不够的** —— 两个按钮都持有回车时,回车落在第一个上,
//    也就是"安装/卸载"那一侧,一次手滑就把系统状态改了。必须**显式清掉第一个的**。
//    按钮顺序仍按 mac 习惯排(主操作在右 = 第一个 add),只把回车挪走。
//    这条规则收在 `makeTwoButtonAlert` 一处:两个调用点(首启框、卸载确认框)都走它,
//    不各写一遍 —— 各写一遍正是这次漏掉一处的原因。
// ③ **点过「稍后」就不再自动弹**:标记写 `UserDefaults`,键名一次定死(改键 = 所有老用户又被问一遍)。
//    菜单项常驻,想装随时点 —— 「不再纠缠」不等于「从此装不了」。

import AppKit
import A2Panel

@MainActor
public enum A2BootstrapPresenter {

    /// 「用户已谢绝首启说明框」的标记键。**改它等于把所有老用户重新问一遍**,所以只此一处、不再改。
    public static let dismissedDefaultsKey = "com.a2.panel.bootstrap.firstRunPromptDismissed"

    /// 读标记(缺省 false = 没谢绝过)。
    public static func firstRunPromptDismissed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: dismissedDefaultsKey)
    }

    /// 写标记。
    public static func setFirstRunPromptDismissed(_ dismissed: Bool,
                                                  defaults: UserDefaults = .standard) {
        defaults.set(dismissed, forKey: dismissedDefaultsKey)
    }

    // ========================================================================
    // 两按钮弹框:回车归安全那一侧(全仓唯一一处定这条规矩,见文件头②)
    // ========================================================================

    /// 造一个两按钮弹框:主操作在右(第一个 add,mac 习惯),**回车绑在安全那一侧**。
    ///
    /// 只造不弹 —— 于是"回车到底落在哪个按钮上"是一条可断言的事实
    /// (`A2BootstrapAlertTests`,连"不加那行清除就会落在主操作上"都一并钉住了)。
    public static func makeTwoButtonAlert(title: String,
                                          body: String,
                                          primaryTitle: String,
                                          safeTitle: String,
                                          style: NSAlert.Style) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = style
        let primary = alert.addButton(withTitle: primaryTitle)
        let safe = alert.addButton(withTitle: safeTitle)
        // 顺序要紧:先把主操作那个**自动获得**的回车摘掉,再绑给安全那个。
        primary.keyEquivalent = ""
        safe.keyEquivalent = "\r"
        return alert
    }

    /// 弹一次首启说明框。返回 `true` = 用户点了「安装并启动」。
    public static func presentFirstRunPrompt() -> Bool {
        let alert = makeTwoButtonAlert(title: A2BootstrapPrompt.title,
                                       body: A2BootstrapPrompt.body,
                                       primaryTitle: A2BootstrapPrompt.installTitle,
                                       safeTitle: A2BootstrapPrompt.laterTitle,
                                       style: .informational)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 弹一次引导动作的确认框(目前只有卸载用得上)。返回 `true` = 用户批准。
    ///
    /// 住在这里而不是渲染器里:回车归属那条规矩只该有**一处**实现
    /// —— 分头写正是 16 票第一版漏掉一半的原因。
    public static func presentConfirmation(_ confirmation: A2BootstrapConfirmation) -> Bool {
        let alert = makeTwoButtonAlert(title: confirmation.title,
                                       body: confirmation.body,
                                       primaryTitle: confirmation.confirmTitle,
                                       safeTitle: confirmation.cancelTitle,
                                       style: .warning)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
