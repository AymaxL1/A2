// AAUISystem —— 菜单模型的**构造逻辑**(14 票)。纯函数,零 AppKit、零 UDS、零 I/O。
//
// ============================================================================
// 为什么状态由调用方传入,而不是这里自己去取
// ============================================================================
// 「状态变化在菜单实时反映」这条验收,如果要靠起 GUI + 点开菜单 + 人眼看,就永远进不了 headless 门禁。
//   把「取状态」与「按状态造模型」切开之后:
//     * 取状态是宿主的事(经 registry.invoke 调 proxy.status / groups.list / subscription.list);
//     * 造模型是**纯函数**——喂三种不同状态进来,断言吐出三种不同模型,这条验收就变成了可机读的纯逻辑断言。
//   代价是「宿主真的会在菜单打开时去重取状态」这一步纯逻辑验不到,那一步由渲染器 A 的 NSMenuDelegate 承担,
//   门禁只能经「dangerous 从菜单路径发起」那条 E2E 间接触达。票面按这个口径如实写。
//
// 依赖边:AAUISystem → AAContracts。零 AppKit。

import AAContracts

// ============================================================================
// 状态
// ============================================================================

/// 菜单要呈现的「当前状态」快照(纯数据)。
///
/// 字段与三条 **safe 只读能力** 的输出一一对应,不多不少:
///   * `proxy.status`            → kernelRunning / apiReachable / kernelVersion / mode / mixedPort / currentNode
///   * `proxy.groups.list`       → groups
///   * `proxy.subscription.list` → subscriptions / activeSubscriptionID
///
/// ⚠️ **已知缺口(诚实记账)**:「系统代理当前是否已被本应用接管」在 V1 **没有任何只读能力面暴露**
///    (`proxy.status` 不报它,接管态只存在于宿主私有的持久化文件里)。菜单因此**不显示系统代理的勾选态**,
///    只并列给出「开启 / 关闭」两项。要显示勾选态就得新增一条 safe 能力 —— 那是能力面变更,不在 14 票范围内。
///    绝不靠 GUI 私自去读那个持久化文件来「猜」出勾选态:那正是薄壳铁律禁止的私有逻辑。
public struct AAProxyUIState: Sendable, Equatable {
    /// 一个代理分组(来自 `proxy.groups.list`)。
    public struct Group: Sendable, Equatable {
        public let name: String
        public let type: String
        public let now: String?
        public let all: [String]
        public init(name: String, type: String, now: String?, all: [String]) {
            self.name = name; self.type = type; self.now = now; self.all = all
        }
    }

    /// 一条订阅(来自 `proxy.subscription.list`)。
    public struct Subscription: Sendable, Equatable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public var kernelRunning: Bool
    public var apiReachable: Bool
    public var kernelVersion: String?
    public var mode: String?
    public var mixedPort: Int?
    public var currentNode: String?
    public var groups: [Group]
    public var subscriptions: [Subscription]
    public var activeSubscriptionID: String?
    /// 取状态过程中的失败/降级说明。菜单会**如实**把它显示出来,不装作一切正常。
    public var notes: [String]

    public init(kernelRunning: Bool = false,
                apiReachable: Bool = false,
                kernelVersion: String? = nil,
                mode: String? = nil,
                mixedPort: Int? = nil,
                currentNode: String? = nil,
                groups: [Group] = [],
                subscriptions: [Subscription] = [],
                activeSubscriptionID: String? = nil,
                notes: [String] = []) {
        self.kernelRunning = kernelRunning
        self.apiReachable = apiReachable
        self.kernelVersion = kernelVersion
        self.mode = mode
        self.mixedPort = mixedPort
        self.currentNode = currentNode
        self.groups = groups
        self.subscriptions = subscriptions
        self.activeSubscriptionID = activeSubscriptionID
        self.notes = notes
    }

