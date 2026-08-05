// A2Panel —— 菜单模型的**构造逻辑**(10 票,自 14 票 `AAMenuModelBuilder` 平移并改喂养源)。
// 纯函数,零 AppKit、零 UDS、零 I/O。
//
// ============================================================================
// 为什么状态由调用方传入,而不是这里自己去取
// ============================================================================
// 「状态变化在菜单实时反映」这条验收,如果要靠起 GUI + 点开菜单 + 人眼看,就永远进不了 headless 门禁。
//   把「取状态」与「按状态造模型」切开之后:
//     * 取状态是**会话**的事(`A2PanelSession`:注册拿快照 + 收推送 + 按需重读三条 safe 能力);
//     * 造模型是**纯函数** —— 喂三种不同状态进来,断言吐出三种不同模型,这条验收就成了可机读的纯逻辑断言。
//   代价是「会话真的会在事件到达时重取状态」这一步纯逻辑验不到,那一步由 `A2PanelProjection` 的
//   `A2PanelEffect` 断言 + 旗舰 e2e(真内核 + 真事件流)承担。
//
// ============================================================================
// 薄壳铁律(ADR 0008 第 5 条)在本文件的具体形态
// ============================================================================
// * 构造器只为**内核快照里真实存在**的能力生成菜单项 —— 能力缺席时对应菜单项直接不出现,
//   而不是出现一个点了报「未知能力」的假入口。壳**不自带**任何能力名单。
// * 取值域(模式有哪几档)读 descriptor 的 `allowedValues`,不硬编码。
// * 要问用户哪些参数,从 descriptor 的必填参数**推导**,不另抄一份名单。
// * 每一项的动作 = `capabilityID` + `params`,渲染器一律经同一个出口发出去。菜单里没有 if。
//
// 依赖边:A2Panel → A2Contract。零 AppKit。

import A2Contract

/// 由「壳的状态」造出菜单模型。**纯函数**:同样的输入必然给出同样的模型。
public enum A2MenuModelBuilder {

    /// 模式取值 → 人读名。取值域本身由 `proxy.mode.set` 的 `allowedValues` 声明(单一来源在能力描述符里),
    /// 这里只负责翻译成中文;内核新增了模式而这里没翻译 → 直接显示原值,不隐藏。
    static func modeDisplayName(_ raw: String) -> String {
        switch raw {
        case "rule":   return "规则"
        case "global": return "全局"
        case "direct": return "直连"
        default:       return raw
        }
    }

