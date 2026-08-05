// A2PanelMacOS —— **渲染器 A**(`A2MenuModel → NSMenu`,10 票自 14 票平移并改动作出口)。
//
// ============================================================================
// 薄壳铁律在这里的具体形态(ADR 0008 第 5 条)
// ============================================================================
// 每个可点项的 action 都落到**同一个出口**:`A2PanelSession.call(capability:input:)`。
// 菜单项里没有任何 if:要不要确认、能不能改、改完什么样,全是内核的事。
//   * dangerous(`proxy.subscription.add` / `.remove`)因此自动走三层仲裁 —— 壳这边一行特判都没有;
//   * 失败(含 `confirmation_denied`)由会话如实报出来,壳不吞。
//
// 唯一一处「壳自己做的决定」是**要不要先弹输入框**:模型里 `prompts` 非空就先问用户。
//   那不是业务逻辑,是呈现 —— 要问哪些参数由内核的 descriptor 决定(见 `A2MenuModelBuilder`)。
//
// ============================================================================
// 状态变化怎么进菜单
// ============================================================================
// 会话在后台线程收推送 → 投影出新的 `A2PanelState` → 投递到主线程 → 本控制器重建 `NSMenu`。
// **不做增量更新 NSMenu**:菜单项少的时候整份重建最不容易错(不会出现「改了标题忘了改勾选」),
// 而重建的输入就是那份纯数据模型 —— 与渲染器 B 吃的是同一份,这正是快照有意义的前提。

import AppKit
import A2Contract
import A2Panel

@MainActor
public final class A2MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let onInvoke: (String, [String: A2JSON]) -> Void
    private let onAbout: () -> Void
    private let onQuit: () -> Void

    private var model: A2MenuModel

    public init(onInvoke: @escaping (String, [String: A2JSON]) -> Void,
                onAbout: @escaping () -> Void,
                onQuit: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.onInvoke = onInvoke
        self.onAbout = onAbout
        self.onQuit = onQuit
        self.model = A2MenuModel(items: [])
        super.init()
        statusItem.button?.title = "A2"
        let menu = NSMenu()
        menu.autoenablesItems = false   // 让模型的 `enabled` 说了算,不让 AppKit 自己猜
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 换一份模型 → 整份重建菜单。
    public func render(_ model: A2MenuModel) {
        self.model = model
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        for item in model.items { menu.addItem(makeItem(item)) }
        // 状态栏标题跟着「有没有在接管系统代理」走:菜单不点开也看得出个大概。
        statusItem.button?.title = model.flattened.contains {
            $0.capabilityID == "proxy.system.enable" && $0.checked
        } ? "A2 ●" : "A2"
    }

    private func makeItem(_ model: A2MenuItemModel) -> NSMenuItem {
        switch model.kind {
        case .separator:
            return NSMenuItem.separator()

        case .header, .info:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            if model.kind == .header {
                item.attributedTitle = NSAttributedString(
                    string: model.title,
                    attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            }
            return item

        case .group:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.isEnabled = model.enabled
            if let reason = model.disabledReason, !model.enabled { item.toolTip = reason }
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in model.children { submenu.addItem(makeItem(child)) }
            item.submenu = submenu
            return item

        case .action:
            let item = NSMenuItem(title: model.title, action: #selector(actionTapped(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.isEnabled = model.enabled
            item.state = model.checked ? .on : .off
            item.representedObject = model
            if let reason = model.disabledReason, !model.enabled { item.toolTip = reason }
            return item

        case .about:
            let item = NSMenuItem(title: model.title, action: #selector(aboutTapped), keyEquivalent: "")
            item.target = self
            return item

        case .quit:
            let item = NSMenuItem(title: model.title, action: #selector(quitTapped), keyEquivalent: "q")
            item.target = self
            return item
        }
    }

    @objc private func actionTapped(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? A2MenuItemModel,
              let capability = model.capabilityID else { return }
        var input = model.params
        for prompt in model.prompts {
            guard let value = askUser(prompt) else { return }   // 用户取消 = 什么都不发
            input[prompt.name] = .string(value)
        }
        onInvoke(capability, input)
    }

    /// 向用户要一个入参。**只收字符串**:类型由内核的 descriptor 声明,壳不替它转
    /// (转错了是壳在替内核决定「这个值算什么」——那正是薄壳铁律禁止的)。
    private func askUser(_ prompt: A2MenuPrompt) -> String? {
        let alert = NSAlert()
        alert.messageText = prompt.label
        alert.informativeText = "参数名:\(prompt.name)"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = prompt.placeholder
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }

    @objc private func aboutTapped() { onAbout() }
    @objc private func quitTapped() { onQuit() }
}