    /// 从三条 safe 能力的输出 JSON 组装状态(纯函数,可单测)。
    ///
    /// 任一输入为 nil / 形状不对 → 该维度按「取不到」处理并往 `notes` 记一条,**绝不臆造默认值**
    /// (例如 groups 取不到就是空数组 + 一条说明,而不是假装「有一个叫 PROXY 的组」)。
    public static func from(status: JSONValue?,
                            groups: JSONValue?,
                            subscriptions: JSONValue?,
                            extraNotes: [String] = []) -> AAProxyUIState {
        var state = AAProxyUIState()
        state.notes = extraNotes

        if let obj = status?.objectValue {
            state.kernelRunning = boolOf(obj["running"]) ?? false
            state.apiReachable = boolOf(obj["apiReachable"]) ?? false
            state.kernelVersion = obj["version"]?.stringValue
            state.mode = obj["mode"]?.stringValue
            state.mixedPort = intOf(obj["mixedPort"])
            state.currentNode = obj["node"]?.stringValue
        } else {
            state.notes.append("内核状态读取失败(proxy.status 不可用)")
        }

        if let arr = arrayOf(groups?.objectValue?["groups"]) {
            state.groups = arr.compactMap { entry in
                guard let g = entry.objectValue, let name = g["name"]?.stringValue else { return nil }
                return Group(name: name,
                             type: g["type"]?.stringValue ?? "",
                             now: g["now"]?.stringValue,
                             all: (arrayOf(g["all"]) ?? []).compactMap { $0.stringValue })
            }
        } else if groups != nil {
            state.notes.append("代理组读取失败(proxy.groups.list 输出形状不符)")
        }

        if let obj = subscriptions?.objectValue {
            state.activeSubscriptionID = obj["active"]?.stringValue
            state.subscriptions = (arrayOf(obj["subscriptions"]) ?? []).compactMap { entry in
                guard let s = entry.objectValue,
                      let id = s["id"]?.stringValue,
                      let name = s["name"]?.stringValue else { return nil }
                return Subscription(id: id, name: name)
            }
        } else if subscriptions != nil {
            state.notes.append("订阅清单读取失败(proxy.subscription.list 输出形状不符)")
        }

        return state
    }

    // JSONValue 只自带 objectValue / stringValue 两个取值便捷口(见 AAContracts),其余在这里就地取。
    private static func boolOf(_ v: JSONValue?) -> Bool? {
        if case .bool(let b)? = v { return b }
        return nil
    }
    private static func intOf(_ v: JSONValue?) -> Int? {
        if case .number(let n)? = v, n.isFinite { return Int(n) }
        return nil
    }
    private static func arrayOf(_ v: JSONValue?) -> [JSONValue]? {
        if case .array(let a)? = v { return a }
        return nil
    }
}

// ============================================================================
// 构造器
// ============================================================================

/// 由「能力清单 + 当前状态」造出菜单模型。**纯函数**:同样的输入必然给出同样的模型。
public enum AAMenuModelBuilder {

    /// 模式取值 → 人读名。取值域本身由 `proxy.mode.set` 的 `allowedValues` 声明(单一来源在能力描述符里),
    /// 这里只负责翻译成中文;能力里新增了模式而这里没翻译 → 直接显示原值,不隐藏。
    static func modeDisplayName(_ raw: String) -> String {
        switch raw {
        case "rule":   return "规则"
        case "global": return "全局"
        case "direct": return "直连"
        default:       return raw
        }
    }

