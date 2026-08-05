// A2Panel —— 菜单栏壳的**纯数据模型**(10 票,自 14 票的 `AAUISystem.AAMenuModel` 原封平移)。
//
// ============================================================================
// 为什么要有这一层(这是「快照测试有意义」的唯一前提)—— 与 14 票逐字同一条理由
// ============================================================================
// `NSMenu` 本身几乎无法直接截图 —— 它由系统在自己的进程/图层里绘制,没有可靠的离屏渲染入口。
//   于是「菜单快照」若直接对着 NSMenu 做,就只能做成「起 GUI、人肉点开、手工截屏」,进不了 headless 门禁。
//
// 解法是把菜单**先拆成一份纯数据**(本文件),再由两个渲染器分别消费:
//   * 渲染器 A:`A2MenuModel → NSMenu`(在 A2PanelMacOS,要 AppKit)—— 真正挂到状态栏上的那份;
//   * 渲染器 B:`A2MenuModel → PNG`(在 A2PanelMacOS,自绘 NSView)—— 门禁里可 diff 的那份。
//   两个渲染器吃**同一个模型**:模型错了两边一起错,快照因此能抓住模型层的回归。
//
// ⚠️ **证明力边界(不许含糊)**:快照证明的是「模型」以及「模型 → 两个渲染器」这条共享路径;
//    它**证明不了** AppKit 把真 NSMenu 画成什么样(字号、行距、分隔线粗细、子菜单箭头、深色模式配色……
//    那些全在系统绘制里,渲染器 B 只是**另一种**呈现)。「菜单在屏幕上真的长这样」只能靠人眼确认,
//    门禁给不了这条结论。
//
// ============================================================================
// 10 票改了什么(与 14 票的差异,逐条)
// ============================================================================
// 1. **喂养源换了**:14 票的模型喂自宿主进程内的注册表与 Port;本票喂自**内核事件流的投影**
//    (`A2PanelState`,见 `A2PanelProjection.swift`)。模型形状本身一字未改。
// 2. `JSONValue`(AAContracts)→ `A2JSON`(A2Contract):两族契约不同物,壳只认新契约。
// 3. 「关于 AA」→「关于 A2 Panel」;GPL 声明面随 ADR 0007 修订版收缩为**外部程序声明**(静态文本)。
//
// 依赖边:A2Panel → A2Contract。**零 AppKit**(渲染器才碰 AppKit;模型层必须能在纯逻辑测试里跑)。

import A2Contract

// ============================================================================
// 用户操作分类(04 票「In(V1)」清单的机读表示 —— 14 票立的,本票原样继承)
// ============================================================================

/// 04 票[代理插件 V1 范围]「**In(V1)**」一栏里的六项用户操作。菜单模型的每个可点项都必须**认领**
/// 其中一项,门禁据此核验「菜单覆盖 04 票 in 清单的全部用户操作」。
///
/// ⚠️ 诚实口径:这个枚举是**人工转写**自 04 票那段散文。门禁能验的是「六个分类各有菜单项、
///    且每项都落到内核**真的登记过**的能力 id 上」,**验不了**「这六个分类忠实地等于 04 票作者
///    心里想的那六件事」—— 那一步是人读票面确认的。
public enum A2MenuUserAction: String, CaseIterable, Sendable, Equatable {
    /// 「系统代理开关」。
    case systemProxyToggle
    /// 「模式切换(规则/全局/直连)」。
    case modeSwitch
    /// 「按代理组选节点」。
    case nodeSelect
    /// 「订阅管理(可存多个、同一时刻激活一个 profile、手动更新)」。
    case subscriptionManage
    /// 「延迟测速(URL test,按组)」。
    case latencyTest
    /// 「基础状态(内核运行状态/监听端口/当前模式与节点)」。
    case basicStatus

    /// 人读名(票面原文用词,便于门禁失败信息里直接对上 04 票)。
    public var displayName: String {
        switch self {
        case .systemProxyToggle:  return "系统代理开关"
        case .modeSwitch:         return "模式切换"
        case .nodeSelect:         return "按代理组选节点"
        case .subscriptionManage: return "订阅管理"
        case .latencyTest:        return "延迟测速"
        case .basicStatus:        return "基础状态"
        }
    }
}

