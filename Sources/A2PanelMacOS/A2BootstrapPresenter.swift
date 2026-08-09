// A2PanelMacOS —— 首启说明框的**呈现面** + 「已谢绝」标记的落点(16 票 / ADR 0012 第 2 条)。
//
// ============================================================================
// 这是壳唯一一次主动打扰用户,所以三件事必须写死
// ============================================================================
// ① **文案不在这里**:装什么、怎么卸、按钮叫什么,全在 `A2BootstrapPrompt`(纯数据,有断言钉着)。
//    这个文件只负责"把那段文字放进 NSAlert"——与确认器 `A2ConfirmationPresentation` 同一种分层,
//    理由也逐字相同:藏进 AppKit 的字符串拼接里就只有人眼能审。
// ② **默认按钮是「稍后」**:`addButton` 的第一个按钮天然拿回车,所以顺序是「稍后」在前、
//    「安装并启动」在后?—— 不行,那样"稍后"会长在右边、"安装"在左边,与 mac 的主次习惯反了。
//    正确做法:按 mac 习惯排(主操作在右 = 第一个 add),再把回车**显式**改绑到「稍后」上。
//    壳不隐式改变系统状态,连一次手滑回车都不该改。
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

    /// 弹一次首启说明框。返回 `true` = 用户点了「安装并启动」。
    public static func presentFirstRunPrompt() -> Bool {
        let alert = NSAlert()
        alert.messageText = A2BootstrapPrompt.title
        alert.informativeText = A2BootstrapPrompt.body
        alert.alertStyle = .informational
        // 主操作在右(第一个 add),回车**显式**改绑到「稍后」——见文件头②。
        alert.addButton(withTitle: A2BootstrapPrompt.installTitle)
        let later = alert.addButton(withTitle: A2BootstrapPrompt.laterTitle)
        later.keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