    /// - Parameters:
    ///   - capabilities: **注册表的实际能力清单**(`Registry.list()`)。构造器只会为清单里**真实存在**的
    ///     能力生成菜单项 —— 这就把「每个菜单动作都能追溯到一个真实能力 id」变成了构造期的不变式,
    ///     而不是事后靠断言去追。能力缺失时对应菜单项直接不出现(而不是出现一个点了报「未知能力」的假入口)。
    ///   - state: 当前状态快照。
    public static func build(capabilities: [CapabilityDescriptor], state: AAProxyUIState) -> AAMenuModel {
        var byID: [String: CapabilityDescriptor] = [:]
        for c in capabilities { byID[c.id] = c }
        func has(_ id: String) -> Bool { byID[id] != nil }

        var items: [AAMenuItemModel] = []
        items.append(.header("AA · 代理"))
        items.append(.separator())

        // ---- ① 基础状态(04 In:内核运行状态 / 监听端口 / 当前模式与节点)----
        if has("proxy.status") {
            if state.kernelRunning {
                var line = "内核:运行中"
                if let v = state.kernelVersion { line += " \(v)" }
                if !state.apiReachable { line += "(控制面未就绪)" }
                items.append(.info(line, capabilityID: "proxy.status", userAction: .basicStatus))
                var detail: [String] = []
                detail.append("模式:" + (state.mode.map(modeDisplayName) ?? "未知"))
                detail.append("节点:" + (state.currentNode.map { $0.isEmpty ? "未选择" : $0 } ?? "未知"))
                detail.append("端口:" + (state.mixedPort.map(String.init) ?? "未知"))
                items.append(.info(detail.joined(separator: " · "),
                                   capabilityID: "proxy.status", userAction: .basicStatus))
            } else {
                items.append(.info("内核:未运行", capabilityID: "proxy.status", userAction: .basicStatus))
            }
        }
        for note in state.notes { items.append(.info("⚠️ \(note)")) }
        items.append(.separator())

        // ---- ② 系统代理开关(04 In:系统代理开关)----
        // 无勾选态:接管态没有只读能力面暴露(见 AAProxyUIState 的「已知缺口」)。并列两项,如实。
        if has("proxy.system.enable") {
            items.append(AAMenuItemModel(
                kind: .action, title: "开启系统代理",
                enabled: state.kernelRunning,
                capabilityID: "proxy.system.enable",
                userAction: .systemProxyToggle,
                disabledReason: state.kernelRunning ? nil : "内核未运行,接管后会指向死端口"))
        }
        if has("proxy.system.disable") {
            // 关闭**永远可点**:内核死了才更需要还原系统代理(否则用户滞留断网态)——这正是 08 票自愈守的那条线。
            items.append(AAMenuItemModel(
                kind: .action, title: "关闭系统代理(还原)",
                capabilityID: "proxy.system.disable",
                userAction: .systemProxyToggle))
        }
        items.append(.separator())

        // ---- ③ 模式切换(04 In:规则/全局/直连)----
        // 取值域**不硬编码**:读 descriptor 里 mode 参数的 allowedValues(09 票立的单一来源)。
        // 声明缺失 → 不造模式项(宁可少一项,也不猜一份取值域出来)。
        if let modeCap = byID["proxy.mode.set"],
           let allowed = modeCap.parameters.first(where: { $0.name == "mode" })?.allowedValues,
           !allowed.isEmpty {
            for raw in allowed {
                items.append(AAMenuItemModel(
                    kind: .action,
                    title: "模式:\(modeDisplayName(raw))",
                    enabled: state.kernelRunning,
                    checked: state.mode == raw,
                    capabilityID: "proxy.mode.set",
                    params: ["mode": .string(raw)],
                    userAction: .modeSwitch,
                    disabledReason: state.kernelRunning ? nil : "内核未运行"))
            }
            items.append(.separator())
        }

        // ---- ④ 按组选节点 + 按组测速(04 In:按代理组选节点 / 延迟测速)----
        let canSelect = has("proxy.node.select")
        let canPing = has("proxy.latency.test")
        if canSelect || canPing {
            if state.groups.isEmpty {
                items.append(.info(state.kernelRunning ? "代理组:无(内核未返回分组)" : "代理组:内核未运行,不可用"))
                // 内核没起来时,「选节点」「测速」两项用户操作在菜单里**只以置灰形态存在**——
                //   有意为之:让用户看得见这两件事存在、也看得见此刻为什么不能做,而不是整块消失。
                //   参数留空 = 无组可填;置灰保证它不可能被真的发出去。
                if canSelect {
                    items.append(AAMenuItemModel(kind: .action, title: "选择节点", enabled: false,
                                                 capabilityID: "proxy.node.select",
                                                 userAction: .nodeSelect,
                                                 disabledReason: "无可用代理组"))
                }
                if canPing {
                    items.append(AAMenuItemModel(kind: .action, title: "延迟测速", enabled: false,
                                                 capabilityID: "proxy.latency.test",
                                                 userAction: .latencyTest,
                                                 disabledReason: "无可用代理组"))
                }
            } else {
                for g in state.groups {
                    var children: [AAMenuItemModel] = []
                    if canSelect {
                        for node in g.all {
                            children.append(AAMenuItemModel(
                                kind: .action,
                                title: node,
                                checked: g.now == node,
                                capabilityID: "proxy.node.select",
                                params: ["group": .string(g.name), "node": .string(node)],
                                userAction: .nodeSelect))
                        }
                    }
                    if canPing {
                        if !children.isEmpty { children.append(.separator()) }
                        children.append(AAMenuItemModel(
                            kind: .action,
                            title: "测速本组",
                            capabilityID: "proxy.latency.test",
                            params: ["group": .string(g.name)],
                            userAction: .latencyTest))
                    }
                    let now = g.now.map { $0.isEmpty ? "未选择" : $0 } ?? "未选择"
                    items.append(AAMenuItemModel(kind: .group,
                                                 title: "\(g.name):\(now)",
                                                 children: children))
                }
            }
            items.append(.separator())
        }

        // ---- ⑤ 订阅管理(04 In:可存多个 / 同一时刻激活一个 / 手动更新)----
        if has("proxy.subscription.list") {
            if state.subscriptions.isEmpty {
                items.append(.info("订阅:无", capabilityID: "proxy.subscription.list",
                                   userAction: .subscriptionManage))
            } else {
                items.append(.info("订阅(同一时刻只激活一个)", capabilityID: "proxy.subscription.list",
                                   userAction: .subscriptionManage))
            }
        }
        if has("proxy.subscription.activate") {
            for sub in state.subscriptions {
                items.append(AAMenuItemModel(
                    kind: .action,
                    title: sub.name,
                    checked: state.activeSubscriptionID == sub.id,
                    capabilityID: "proxy.subscription.activate",
                    params: ["id": .string(sub.id)],
                    userAction: .subscriptionManage))
            }
        }
        if has("proxy.subscription.update") {
            // 逐条可更新,**不只更新激活项**。
            //   V1 In 清单(v1-mac-recharter/04)写的是「订阅管理(可存多个、同一时刻激活一个 profile、**手动更新**)」——
            //   「手动更新」没有限定只能更新激活的那条,而 `proxy.subscription.update` 本身就按 id 收参。
            //   早先只给了「更新当前订阅」一项,那是把 In 清单悄悄收窄了(双轴 CR 抓到)。
            //   做成分组:每条订阅一个子项,想更新哪条更新哪条;一条都没有时整组禁用并说明原因。
            let children = state.subscriptions.map { sub in
                AAMenuItemModel(
                    kind: .action,
                    title: sub.name,
                    capabilityID: "proxy.subscription.update",
                    params: ["id": .string(sub.id)],
                    userAction: .subscriptionManage)
            }
            // 容器**不认领** userAction:它自己不绑能力,认领了就是「空头认领」——
            //   门禁那条「认领了 04 票用户操作的项都绑了能力 id」会当场抓住(它确实抓到过一次)。
            //   真正兑现这条用户操作的是下面每个子项,userAction 挂在它们身上。
            items.append(AAMenuItemModel(
                kind: .group,
                title: "更新订阅",
                enabled: !children.isEmpty,
                children: children,
                disabledReason: children.isEmpty ? "尚无订阅" : nil))
        }
        if let addCap = byID["proxy.subscription.add"] {
            // dangerous:点下去先弹输入框收 name/source,再走**同一个** registry.invoke 出口 →
            //   路由层强制宿主确认。菜单侧没有任何「要不要确认」的判断,那是 Registry 的事。
            //   要问哪些参数从 descriptor 的必填参数**推导**,不在这里另抄一份名单。
            let prompts = addCap.parameters.filter { $0.required }.map {
                // label 用 descriptor 的中文 description,**不用参数名** —— 参数名是给机器看的
                //   (`name` / `source`),弹给人看的输入框标签写英文标识符是把内部命名泄给用户。
                //   description 缺失时才退回参数名(至少不是空标签)。
                AAMenuPrompt(name: $0.name,
                             label: $0.description.isEmpty ? $0.name : $0.description,
                             placeholder: $0.name)
            }
            items.append(AAMenuItemModel(
                kind: .action,
                title: "添加 / 替换订阅源…",
                capabilityID: "proxy.subscription.add",
                prompts: prompts,
                userAction: .subscriptionManage))
        }
        items.append(.separator())

        // ---- ⑥ 关于 / 退出 ----
        items.append(AAMenuItemModel(kind: .about, title: "关于 AA"))
        items.append(AAMenuItemModel(kind: .quit, title: "退出"))

        return AAMenuModel(items: items)
    }
}
