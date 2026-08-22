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
// ============================================================================
// 16 票加了什么:第二个输入(面板本地的引导状态)
// ============================================================================
// `build(state:bootstrap:)` 现在收两份状态,泾渭分明:
//   * `state`     —— **内核说过的话**的投影(快照 + 七族事件),`A2PanelProjection` 的产物;
//   * `bootstrap` —— **面板自己知道的事**(嵌入 bin 在不在、它是什么版本、服务装没装、有没有在途操作)。
// 两份并列而不是合并,理由写在 `A2BootstrapState` 头注:合并会让"投影 = 内核事实"这条口径破掉。
// 缺省 `.hidden`(没有内嵌 bin)时本票新增的区段**一项都不出现**,菜单与 10 票逐字相同 ——
// 于是既有的四份 golden 一个字节都不用动,这不是巧合,是"引导功能整体隐藏"那条要求的直接后果。
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

    public static func build(state: A2PanelState,
                             bootstrap: A2BootstrapState = .hidden) -> A2MenuModel {
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
            // 措辞的边界(14 票改判):**面板断连**仍只是本面板失联(退出仅断连不变);
            //   但「代理不受影响」不能再说 —— 内嵌 mihomo 随内核服务生死,内核真停了代理就是停了。
            //   两种情形面板分不清(它连不上),所以两句都如实说、不替内核猜。
            items.append(.info("内核:未连接(\(reason))— 仅本面板失联;内置代理内核随内核服务起落"))
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
        // ---- ⓪′ 引导区段(16 票 / ADR 0012)——**紧跟连接行**,因为它回答的正是那一行提出的问题:
        //      「没连上,那我该怎么办?」10 票时这个问题的答案只能是"自己去敲 a2 service install"。
        items.append(contentsOf: bootstrapItems(state: state, bootstrap: bootstrap))
        items.append(contentsOf: mihomoItems(state: state, bootstrap: bootstrap))
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
        // **2026-08-22 用户裁定:开启改走 agent**。接管要看本机网络环境行事(哪个网络服务、
        // 端口取哪个、要不要绕过内网),那是需要现场判断的活;面板一键接管在别的机器上未必对。
        // 于是这一项从「能力项(经 UDS 发起)」降为「本地项(复制一段指令)」——
        // `proxy.system.enable` 仍在内核注册表里,agent 照常调得到,只是不再有菜单入口
        // (对账见 `A2PanelFixtures.menuExemptCapabilities`)。
        //
        // **不按 mihomo 在不在跑来禁用**:mihomo 没跑恰恰更该找 agent(它会把整条链一起收拾),
        // 而不是让人对着一个灰掉的入口发呆。
        if has("proxy.system.enable") {
            items.append(A2MenuItemModel(
                kind: .local, title: "开启系统代理(复制指令给 AI 助手)",
                enabled: true,
                checked: proxy.systemProxyTakenOver,
                localAction: .copySystemProxyPrompt))
        }
        if has("proxy.system.disable") {
            // 关闭**永远可点**:mihomo 死了才更需要还原系统代理(否则用户滞留断网态)。
            //   新架构里这条更重要 —— 「退出即还原」已废除,还原**只能**由这条显式命令发起。
            //   2026-08-22 用户裁定又给了它第二重身份:**救命按钮**。系统代理一旦指向死端口,
            //   机器就断网,连 agent 自己都可能上不了网 —— 那一刻用户手上只剩这一项。
            //   所以它**刻意不跟着开启那项改成 prompt**:救命的东西不许经第三者转手。
            items.append(A2MenuItemModel(
                kind: .action, title: "关闭系统代理(还原)",
                checked: false,
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

        // ---- ⑤′ 高级(16 票):卸载与安装**对等**,但它不该和日常操作并排 ----
        if let advanced = advancedGroup(bootstrap: bootstrap) {
            items.append(advanced)
            items.append(.separator())
        }

        // ---- ⑥ 关于 / 退出 ----
        items.append(A2MenuItemModel(kind: .about, title: "关于 A2 Panel"))
        // 小白心智模型只有一个 A2:从 UI 退出时,先安全还原系统代理,再停 a2 服务;
        // daemon 的退出钩子负责收掉内嵌 mihomo。
        items.append(A2MenuItemModel(kind: .quit, title: "退出 A2(同时关闭代理)"))

        // 收口:把分隔线收拾干净(见 `tidySeparators` 的理由)。
        return A2MenuModel(items: tidySeparators(items))
    }

    /// 去掉**首尾**与**连续**的分隔线。
    ///
    /// 16 票才需要它,原因是本票第一次把「一条能力都还不知道」的状态画进了菜单:全新用户第一次打开
    /// `.app` 时还没连上内核,而能力清单**只来自快照** —— 于是上面每一段(状态/开关/模式/分组/订阅)
    /// 都整段缺席,只剩下它们各自那条分隔线,菜单上会连着出现四条横线。
    /// 那不是"信息为零",是"看起来坏了"。
    ///
    /// 收拾的是**呈现**而不是内容:每一段照旧只管"我在不在",不必彼此打听"我前面那段出了没有"
    /// —— 那种打听正是让构造器长出耦合的开端。既有四份装置里本来就没有连续分隔线,
    /// 所以这一步对它们**逐字无影响**(golden 一个字节没动,有断言钉着)。
    ///
    /// (`public` 的理由与 `A2MenuModel.describe` 同类:它是一条**可单独断言**的纯规则,
    ///  "只动分隔线、别的一个字不改"这件事值得有一条直接对着它的用例。)
    public static func tidySeparators(_ items: [A2MenuItemModel]) -> [A2MenuItemModel] {
        var out: [A2MenuItemModel] = []
        for item in items {
            let normalized = item.children.isEmpty
                ? item
                : item.withChildren(tidySeparators(item.children))
            if normalized.kind == .separator {
                // 开头不要、连着不要。
                guard let last = out.last, last.kind != .separator else { continue }
            }
            out.append(normalized)
        }
        while out.last?.kind == .separator { out.removeLast() }
        return out
    }

    // ========================================================================
    // 引导区段(16 票 / ADR 0012)
    // ========================================================================

    /// 连接行下面那几项。**没有内嵌 bin 就一项都不出** —— 那时壳退回 10 票的形态:
    /// 只说"没连上、代理不受影响",不给任何点了会失败的入口(与「能力缺席即不出现」同一条姿势)。
    static func bootstrapItems(state: A2PanelState, bootstrap: A2BootstrapState) -> [A2MenuItemModel] {
        guard bootstrap.embeddedBinAvailable else { return [] }
        var items: [A2MenuItemModel] = []

        // 在途:项**留着但禁用**,另给一条 info 说清在干什么。
        //   为什么不整块换成一条 info:那样菜单会在两帧之间"少一项",用户刚点下去就看见自己点的东西没了。
        let busy = bootstrap.inFlight != nil
        let busyReason = bootstrap.inFlight.map { inFlight -> String in
            switch inFlight {
            case .install:       return "安装中,请稍候"
            case .uninstall:     return "卸载中,请稍候"
            case .restartMihomo: return "重启代理内核中,请稍候"
            }
        }

        switch state.connection {
        case .disconnected:
            // 断连 = 面板连不上内核。装没装由 `service status` 说了算,它答不上来时按"未装"呈现
            //   —— 那正是幂等 install 该被点的时候(装了就是收敛,没装就是装)。
            let title = (bootstrap.serviceState == .installedNotRunning)
                ? "启动内核" : "安装并启动内核"
            items.append(A2MenuItemModel(
                kind: .bootstrap,
                title: title,
                enabled: !busy,
                bootstrapAction: .install,
                disabledReason: busyReason))

        case .connected:
            // 已连上还要出项,只有一种情形:**线上内核与包里这份不是同一版**。
            //   线上版本取 `snapshot.status.version`(hello 全量快照里那一个,与 `a2 version` 同源);
            //   包里那份是启动时问过一次的缓存(不轮询 —— ADR 0012 第 5 条)。
            if let embedded = bootstrap.embeddedKernelVersion,
               let live = state.kernelStatus?.version,
               embedded != live {
                items.append(A2MenuItemModel(
                    kind: .bootstrap,
                    // 「短暂中断」写进标题(14 票):内嵌 mihomo 随内核重启带下再拉起 —— 用户点之前就该知道。
                    title: "升级内核 v\(live)→v\(embedded)(重启服务,代理短暂中断)",
                    enabled: !busy,
                    bootstrapAction: .install,
                    disabledReason: busyReason))
                // 标题只放得下一句,而这一次点击的后果不止一句 —— 剩下的**摆在点之前**,
                //   而不是等它发生了再让用户去猜(升级会重启内核 → 面板断连重连 →
                //   在途的 dangerous 确认随之收场,那是 08 票定的降级行为,如实说出来)。
                items.append(.info("↳ 重启会把内置代理内核一并带下再拉起(秒级瞬断);面板短暂断开重连,在途确认按默认拒绝收场"))
            }
        }

        if let inFlight = bootstrap.inFlight {
            switch inFlight {
            case .install:       items.append(.info("⏳ 安装中…(经包内内核 bin;装完面板会自动重连)"))
            case .uninstall:     items.append(.info("⏳ 卸载中…"))
            case .restartMihomo: items.append(.info("⏳ 重启代理内核中…(秒级瞬断)"))
            }
        }
        // 失败**如实一行**,含退出码语义。不重试、不掩饰:点了没成,用户有权知道内核说了什么。
        if let failure = bootstrap.lastFailure {
            items.append(.info("⚠️ 引导失败:\(failure.displayLine)"))
            // 内核给了指引就原样摊在下面(17 票:`service_purge_blocked` 那条的价值全在这几行 ——
            //   "先 a2 proxy off 再来"。壳一个字不改写,也不替它挑哪条更重要)。
            for line in failure.guidanceLines { items.append(.info(line)) }
        }
        return items
    }

    /// mihomo 区段(14 票 / 04·05 票定稿,08 票加装入口):状态行、「尚未配置节点」提示、
    /// 「安装 mihomo」入口、重启项、AI 助手说明入口。
    ///
    /// 与引导区段同一条隐藏纪律:没有内嵌 bin 就一项都不出(dev / 测试态菜单与 10 票逐字相同)。
    /// 「复制 AI 助手使用说明」**未装也出现**(04 票裁定):内容随状态自适应 ——
    /// 未装版教 agent 引导用户点菜单安装,而不是让一个装了面板的人自己去猜下一步。
    static func mihomoItems(state: A2PanelState, bootstrap: A2BootstrapState) -> [A2MenuItemModel] {
        guard bootstrap.embeddedBinAvailable else { return [] }
        var items: [A2MenuItemModel] = []
        let busy = bootstrap.inFlight != nil
        let connected: Bool = {
            if case .connected = state.connection { return true }
            return false
        }()

        if let facts = bootstrap.mihomoFacts {
            switch facts.mode {
            case .off:
                // 未启用**仍不出状态行**(引导启用是 agent 对话流的事,07 票:面板不劝装),
                // 但 08 票给了一条**入口**:一次点击复制一段给 agent 的指令,由对话流接手。
                // 这不是"面板替你装 mihomo" —— 面板一个字节都不下载,它只负责把人接回 agent 那边。
                //
                // 要求已连上内核:断连时 `mihomoFacts` 多半是断开前问到的旧答案,而这段指令的
                // 第一步就是让 agent 去跑 CLI —— 内核都没跑的时候,该出的是「安装并启动内核」。
                if connected {
                    items.append(A2MenuItemModel(
                        kind: .local,
                        title: "安装 mihomo(复制指令给 AI 助手)",
                        enabled: true,
                        localAction: .copyInstallMihomoPrompt))
                }
            case .observe:
                items.append(.info("代理内核:observe(只读旁观本机已有 mihomo)"))
            case .embedded:
                let stateLine: String
                switch facts.embeddedState {
                case .running: stateLine = "内置代理内核:运行中"
                case .stopped: stateLine = "内置代理内核:未在运行"
                case .failed:  stateLine = "内置代理内核:故障(已暂停重拉)"
                }
                items.append(.info(stateLine))
                if facts.embeddedState == .running && !facts.hasProxies {
                    // 可点 = 复制指令给 agent(04 票:把人引向 agent,面板不做配置 UI)。
                    // **08 票改判**:复制的从"使用说明"换成「请帮我把代理用起来」那段指令 ——
                    // 这一刻用户缺的不是"A2 是什么",而是"谁来把节点配上",对症的是指令。
                    items.append(A2MenuItemModel(
                        kind: .local,
                        title: "⚠ 尚未配置节点 — 让你的 AI 助手帮你配置",
                        enabled: true,
                        localAction: .copyInstallMihomoPrompt))
                }
                let restartReason: String? = {
                    if busy { return "有引导操作在途" }
                    if case .disconnected = state.connection { return "内核未连接(重启经内核服务)" }
                    return nil
                }()
                items.append(A2MenuItemModel(
                    kind: .bootstrap,
                    title: "重启代理内核",
                    enabled: restartReason == nil,
                    bootstrapAction: .restartMihomo,
                    disabledReason: restartReason))
            }
        }

        items.append(A2MenuItemModel(
            kind: .local,
            title: "复制 AI 助手使用说明",
            enabled: true,
            localAction: .copyAssistantGuide))
        return items
    }

    /// 「高级」子菜单。有内嵌 bin 就常驻 —— 能装就能卸(ADR 0012 第 6 条),
    /// 卸不了的时候**置灰并说明为什么**,而不是整项消失。
    static func advancedGroup(bootstrap: A2BootstrapState) -> A2MenuItemModel? {
        guard bootstrap.embeddedBinAvailable else { return nil }
        let reason: String? = {
            if bootstrap.inFlight != nil { return "有引导操作在途" }
            if bootstrap.serviceState == .notInstalled { return "服务尚未安装,没有可卸的东西" }
            if bootstrap.serviceState == nil { return "读不到服务态(`service status` 没答上来)" }
            return nil
        }()
        return A2MenuItemModel(
            kind: .group,
            title: "高级",
            children: [
                A2MenuItemModel(
                    kind: .bootstrap,
                    title: "停止并卸载内核服务…",
                    enabled: reason == nil,
                    bootstrapAction: .uninstall,
                    disabledReason: reason),
                // 卸载的口径必须与 CLI 逐字同源(`a2 service uninstall` 的人类面也这么说):
                //   默认只拆 unit,数据同侧的东西不由一次点击带走 —— 除非用户在确认框里
                //   亲手勾上那一格(17 票)。这一行必须把"还有那一格"说出来,否则它就在撒谎。
                .info("(默认只拆服务;确认框里可勾选「同时删除 ~/.a2」)"),
            ])
    }
}