// ============================================================================
// 菜单项
// ============================================================================

/// 需要向用户索取的一个入参(菜单项点下去后先弹输入框,再发起能力调用)。
///
/// 为什么要有它:`proxy.subscription.add` 的 name/source 这类参数**取不到于任何状态**——
///   它们只能由用户当场输入。把「要问哪些参数」放进模型,渲染器 A 才能据此弹输入框,
///   而门禁的纯逻辑断言也能核验「add 项确实声明了 name+source 两个必填输入」。
public struct A2MenuPrompt: Sendable, Equatable {
    /// 参数名(须与能力 descriptor 的 `A2ParameterSpec.name` 一致)。
    public let name: String
    /// 输入框标签(人读)。
    public let label: String
    /// 占位提示。
    public let placeholder: String

    public init(name: String, label: String, placeholder: String) {
        self.name = name
        self.label = label
        self.placeholder = placeholder
    }
}

/// 菜单里的一项(纯数据)。
public struct A2MenuItemModel: Sendable, Equatable {
    /// 项的种类。渲染器据此决定画成什么;门禁据此区分「可点项」与「只读项」。
    public enum Kind: String, Sendable, Equatable {
        /// 标题行(不可点)。
        case header
        /// 只读信息行(不可点)。基础状态就是靠它呈现。
        case info
        /// 分隔线。
        case separator
        /// 可点的能力调用项。
        case action
        /// 带子菜单的父项(本身不发起调用)。
        case group
        /// 「关于 A2 Panel」。
        case about
        /// 「退出」。**退出仅断连**(ADR 0008:「退出即还原」废除)。
        case quit
    }

    public let kind: Kind
    public let title: String
    /// 是否可点。渲染器 A 会关掉 NSMenu 的 autoenablesItems,让这个字段说了算。
    public let enabled: Bool
    /// 是否勾选(当前模式 / 当前节点 / 当前激活订阅 / 系统代理接管态)。
    public let checked: Bool
    /// 本项对应的能力 id。`nil` = 本项不对应任何能力(分隔线 / 标题 / 退出)。
    ///
    /// **薄壳铁律**:所有可点项的动作都由这个 id + `params` 决定,渲染器 A 一律经
    ///   `A2KernelClient.callCapability(_:input:)` 这**同一个出口**发起 —— 菜单项里没有任何业务逻辑。
    public let capabilityID: String?
    /// 调用该能力时要带的入参(已能从当前状态确定的那部分)。
    public let params: [String: A2JSON]
    /// 还须当场向用户索取的入参(见 `A2MenuPrompt`)。
    public let prompts: [A2MenuPrompt]
    /// 本项认领的 04 票用户操作分类。只读信息行也可以认领(如「基础状态」)。
    public let userAction: A2MenuUserAction?
    /// 子菜单项(仅 `.group` 用)。
    public let children: [A2MenuItemModel]
    /// 置灰原因(人读)。`enabled == false` 时应给出,让用户知道为什么点不了。
    public let disabledReason: String?

    public init(kind: Kind,
                title: String,
                enabled: Bool = true,
                checked: Bool = false,
                capabilityID: String? = nil,
                params: [String: A2JSON] = [:],
                prompts: [A2MenuPrompt] = [],
                userAction: A2MenuUserAction? = nil,
                children: [A2MenuItemModel] = [],
                disabledReason: String? = nil) {
        self.kind = kind
        self.title = title
        self.enabled = enabled
        self.checked = checked
        self.capabilityID = capabilityID
        self.params = params
        self.prompts = prompts
        self.userAction = userAction
        self.children = children
        self.disabledReason = disabledReason
    }

