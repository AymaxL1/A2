// A2PanelMacOS —— 确认器的**呈现面**(10 票)。
//
// ============================================================================
// 这就是「带外确认」在 mac 上的样子
// ============================================================================
// dangerous 调用的入参从**内核**推到这个进程,由这里弹给人看;人点的按钮经**另一条**协议消息
// (`confirmations.resolve`)回内核。发起那次调用的 agent 全程碰不到这两样东西 ——
// 它那条连接上只有「我转给人了、最多等这么久」和最终成败(ADR 0005 修订版第③层)。
//
// 三条不许动的规矩:
//   ① **入参原样呈现**,由 `A2ConfirmationPresentation` 负责(纯逻辑可断言,见那个类型的头注);
//   ② **拒绝是默认按钮**:沉默不是同意,手滑回车不该放行;
//   ③ 窗口被别的原因关掉(超时/降级/发起方走了)时**不发任何决定** —— 收场归内核。
//
// 为什么不用 `NSAlert.runModal()`:模态会占住主 run loop,而在途可以同时有多条 dangerous 请求
// (内核不串行化它们)。一条模态弹起来,第二条就只能排队,而排队期间那条可能已经超时 ——
// 用户会看见一个「点了没用」的窗。改用**各自独立的非模态面板**,来一条弹一个,收场一条关一个。

import AppKit
import A2Contract
import A2Panel

@MainActor
public final class A2ConfirmationPresenter {

    /// 当前挂着的确认窗(按确认 id)。
    private var windows: [String: NSWindow] = [:]
    private let onDecision: (String, A2ConfirmationDecision) -> Void

    public init(onDecision: @escaping (String, A2ConfirmationDecision) -> Void) {
        self.onDecision = onDecision
    }

    /// 弹一条确认。重复 id 幂等(不叠窗)。
    public func present(_ request: A2ConfirmationRequest) {
        guard windows[request.id] == nil else { return }
        let presentation = A2ConfirmationPresentation(request: request)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = presentation.title
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 60, width: 428, height: 220))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        // **可选中**:用户要能把入参复制出去自己核对(尤其是一条 URL 到底指向哪)。
        text.isSelectable = true
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = presentation.body
        scroll.documentView = text
        content.addSubview(scroll)

        let deny = NSButton(title: presentation.denyTitle, target: nil, action: nil)
        deny.frame = NSRect(x: 344, y: 16, width: 100, height: 32)
        deny.bezelStyle = .rounded
        // 默认按钮 = 拒绝(规矩②)。回车 = 拒绝。
        //
        // ⚠️ 16 票 CR 在这里起过一次争议,裁定记在这:**这两个按钮是手搭的 `NSButton`,
        //    不是 `NSAlert`**。`NSAlert.addButton` 会给第一个按钮**自动**塞一个 `\r`
        //    (那是 `A2BootstrapPresenter` 必须显式清掉的东西);手搭的 `NSButton` 不会 ——
        //    它的 `keyEquivalent` 缺省是空串,下面的 `approve` 从头到尾没被赋过值。
        //    所以回车在这个窗上**只**落在 deny 上,批准永远得用鼠标点。有断言钉着缺省值这条事实。
        deny.keyEquivalent = "\r"
        deny.target = self
        deny.action = #selector(denyTapped(_:))
        deny.identifier = NSUserInterfaceItemIdentifier(request.id)
        content.addSubview(deny)

        let approve = NSButton(title: presentation.approveTitle, target: nil, action: nil)
        approve.frame = NSRect(x: 236, y: 16, width: 100, height: 32)
        approve.bezelStyle = .rounded
        // **不给它任何 keyEquivalent**,这一行的缺席是有意的(见上面 deny 那段裁定)。
        approve.target = self
        approve.action = #selector(approveTapped(_:))
        approve.identifier = NSUserInterfaceItemIdentifier(request.id)
        content.addSubview(approve)

        window.contentView = content
        windows[request.id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 收场了 —— 关窗,**不发决定**(规矩③)。
    public func dismiss(_ ids: [String]) {
        for id in ids {
            windows[id]?.close()
            windows.removeValue(forKey: id)
        }
    }

    public func dismissAll() {
        dismiss(Array(windows.keys))
    }

    @objc private func approveTapped(_ sender: NSButton) {
        decide(sender, .approve)
    }

    @objc private func denyTapped(_ sender: NSButton) {
        decide(sender, .deny)
    }

    private func decide(_ sender: NSButton, _ decision: A2ConfirmationDecision) {
        guard let id = sender.identifier?.rawValue else { return }
        // 先关窗再发决定:发出去之后内核会推 `arbitration`,那条事件也会要求关这个窗 ——
        //   先关掉,后到的 dismiss 就是个空操作,不会出现「窗已经没了还去关一次」的竞态。
        windows[id]?.close()
        windows.removeValue(forKey: id)
        onDecision(id, decision)
    }
}
