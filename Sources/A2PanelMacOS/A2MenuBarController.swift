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
// 16 票:第二个出口(引导项),以及为什么它**不是**第二套逻辑
// ============================================================================
// `.bootstrap` 项走的是内嵌内核 bin(ADR 0012 的五条白名单),不经 UDS。本控制器对它做的事与
// 能力项**同构**:读模型里那个字段 → 交给唯一的出口(`onBootstrap`)→ 完事。
//   * 「要不要先弹确认」照样是**数据说了算**(`action.confirmation` 非空就弹),
//     与 prompts 那条同一种姿势 —— 控制器里没有"哪个动作危险"的判断;
//   * 确认框的按钮默认落在**取消**上,与 dangerous 确认器同一条规矩(沉默不是同意)。
//
// ============================================================================
// 状态变化怎么进菜单
// ============================================================================
// 会话在后台线程收推送 → 投影出新的 `A2PanelState` → 投递到主线程 → 本控制器重建 `NSMenu`。
// **不做增量更新 NSMenu**:菜单项少的时候整份重建最不容易错(不会出现「改了标题忘了改勾选」),
// 而重建的输入就是那份纯数据模型 —— 与渲染器 B 吃的是同一份,这正是快照有意义的前提。
//
// ============================================================================
// 19 票:状态栏那一格从"文字"变成"图标 + 状态字"
// ============================================================================
// 图标只取一次(init 时),取不到就一直回落文字 —— 一个 `.app` 跑起来之后资源不会中途长出来。
// 「画什么」这件事本身不在这里判:`A2MenuBarPresentation.resolve` 是纯函数,四种组合各有断言
// (见 `A2MenuBarIconTests`)。本控制器只负责把结果抹到 `statusItem.button` 上。
// **菜单内容一个字没动** —— 状态栏标题不进 `A2MenuModel`,所以 `Snapshots/a2-panel/` 的 golden
// 在本票零漂移(已核实)。

import AppKit
import A2Contract
import A2Panel

@MainActor
public final class A2MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let onInvoke: (String, [String: A2JSON]) -> Void
    /// 第二个参数 = 用户在确认框里勾没勾那个「同时删除 ~/.a2」(17 票)。
    /// 没有确认框、或那个框没有勾选框时恒 false。
    private let onBootstrap: (A2BootstrapMenuAction, Bool) -> Void
    /// 面板本地动作(14 票):不出面板进程的第三条出口
    /// (初始化 A2 skill、安装 mihomo 指令、开启系统代理指令)。
    private let onLocal: (A2PanelLocalAction) -> Void
    private let onAbout: () -> Void
    private let onQuit: () -> Void

    private var model: A2MenuModel
    /// 菜单栏 template 图标;`.app` 之外(`swift build` / `swift test`)取不到 → nil → 回落文字。
    private let icon: NSImage?

    public init(onInvoke: @escaping (String, [String: A2JSON]) -> Void,
                onBootstrap: @escaping (A2BootstrapMenuAction, Bool) -> Void,
                onLocal: @escaping (A2PanelLocalAction) -> Void = { _ in },
                onAbout: @escaping () -> Void,
                onQuit: @escaping () -> Void,
                icon: NSImage? = A2MenuBarIcon.load()) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.onInvoke = onInvoke
        self.onBootstrap = onBootstrap
        self.onLocal = onLocal
        self.onAbout = onAbout
        self.onQuit = onQuit
        self.model = A2MenuModel(items: [])
        self.icon = icon
        super.init()
        apply(A2MenuBarPresentation.resolve(hasIcon: icon != nil, proxyTakenOver: false))
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
        // 状态栏那一格跟着「有没有在接管系统代理」走:菜单不点开也看得出个大概。
        let takenOver = model.flattened.contains {
            $0.capabilityID == "proxy.system.enable" && $0.checked
        }
        apply(A2MenuBarPresentation.resolve(hasIcon: icon != nil, proxyTakenOver: takenOver))
    }

    /// 把呈现决策抹到按钮上。**这里没有任何判断** —— 判断全在 `A2MenuBarPresentation.resolve`。
    private func apply(_ presentation: A2MenuBarPresentation) {
        statusItem.button?.image = presentation.usesIcon ? icon : nil
        statusItem.button?.title = presentation.title
        statusItem.button?.imagePosition = presentation.imagePosition
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

        case .local:
            let item = NSMenuItem(title: model.title, action: #selector(localTapped(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.isEnabled = model.enabled
            item.representedObject = model
            return item

        case .bootstrap:
            let item = NSMenuItem(title: model.title, action: #selector(bootstrapTapped(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.isEnabled = model.enabled
            item.representedObject = model
            // 工具提示如实写出它会跑什么(角标在真菜单里没有位置,只能落到 tooltip)。
            item.toolTip = (!model.enabled ? model.disabledReason : model.bootstrapAction?.badge)
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

    @objc private func bootstrapTapped(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? A2MenuItemModel,
              let action = model.bootstrapAction else { return }
        // 「要不要先确认」由**动作自己的数据**说了算(见文件头)。用户不点确认 = 什么都不发。
        //   弹框本身交给 `A2BootstrapPresenter` —— 「回车归安全那一侧」那条规矩只该有一处实现
        //   (16 票第一版在这里另写了一遍,于是漏掉了"清掉主操作那个自动回车"的半句)。
        //   17 票:那个框里还可能有一个默认不勾的勾选框(「同时删除 ~/.a2」),
        //   它的状态与"批没批准"一起回来 —— 取消时它一律作废(见 `presentConfirmation`)。
        guard let confirmation = action.confirmation else { onBootstrap(action, false); return }
        let choice = A2BootstrapPresenter.presentConfirmation(confirmation)
        guard choice.approved else { return }   // 用户不点确认 = 什么都不发
        onBootstrap(action, choice.checked)
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

    @objc private func localTapped(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? A2MenuItemModel,
              let action = model.localAction else { return }
        onLocal(action)
    }

    @objc private func aboutTapped() { onAbout() }
    @objc private func quitTapped() { onQuit() }
}
