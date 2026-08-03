// AAHostMacOS —— 菜单栏轻壳(14 票):**渲染器 A**(`AAMenuModel → NSMenu`)+ 菜单生命周期 + 动作路由。
//
// ============================================================================
// 薄壳铁律:所有菜单动作只有**一个出口**
// ============================================================================
// 每一个可点菜单项的 action 都是本文件的 `menuItemActivated(_:)`,它做的事只有三步:
//   ① 从 `sender.representedObject` 取回那一项的 `AAMenuItemModel`(里面写着 capabilityID + params);
//   ② 若该项声明了 `prompts`(参数只能当场问用户,如换订阅源的 name/source),弹输入框收齐;
//   ③ 调 `registry.invoke(capabilityID:input:)`。
// **没有第四步。** 菜单项里没有任何 if 判断「这个要不要确认」「那个要不要先停内核」——
//   风险分级与确认路由是 `Registry.invoke` 的职责,GUI 与 CLI 因此物理上走同一条路径。
//   `proxy.subscription.add`(dangerous)从菜单点下去,与 `aa proxy subscription add` 走的是同一个路由层,
//   同样弹宿主确认、同样挡得住 deny —— 这就是「GUI 与 CLI 同源」可被门禁核验的形态。
//
// ============================================================================
// 实时反映:靠 NSMenuDelegate,不靠定时器
// ============================================================================
// `menuWillOpen` 里重新取状态(三条 safe 能力)→ 重建模型 → 重建菜单项。菜单没打开时一次调用都不发,
//   既不烧 CPU 也不会在后台反复打内核 REST。代价:取状态是**同步**的,内核 REST 卡住会拖慢菜单弹出。
//   V1 接受(本机 127.0.0.1,且 SocketHTTPPort 有超时);真要改成异步得先解决「菜单已弹出后再更新内容」的
//   闪烁问题,不在 14 票范围内 —— 记为债务。
//
// 依赖边:AAHostMacOS → AAUISystem(纯模型)+ AAHostRuntime(注册表)+ AAContracts。

import AppKit
import AAContracts
import AAHostRuntime
import AAUISystem

/// 菜单栏菜单的控制器:持有模型、建 NSMenu、路由动作。
///
/// 生命周期:调用方(AppDelegate)必须持有本对象 —— 菜单项的 target 是**弱引用**,
///   不持有的话点了没反应,而且是静默的(15 票的关于页踩过同一个坑,这里沿用那条经验)。
@MainActor
final class AAMenuBarController: NSObject, NSMenuDelegate {

    /// 收集用户输入的替身(test-only seam 的注入点)。
    ///
    /// 缺省 nil = 走真 NSAlert 输入框。**本文件不读任何环境变量** —— 注入由 `HostApp.swift` 在
    ///   `#if AA_TESTING` 里完成,好让「全仓只有 HostApp.swift 用条件编译符号」这条既有约定继续成立。
    typealias PromptCollector = @MainActor ([AAMenuPrompt], CapabilityDescriptor) -> [String: JSONValue]?

    private let registry: Registry
    /// 15 票的关于页菜单项由外部提供(`AboutWindowController.makeMenuItem()`)。
    /// 本控制器**不重写关于页**:那是 GPL 义务呈现面,重写一次 = 重新承担一次法律正确性风险。
    private let aboutItemProvider: @MainActor () -> NSMenuItem
    private let promptCollector: PromptCollector?

    /// 当前菜单模型(最近一次重建的结果)。供 test/dev seam 与调试查看。
    private(set) var model: AAMenuModel = AAMenuModel(items: [])
    private var menu: NSMenu?

    init(registry: Registry,
         aboutItemProvider: @escaping @MainActor () -> NSMenuItem,
         promptCollector: PromptCollector? = nil) {
        self.registry = registry
        self.aboutItemProvider = aboutItemProvider
        self.promptCollector = promptCollector
        super.init()
    }

    // ============ 菜单建立与刷新 ============

    /// 建出挂到 NSStatusItem 上的那个 NSMenu(内容立即填一次,之后每次打开由 `menuWillOpen` 刷新)。
    func makeMenu() -> NSMenu {
        let m = NSMenu()
        // 必须关掉自动启用:否则 AppKit 会按「target 能不能响应 action」自行决定灰不灰,
        //   模型里的 `enabled`(以及它承载的「为什么点不了」)就会被系统覆盖掉。
        m.autoenablesItems = false
        m.delegate = self
        menu = m
        rebuild()
        return m
    }

    /// NSMenuDelegate:菜单**将要打开** → 重取状态、重建。这是「状态变化实时反映」的实现点。
    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    /// 重取状态 → 造模型 → 渲染进 NSMenu。
    func rebuild() {
        guard let m = menu else { return }
        model = AAMenuModelBuilder.build(capabilities: registry.list(), state: readState())
        AAMenuRenderer.apply(model, to: m, target: self,
                             action: #selector(menuItemActivated(_:)),
                             aboutItem: aboutItemProvider())
    }