    // ---- 便捷构造(让 Builder 读起来像菜单本身)----
    public static func separator() -> A2MenuItemModel { A2MenuItemModel(kind: .separator, title: "") }
    public static func header(_ title: String) -> A2MenuItemModel {
        A2MenuItemModel(kind: .header, title: title, enabled: false)
    }
    public static func info(_ title: String, capabilityID: String? = nil,
                            userAction: A2MenuUserAction? = nil) -> A2MenuItemModel {
        A2MenuItemModel(kind: .info, title: title, enabled: false,
                        capabilityID: capabilityID, userAction: userAction)
    }
}

// ============================================================================
// 菜单模型
// ============================================================================

/// 一整份菜单(纯数据)。
public struct A2MenuModel: Sendable, Equatable {
    public let items: [A2MenuItemModel]

    public init(items: [A2MenuItemModel]) { self.items = items }

    /// 深度优先展平(父项在前,子项紧随),同时给出缩进层级。
    ///
    /// 两个渲染器的分工在这里显形:渲染器 A 用 `items` + `children` 造**真子菜单**;
    ///   渲染器 B 画不出子菜单(那是系统行为),改用本方法把子项**缩进展开**到同一张图里。
    public var rows: [(item: A2MenuItemModel, depth: Int)] {
        var out: [(A2MenuItemModel, Int)] = []
        func walk(_ list: [A2MenuItemModel], _ depth: Int) {
            for it in list {
                out.append((it, depth))
                if !it.children.isEmpty { walk(it.children, depth + 1) }
            }
        }
        walk(items, 0)
        return out
    }

    /// 全部项(含子项)的平铺列表,供覆盖面/可追溯性核验。
    public var flattened: [A2MenuItemModel] { rows.map { $0.item } }

    /// 模型的**确定性文本快照**。
    ///
    /// 用途有二:
    ///   ① 快照 PNG 一旦对不上,人要能一眼看出「哪一行变了」——图片 diff 说不出这个,文本能;
    ///   ② 它本身就是一份**确定性远强于像素**的 golden(PNG 若被证明会抖,降级路线就是它)。
    /// 参数按键名排序输出,避免字典序不稳导致的假 diff。
    public var textSnapshot: String {
        var lines: [String] = []
        for (item, depth) in rows {
            let indent = String(repeating: "  ", count: depth)
            switch item.kind {
            case .separator:
                lines.append("\(indent)[separator]")
            default:
                var flags: [String] = [item.kind.rawValue]
                flags.append(item.enabled ? "enabled" : "disabled")
                if item.checked { flags.append("checked") }
                var line = "\(indent)[\(flags.joined(separator: " "))] \(item.title)"
                if let capID = item.capabilityID {
                    line += "  → \(capID)"
                    if !item.params.isEmpty {
                        let rendered = item.params.keys.sorted()
                            .map { "\($0)=\(A2MenuModel.describe(item.params[$0]!))" }
                            .joined(separator: ",")
                        line += " {\(rendered)}"
                    }
                    if !item.prompts.isEmpty {
                        line += " prompts[\(item.prompts.map { $0.name }.sorted().joined(separator: ","))]"
                    }
                }
                if let action = item.userAction { line += "  @\(action.rawValue)" }
                if let reason = item.disabledReason { line += "  (\(reason))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `A2JSON` → 稳定文本(只用于文本快照)。
    ///
    /// 整数与浮点在 `A2JSON` 里本就是两支(见 A2JSON 头注),所以这里**不做** 14 票那种
    /// 「`1.0` 归一成 `1`」的处理 —— 契约里是整数就编成整数,壳不替它猜。
    /// (`public`:确认器的呈现面用同一套规则渲染 `input`,断言也比它 —— 见 `A2ConfirmationPresentation`。)
    public static func describe(_ value: A2JSON) -> String {
        switch value {
        case .string(let s): return s
        case .bool(let b):   return b ? "true" : "false"
        case .null:          return "null"
        case .int(let n):    return String(n)
        case .double(let n): return String(n)
        case .array(let a):  return "[" + a.map(describe).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { "\($0)=\(describe(o[$0]!))" }.joined(separator: ",") + "}"
        }
    }
}
