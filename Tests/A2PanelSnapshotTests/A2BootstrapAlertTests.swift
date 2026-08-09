// 16 票 CR:**回车落在哪个按钮上** —— 一条真缺陷,值一套专门的断言。
//
// ============================================================================
// 缺陷长什么样
// ============================================================================
// `NSAlert.addButton(withTitle:)` 会给**第一个**加进去的按钮自动塞一个 `\r`(AppKit 的默认按钮约定)。
// 16 票第一版把主操作("安装并启动" / "停止并卸载")放在第一个(mac 习惯,主操作在右),
// 然后只给第二个按钮补了 `keyEquivalent = "\r"` —— 于是**两个按钮都持有回车**,
// 而回车落在第一个上。结果:一次手滑回车就把内核装了 / 把服务卸了。
// 这恰好打在本票自己立的「显式点击边界」上:那一下**不是**显式点击。
//
// 修法是显式清掉主操作那个自动回车,并把规矩收在 `A2BootstrapPresenter.makeTwoButtonAlert` 一处。
//
// ============================================================================
// 为什么这套用例住在 A2PanelSnapshotTests
// ============================================================================
// 它要真的建 `NSAlert` / `NSButton`(AppKit),而 `A2PanelTests` 是**零 AppKit** 的纯逻辑套件。
// 本套件本来就是 AppKit 那一侧(离屏渲染),`@MainActor` 也已经是它的常态。
// **只造不弹**:`runModal()` 一次都不调 —— 门禁里没有人能点那个按钮。

import AppKit
import Testing
import A2Panel
import A2PanelMacOS

@Suite("16 弹框按键归属(回车绝不落在改变系统状态的那个按钮上)")
@MainActor
struct A2BootstrapAlertTests {

    @Test("16 首启说明框:回车归「稍后」,「安装并启动」手里**没有**回车")
    func firstRunPromptBindsReturnToLater() throws {
        let alert = A2BootstrapPresenter.makeTwoButtonAlert(
            title: A2BootstrapPrompt.title,
            body: A2BootstrapPrompt.body,
            primaryTitle: A2BootstrapPrompt.installTitle,
            safeTitle: A2BootstrapPrompt.laterTitle,
            style: .informational)

        #expect(alert.buttons.count == 2)
        let install = try #require(alert.buttons.first { $0.title == A2BootstrapPrompt.installTitle })
        let later = try #require(alert.buttons.first { $0.title == A2BootstrapPrompt.laterTitle })
        #expect(install.keyEquivalent == "", "回车绝不能落在「安装并启动」上 —— 那不是显式点击")
        #expect(later.keyEquivalent == "\r")
    }

    @Test("16 卸载确认框:回车归「取消」,「停止并卸载」手里**没有**回车")
    func uninstallConfirmationBindsReturnToCancel() throws {
        let confirmation = try #require(A2BootstrapMenuAction.uninstall.confirmation)
        let alert = A2BootstrapPresenter.makeTwoButtonAlert(
            title: confirmation.title,
            body: confirmation.body,
            primaryTitle: confirmation.confirmTitle,
            safeTitle: confirmation.cancelTitle,
            style: .warning)

        let destroy = try #require(alert.buttons.first { $0.title == confirmation.confirmTitle })
        let cancel = try #require(alert.buttons.first { $0.title == confirmation.cancelTitle })
        #expect(destroy.keyEquivalent == "")
        #expect(cancel.keyEquivalent == "\r")
    }

    @Test("16 反向证明缺陷真实存在:不清那一行的话,`NSAlert` 会让**两个**按钮都拿着回车")
    func addButtonGivesTheFirstButtonReturnByDefault() {
        // 这是 16 票第一版写的那种弹框(只给第二个按钮绑,不清第一个)。
        //   留着它是为了让"为什么必须多那一行"永远有据可查 —— AppKit 哪天改了行为,这条会红,
        //   那时该重新审视的是 `makeTwoButtonAlert`,而不是把这条删掉了事。
        let naive = NSAlert()
        naive.addButton(withTitle: "主操作")
        let second = naive.addButton(withTitle: "安全")
        second.keyEquivalent = "\r"

        #expect(naive.buttons[0].keyEquivalent == "\r",
                "AppKit 给第一个按钮的自动回车 —— 正是必须显式清掉的那一个")
        #expect(naive.buttons[1].keyEquivalent == "\r")
    }

    @Test("16 手搭的 NSButton **不会**自动拿到回车 —— 确认器那个窗因此是安全的")
    func handBuiltButtonsHaveNoKeyEquivalent() {
        // 16 票 CR 两轴在 `A2ConfirmationPresenter` 上给出了相反判断,裁定靠这条事实:
        //   那个窗的两个按钮是手搭的 `NSButton`,不是 `NSAlert` 的;缺省 `keyEquivalent` 是空串,
        //   而它只给 deny 显式绑了 `\r`、approve 一次都没赋过值 —— 所以回车只落在「拒绝」上。
        //   (dangerous 的批准被回车误触,比装个内核严重得多,所以这条值得钉死。)
        let button = NSButton(title: "批准", target: nil, action: nil)
        #expect(button.keyEquivalent == "",
                "手搭 NSButton 的缺省 keyEquivalent 若不再是空串,A2ConfirmationPresenter 就得重审")
    }
}