    /// 经**能力面**取当前状态(三条 safe 只读能力)。GUI 不自己去读内核 / 文件,与关于页同一条铁律。
    ///
    /// 三条能力都是 safe → `Registry.invoke` 同步直执行,拿得到 `.success`。
    ///   任一条失败/缺失 → 该维度按「取不到」处理并往 notes 记一条,菜单如实显示,绝不装作正常。
    private func readState() -> AAProxyUIState {
        var notes: [String] = []
        func read(_ id: String) -> JSONValue? {
            guard registry.describe(id) != nil else { return nil }   // 能力不存在:不记 note,菜单本来就不会有那一块
            switch registry.invoke(capabilityID: id, input: nil) {
            case .success(let v): return v
            case .failure(let e): notes.append("\(id) 调用失败:\(e.code)"); return nil
            case .pending:        notes.append("\(id) 返回 pending(safe 能力不应如此)"); return nil
            }
        }
        return AAProxyUIState.from(status: read("proxy.status"),
                                   groups: read("proxy.groups.list"),
                                   subscriptions: read("proxy.subscription.list"),
                                   extraNotes: notes)
    }

    // ============ 动作路由(唯一出口)============

    @objc func menuItemActivated(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? AAMenuItemModel,
              let capID = entry.capabilityID else {
            hostLog("[menu] 菜单项「\(sender.title)」没有绑定能力 id —— 不做任何事(这是 bug,可点项必须绑能力)")
            return
        }
        guard let descriptor = registry.describe(capID) else {
            // 构造期就只为真实存在的能力造项,走到这里说明能力清单在菜单建好之后变了。如实记录,不静默。
            hostLog("[menu] 菜单项「\(sender.title)」绑定的能力已不存在: \(capID)")
            return
        }

        var input = entry.params
        if !entry.prompts.isEmpty {
            guard let collected = collectPrompts(entry.prompts, descriptor: descriptor) else {
                hostLog("[menu] 用户取消了输入,不发起调用 [\(capID)]")
                return
            }
            for (k, v) in collected { input[k] = v }
        }
        invoke(capID, input.isEmpty ? nil : .object(input))
    }

    /// **唯一的能力调用出口**。放到后台队列:能力 handler 会打内核 REST / 跑 networksetup,
    /// 在主线程上做会卡住整个 UI;而 dangerous 的确认回调本来就是「后台调用 → 切主线程弹窗」的形状
    /// (与 UDS 那条路径逐字一致),放后台反而与既有确认路由完全同构。
    private func invoke(_ capabilityID: String, _ input: JSONValue?) {
        hostLog("[menu] 发起能力调用 [\(capabilityID)] \(AppDelegate.renderInput(input))")
        let registry = self.registry
        DispatchQueue.global(qos: .userInitiated).async {
            switch registry.invoke(capabilityID: capabilityID, input: input) {
            case .success:
                hostLog("[menu] 能力调用结果 [\(capabilityID)]: success")
            case .failure(let err):
                hostLog("[menu] 能力调用结果 [\(capabilityID)]: failed code=\(err.code) detail=\(err.detail)")
            case .pending(let requestID):
                hostLog("[menu] 能力调用结果 [\(capabilityID)]: pending requestId=\(requestID)(等待宿主确认)")
            }
        }
    }

    /// 弹输入框收齐 prompts 声明的参数。取消 → nil(调用方据此中止,绝不带空值硬发)。
    private func collectPrompts(_ prompts: [AAMenuPrompt],
                                descriptor: CapabilityDescriptor) -> [String: JSONValue]? {
        if let collector = promptCollector { return collector(prompts, descriptor) }

        NSApp.activate(ignoringOtherApps: true)   // accessory app 不 activate 会弹到别人后面(与确认框同一条经验)
        let alert = NSAlert()
        alert.messageText = descriptor.summary.components(separatedBy: "(").first ?? descriptor.id
        alert.informativeText = "能力:\(descriptor.id)\n\n填写后仍会走宿主的风险路由(dangerous 会再弹一次最终确认)。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")

