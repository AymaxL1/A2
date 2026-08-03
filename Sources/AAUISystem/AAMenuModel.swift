// AAUISystem —— 菜单栏轻壳的**纯数据模型**(14 票)。
//
// ============================================================================
// 为什么要有这一层(这是「快照测试有意义」的唯一前提)
// ============================================================================
// `NSMenu` 本身几乎无法直接截图 —— 它由系统在自己的进程/图层里绘制,没有可靠的离屏渲染入口。
//   于是「菜单快照」若直接对着 NSMenu 做,就只能做成「起 GUI、人肉点开、手工截屏」,进不了 headless 门禁。
//
// 本票的解法是把菜单**先拆成一份纯数据**(本文件),再由两个渲染器分别消费:
//   * 渲染器 A:`AAMenuModel → NSMenu`(在 AAHostMacOS,要 AppKit)—— 真正挂到状态栏上的那份;
//   * 渲染器 B:`AAMenuModel → PNG`(在 AAHostMacOS,自绘 NSView)—— 门禁里可 diff 的那份。
//   两个渲染器吃**同一个模型**:模型错了两边一起错,快照因此能抓住模型层的回归。
//
// ⚠️ **证明力边界(不许含糊)**:快照证明的是「模型」以及「模型 → 两个渲染器」这条共享路径;
//    它**证明不了** AppKit 把真 NSMenu 画成什么样(字号、行距、分隔线粗细、子菜单箭头、深色模式配色……
//    那些全在系统绘制里,渲染器 B 只是**另一种**呈现)。「菜单在屏幕上真的长这样」只能靠人眼确认,
//    门禁给不了这条结论。票面与 README 都按这个口径写。
//
// 依赖边:AAUISystem → AAContracts。**零 AppKit**(PluginProxy 依赖本 target,一旦这里 import AppKit,
//   AppKit 就会被拖进插件域,破坏「插件是纯逻辑」的边界)。

import AAContracts

// ============================================================================
// 用户操作分类(04 票「In(V1)」清单的机读表示)
// ============================================================================

/// 04 票[代理插件 V1 范围](`.scratch/v1-mac-recharter/issues/04-proxy-plugin-v1-scope.md`)
/// 「**In(V1)**」一栏里的六项用户操作。菜单模型的每个可点项都必须**认领**其中一项,
/// 门禁据此核验「菜单覆盖 04 票 in 清单的全部用户操作」。
///
/// ⚠️ 诚实口径:这个枚举是**人工转写**自 04 票那段散文(那票里它就是一行中文句子,没有机读形态)。
///    所以门禁能验的是「六个分类各有菜单项、且每项都落到真实存在的能力 id 上」,
///    **验不了**「这六个分类忠实地等于 04 票作者心里想的那六件事」—— 那一步是人读票面确认的。
public enum AAMenuUserAction: String, CaseIterable, Sendable, Equatable {
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
public struct AAMenuPrompt: Sendable, Equatable {
    /// 参数名(须与能力 descriptor 的 `ParameterSpec.name` 一致)。
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
public struct AAMenuItemModel: Sendable, Equatable {
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
        /// 「关于 AA」——渲染器 A 会把 15 票 `AboutWindowController.makeMenuItem()` 造好的那一项原样挂进来。
        case about
        /// 「退出」。
        case quit
    }

    public let kind: Kind
    public let title: String
    /// 是否可点。渲染器 A 会关掉 NSMenu 的 autoenablesItems,让这个字段说了算。
    public let enabled: Bool
    /// 是否勾选(当前模式 / 当前节点 / 当前激活订阅)。
    public let checked: Bool
    /// 本项对应的能力 id。`nil` = 本项不对应任何能力(分隔线 / 标题 / 退出)。
    ///
    /// **薄壳铁律**:所有可点项的动作都由这个 id + `params` 决定,渲染器 A 一律经
    ///   `registry.invoke(capabilityID:input:)` 这**同一个出口**发起——菜单项里没有任何业务逻辑。
    public let capabilityID: String?
    /// 调用该能力时要带的入参(已能从当前状态确定的那部分)。
    public let params: [String: JSONValue]
    /// 还须当场向用户索取的入参(见 `AAMenuPrompt`)。
    public let prompts: [AAMenuPrompt]
    /// 本项认领的 04 票用户操作分类。只读信息行也可以认领(如「基础状态」)。
    public let userAction: AAMenuUserAction?
    /// 子菜单项(仅 `.group` 用)。
    public let children: [AAMenuItemModel]
    /// 置灰原因(人读)。`enabled == false` 时应给出,让用户知道为什么点不了。
    public let disabledReason: String?

    public init(kind: Kind,
                title: String,
                enabled: Bool = true,
                checked: Bool = false,
                capabilityID: String? = nil,
                params: [String: JSONValue] = [:],
                prompts: [AAMenuPrompt] = [],
                userAction: AAMenuUserAction? = nil,
                children: [AAMenuItemModel] = [],
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
    public static func separator() -> AAMenuItemModel { AAMenuItemModel(kind: .separator, title: "") }
    public static func header(_ title: String) -> AAMenuItemModel {
        AAMenuItemModel(kind: .header, title: title, enabled: false)
    }
    public static func info(_ title: String, capabilityID: String? = nil,
                           userAction: AAMenuUserAction? = nil) -> AAMenuItemModel {
        AAMenuItemModel(kind: .info, title: title, enabled: false,
                        capabilityID: capabilityID, userAction: userAction)
    }
}

// ============================================================================
// 菜单模型
// ============================================================================

/// 一整份菜单(纯数据)。
public struct AAMenuModel: Sendable, Equatable {
    public let items: [AAMenuItemModel]

    public init(items: [AAMenuItemModel]) { self.items = items }

    /// 深度优先展平(父项在前,子项紧随),同时给出缩进层级。
    ///
    /// 两个渲染器的分工在这里显形:渲染器 A 用 `items` + `children` 造**真子菜单**;
    ///   渲染器 B 画不出子菜单(那是系统行为),改用本方法把子项**缩进展开**到同一张图里。
    ///   ——这正是「快照证明模型、不证明 AppKit 呈现」那条边界的具体体现之一。
    public var rows: [(item: AAMenuItemModel, depth: Int)] {
        var out: [(AAMenuItemModel, Int)] = []
        func walk(_ list: [AAMenuItemModel], _ depth: Int) {
            for it in list {
                out.append((it, depth))
                if !it.children.isEmpty { walk(it.children, depth + 1) }
            }
        }
        walk(items, 0)
        return out
    }

    /// 全部项(含子项)的平铺列表,供覆盖面/可追溯性核验。
    public var flattened: [AAMenuItemModel] { rows.map { $0.item } }

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
                            .map { "\($0)=\(AAMenuModel.describe(item.params[$0]!))" }
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

    /// JSONValue → 稳定文本(只用于文本快照;数字按整数/小数两态输出,避免 "1.0" 与 "1" 漂移)。
    static func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .bool(let b):   return b ? "true" : "false"
        case .null:          return "null"
        case .number(let n):
            if n == n.rounded() && n.magnitude < 1e15 { return String(Int64(n)) }
            return String(n)
        case .array(let a):  return "[" + a.map(describe).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { "\($0)=\(describe(o[$0]!))" }.joined(separator: ",") + "}"
        }
    }
}