    public static func build(state: A2PanelState) -> A2MenuModel {
        var byID: [String: A2CapabilityDescriptor] = [:]
        for c in state.capabilities { byID[c.id] = c }
        func has(_ id: String) -> Bool { byID[id] != nil }

        let proxy = state.proxy
        var items: [A2MenuItemModel] = []
        items.append(.header("A2 Panel · 代理"))
        items.append(.separator())

        // ---- ⓪ 连接与仲裁面(新架构才有的一段:壳是**对等客户端**,连没连上是用户要知道的事)----
        switch state.connection {
        case .connected:
            var line = "内核:已连接"
            if let v = state.kernelStatus?.version { line += " v\(v)" }
            items.append(.info(line))
        case let .disconnected(reason):
            // 断连**不是**「代理停了」:数据面不随控制面起落(ADR 0007 修订版)。措辞必须分清这两件事,
            //   否则用户会以为关掉壳就断网了 —— 那正是「退出即还原」废除之后最容易产生的误解。
            items.append(.info("内核:未连接(\(reason))— 代理不受影响,仅本面板失联"))
        }
        if let arbitration = state.arbitration {
            // 壳自己就是那个确认器。这一行是「内核认到我了没有」的**运行时证据**,
            //   也是 dangerous 能不能走通的那条事实(ADR 0005 修订版第③层)。
            items.append(.info(arbitration.confirmerPresent
                               ? "确认器:在场(dangerous 会弹到这里)"
                               : "确认器:不在场(dangerous 一律默拒)"))
            if !arbitration.pending.isEmpty {
                items.append(.info("待确认:\(arbitration.pending.count) 条"))
            }
        }
        items.append(.separator())

        // ---- ① 基础状态(04 In:内核运行状态 / 监听端口 / 当前模式与节点)----
        if has("proxy.status") {
            if proxy.kernelRunning {
                var line = "mihomo:运行中"
                if let v = proxy.kernelVersion { line += " \(v)" }
                if !proxy.apiReachable { line += "(控制面未就绪)" }
                items.append(.info(line, capabilityID: "proxy.status", userAction: .basicStatus))
                var detail: [String] = []
                detail.append("模式:" + (proxy.mode.map(modeDisplayName) ?? "未知"))
                detail.append("节点:" + (proxy.currentNode.map { $0.isEmpty ? "未选择" : $0 } ?? "未知"))
                detail.append("端口:" + (proxy.mixedPort.map(String.init) ?? "未知"))
                items.append(.info(detail.joined(separator: " · "),
                                   capabilityID: "proxy.status", userAction: .basicStatus))
            } else {
                items.append(.info("mihomo:未运行", capabilityID: "proxy.status", userAction: .basicStatus))
            }
        }
        for note in proxy.notes { items.append(.info("⚠️ \(note)")) }
        items.append(.separator())

        // ---- ② 系统代理开关(04 In:系统代理开关)----
        //
        // 14 票在这里记过一条「已知缺口」:接管态没有只读能力面,菜单只能并列两项、不显示勾选。
        //   新契约把 `systemProxy.takenOver` 写进了 `proxy.status`(07 票),**缺口已填** —— 显示勾选态。
        if has("proxy.system.enable") {
            items.append(A2MenuItemModel(
                kind: .action, title: "开启系统代理",
                enabled: proxy.kernelRunning,
                checked: proxy.systemProxyTakenOver,
                capabilityID: "proxy.system.enable",
                userAction: .systemProxyToggle,
                disabledReason: proxy.kernelRunning ? nil : "mihomo 未运行,接管后会指向死端口"))
        }
        if has("proxy.system.disable") {
            // 关闭**永远可点**:mihomo 死了才更需要还原系统代理(否则用户滞留断网态)。
            //   新架构里这条更重要 —— 「退出即还原」已废除,还原**只能**由这条显式命令发起。
            items.append(A2MenuItemModel(
                kind: .action, title: "关闭系统代理(还原)",
                checked: !proxy.systemProxyTakenOver,
                capabilityID: "proxy.system.disable",
                userAction: .systemProxyToggle))
        }
        items.append(.separator())

        // ---- ③ 模式切换(04 In:规则/全局/直连)----
        if let modeCap = byID["proxy.mode.set"],
           let allowed = modeCap.parameters.first(where: { $0.name == "mode" })?.allowedValues,
           !allowed.isEmpty {
            for raw in allowed {
                items.append(A2MenuItemModel(
                    kind: .action,
                    title: "模式:\(modeDisplayName(raw))",
                    enabled: proxy.kernelRunning,
                    checked: proxy.mode == raw,
                    capabilityID: "proxy.mode.set",
                    params: ["mode": .string(raw)],
                    userAction: .modeSwitch,
                    disabledReason: proxy.kernelRunning ? nil : "mihomo 未运行"))
            }
            items.append(.separator())
        }

        // ---- ④ 按组选节点 + 按组测速(04 In:按代理组选节点 / 延迟测速)----
        let canSelect = has("proxy.node.select")
        let canPing = has("proxy.latency.test")
        if canSelect || canPing {
            if proxy.groups.isEmpty {
                items.append(.info(proxy.kernelRunning ? "代理组:无(内核未返回分组)" : "代理组:mihomo 未运行,不可用"))
                // mihomo 没起来时,「选节点」「测速」两项用户操作在菜单里**只以置灰形态存在**——
                //   有意为之:让用户看得见这两件事存在、也看得见此刻为什么不能做,而不是整块消失。
                if canSelect {
                    items.append(A2MenuItemModel(kind: .action, title: "选择节点", enabled: false,
                                                 capabilityID: "proxy.node.select",
                                                 userAction: .nodeSelect,
                                                 disabledReason: "无可用代理组"))
                }
                if canPing {
                    items.append(A2MenuItemModel(kind: .action, title: "延迟测速", enabled: false,
                                                 capabilityID: "proxy.latency.test",
                                                 userAction: .latencyTest,
                                                 disabledReason: "无可用代理组"))
                }
            } else {
                for g in proxy.groups {
                    var children: [A2MenuItemModel] = []
                    if canSelect {
                        for node in g.all {
                            children.append(A2MenuItemModel(
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
                        children.append(A2MenuItemModel(
                            kind: .action,
                            title: "测速本组",
                            capabilityID: "proxy.latency.test",
                            params: ["group": .string(g.name)],
                            userAction: .latencyTest))
                    }
                    let now = g.now.map { $0.isEmpty ? "未选择" : $0 } ?? "未选择"
                    items.append(A2MenuItemModel(kind: .group,
                                                 title: "\(g.name):\(now)",
                                                 children: children))
                }
            }
            items.append(.separator())
        }

        // ---- ⑤ 订阅管理(04 In:可存多个 / 同一时刻激活一个 / 手动更新)----
        if has("proxy.subscription.list") {
            items.append(.info(proxy.subscriptions.isEmpty ? "订阅:无" : "订阅(同一时刻只激活一个)",
                               capabilityID: "proxy.subscription.list",
                               userAction: .subscriptionManage))
        }
        if has("proxy.subscription.activate") {
            for sub in proxy.subscriptions {
                items.append(A2MenuItemModel(
                    kind: .action,
                    title: sub.name,
                    checked: proxy.activeSubscriptionID == sub.id,
                    capabilityID: "proxy.subscription.activate",
                    params: ["id": .string(sub.id)],
                    userAction: .subscriptionManage))
            }
        }
        if has("proxy.subscription.update") {
            // 逐条可更新,**不只更新激活项**(04 票 In 清单的「手动更新」没有限定只能更新激活的那条)。
            let children = proxy.subscriptions.map { sub in
                A2MenuItemModel(
                    kind: .action,
                    title: sub.name,
                    capabilityID: "proxy.subscription.update",
                    params: ["id": .string(sub.id)],
                    userAction: .subscriptionManage)
            }
            // 容器**不认领** userAction:它自己不绑能力,认领了就是「空头认领」——
            //   门禁那条「认领了 04 票用户操作的项都绑了能力 id」会当场抓住(14 票它确实抓到过一次)。
            items.append(A2MenuItemModel(
                kind: .group,
                title: "更新订阅",
                enabled: !children.isEmpty,
                children: children,
                disabledReason: children.isEmpty ? "尚无订阅" : nil))
        }
        if has("proxy.subscription.remove") {
            // 07 票新增的 dangerous 能力。放进菜单是因为它**必须有个人能审的入口**:
            //   删订阅不可逆,而确认器就在这个进程里 —— 从菜单发起时确认弹在同一个壳上,
            //   这正是「带外确认」在 mac 上的样子。
            let children = proxy.subscriptions.map { sub in
                A2MenuItemModel(
                    kind: .action,
                    title: sub.name,
                    capabilityID: "proxy.subscription.remove",
                    params: ["id": .string(sub.id)],
                    userAction: .subscriptionManage)
            }
            items.append(A2MenuItemModel(
                kind: .group,
                title: "删除订阅…",
                enabled: !children.isEmpty,
                children: children,
                disabledReason: children.isEmpty ? "尚无订阅" : nil))
        }
        if let addCap = byID["proxy.subscription.add"] {
            // dangerous:点下去先弹输入框收 name/source,再走**同一个**能力出口 →
            //   内核的三层仲裁强制确认。菜单侧没有任何「要不要确认」的判断,那是内核的事。
            let prompts = addCap.parameters.filter { $0.required }.map {
                // label 用 descriptor 的中文 description,**不用参数名** —— 参数名是给机器看的。
                A2MenuPrompt(name: $0.name,
                             label: $0.description.isEmpty ? $0.name : $0.description,
                             placeholder: $0.name)
            }
            items.append(A2MenuItemModel(
                kind: .action,
                title: "添加 / 替换订阅源…",
                capabilityID: "proxy.subscription.add",
                prompts: prompts,
                userAction: .subscriptionManage))
        }
        items.append(.separator())

        // ---- ⑥ 关于 / 退出 ----
        items.append(A2MenuItemModel(kind: .about, title: "关于 A2 Panel"))
        // 「退出」的语义在新架构里变了,标题必须说出来:壳退出**只是断连**,代理照跑
        //   (ADR 0008 / spec:「退出即还原」废除)。用户点它之前就该知道这件事。
        items.append(A2MenuItemModel(kind: .quit, title: "退出面板(代理继续运行)"))

        return A2MenuModel(items: items)
    }
}