        let rowHeight: CGFloat = 48
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320,
                                             height: rowHeight * CGFloat(prompts.count)))
        var fields: [(String, NSTextField)] = []
        for (i, p) in prompts.enumerated() {
            let y = container.bounds.height - CGFloat(i + 1) * rowHeight
            let label = NSTextField(labelWithString: p.label)
            label.frame = NSRect(x: 0, y: y + 24, width: 320, height: 16)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.toolTip = p.placeholder
            let field = NSTextField(frame: NSRect(x: 0, y: y, width: 320, height: 22))
            field.placeholderString = p.placeholder
            container.addSubview(label)
            container.addSubview(field)
            fields.append((p.name, field))
        }
        alert.accessoryView = container
        fields.first?.1.becomeFirstResponder()

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var out: [String: JSONValue] = [:]
        for (name, field) in fields {
            out[name] = .string(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    // ============ test/dev seam:程序化激活一个菜单项 ============

    /// 找到绑定了指定能力 id 的那个**真 NSMenuItem**,并经 `NSApp.sendAction` 触发它的 action。
    ///
    /// 为什么要有它:门禁是 headless 的,没人能去点菜单。但「dangerous 从**菜单路径**发起仍触发宿主确认」
    ///   这条验收,只有真的走一遍 NSMenuItem 的 target/action 连线才算数 —— 直接调 `registry.invoke`
    ///   证明不了菜单项接对了线。本方法先跑一次 `menuWillOpen` 的重建路径(保证被点的是当前状态下的那一项),
    ///   再让 AppKit 派发 action,与用户真点一下的差别只剩「鼠标事件」本身。
    ///
    /// 本方法**不读任何环境变量、不改变任何行为**,故不加条件编译;是否调用它由 HostApp.swift 的
    ///   `#if AA_TESTING` 决定。
    /// - Returns: 是否成功找到并激活。
    @discardableResult
    func simulateMenuClick(capabilityID: String) -> Bool {
        guard let m = menu else {
            hostLog("[menu-probe] 菜单尚未建立,无法激活 \(capabilityID)")
            return false
        }
        rebuild()   // 与真实打开菜单同一条路径(menuWillOpen → rebuild)
        guard let item = AAMenuBarController.findItem(in: m, capabilityID: capabilityID) else {
            hostLog("[menu-probe] 菜单里找不到绑定 \(capabilityID) 的项")
            return false
        }
        guard item.isEnabled, let action = item.action else {
            hostLog("[menu-probe] 菜单项「\(item.title)」不可点(enabled=\(item.isEnabled)),不激活")
            return false
        }
        hostLog("[menu-probe] 激活菜单项「\(item.title)」→ capabilityID=\(capabilityID)")
        NSApp.sendAction(action, to: item.target, from: item)
        return true
    }

    /// 递归查找(含子菜单)。
    private static func findItem(in menu: NSMenu, capabilityID: String) -> NSMenuItem? {
        for item in menu.items {
            if let entry = item.representedObject as? AAMenuItemModel, entry.capabilityID == capabilityID,
               entry.kind == .action {
                return item
            }
            if let sub = item.submenu, let found = findItem(in: sub, capabilityID: capabilityID) {
                return found
            }
        }
        return nil
    }
}

// ============================================================================
// 渲染器 A:AAMenuModel → NSMenu
// ============================================================================

/// **渲染器 A**。与 `AAMenuSnapshotRenderer`(渲染器 B,出 PNG)吃同一个 `AAMenuModel`。
///
/// 这里刻意只做「照模型摆项」这一件事:标题、勾选、灰不灰、绑哪个能力,全部来自模型。
///   任何一处在这里现算,都会让快照(走渲染器 B)与真菜单产生一条门禁看不见的分叉。
@MainActor
enum AAMenuRenderer {
    static func apply(_ model: AAMenuModel, to menu: NSMenu,
                      target: AnyObject, action: Selector, aboutItem: NSMenuItem) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for item in model.items {
            menu.addItem(make(item, target: target, action: action, aboutItem: aboutItem))
        }
    }

    private static func make(_ model: AAMenuItemModel,
                             target: AnyObject, action: Selector, aboutItem: NSMenuItem) -> NSMenuItem {
        switch model.kind {
        case .separator:
            return NSMenuItem.separator()

        case .about:
            // 15 票造好的那一项原样挂进来(target 指向 AboutWindowController,不经本控制器)。
            return aboutItem

        case .quit:
            let item = NSMenuItem(title: model.title,
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
            return item

        case .header, .info:
            // nil action + 显式 isEnabled=false:只读行,点不动。
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.representedObject = model
            return item

        case .group:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            // 尊重模型,**不要硬编码 true**。今天 builder 从不产 disabled 的分组,所以写死也「碰巧对」——
            //   但那是在「两个渲染器同吃一个模型」这条不变式上留了道分叉:渲染器 B 是按模型上色的,
            //   哪天 builder 真产出 disabled 分组,两边就会不一致,而**快照恰恰抓不到这种分叉**
            //   (快照比的是 B 的输出,A 的偏差它看不见)。不变式要靠两边都老实,不能靠「碰巧」。
            item.isEnabled = model.enabled
            item.state = model.checked ? .on : .off
            let sub = NSMenu()
            sub.autoenablesItems = false
            for child in model.children {
                sub.addItem(make(child, target: target, action: action, aboutItem: aboutItem))
            }
            item.submenu = sub
            item.representedObject = model
            return item

        case .action:
            let item = NSMenuItem(title: model.title, action: action, keyEquivalent: "")
            item.target = target
            item.isEnabled = model.enabled
            item.state = model.checked ? .on : .off
            if let reason = model.disabledReason { item.toolTip = reason }
            item.representedObject = model
            return item
        }
    }
}
