// A2PanelFixtures —— 壳快照与纯逻辑断言的**共享固定装置**(10 票,自 14 票 `AAMenuFixtures` 平移)。
//
// ============================================================================
// 为什么单独一个 target(而不是塞进 Tests/)
// ============================================================================
// 它有**两类消费者**:`swift test` 里的纯逻辑/快照断言,以及 `a2-panel-snapshot` 这个**可执行**
// (重录 golden、给人眼抽查用产物)。SPM 的 executableTarget 不能依赖 testTarget,
// 所以装置必须住在 `Sources/` 下 —— 与 14 票 `AAHostTestKit` 的理由逐字相同。
//
// 于是「快照覆盖的三种状态」与「状态反映断言喂的三种状态」物理上是同一批,
// 不可能出现「断言验的是 A、图片画的是 B」这种看起来都绿、其实各说各话的局面。
//
// ============================================================================
// ⚠️ 能力清单从哪来 —— 与 14 票最大的差别,必须说清楚
// ============================================================================
// 14 票的装置里能力清单取自**真注册表**(宿主与注册表同进程,`Registry.list()` 现造一份)。
// 新架构里能力清单只有一个权威来源:**内核的快照**。而纯逻辑测试不起 daemon,
// 所以这里是一份**手写的对照清单**(逐条抄自 `kernel/src/capability/proxy.ts` 与 `builtin.ts` 的 manifest)。
//
// 手写清单会漂,所以漂移由**旗舰 e2e** 兜住 —— `a2-panel-probe` 连上**真内核**之后逐条核对:
//   ① 本清单里的每个 id 在真快照里都存在,且 `risk` / `cliAlias` / 参数取值域逐字相同;
//   ② 真快照里每一条 normal/dangerous 的 `proxy.*` 能力,要么出现在菜单里,
//      要么在 `menuExemptCapabilities` 里显式记账(带理由)。
// 换句话说:清单漂了 → e2e 当场红。这比 14 票的「假注册表」更强:那时对照的是同进程的一份副本,
// 现在对照的是**真的跑着的那个内核**。
//
// ⚠️ **这道门是单向的,如实写明**:①逐条比的是「装置里有的,真内核也得有且一致」;
//    「真内核有而装置里没有」只在 **normal/dangerous 的 `proxy.*`** 那一族上会红(反向核对④)。
//    新增一条 `proxy.*` **safe** 能力不会让任何断言变色 —— 那是有意的:菜单本来就不必露出每条只读能力,
//    而 11 票起插件会往注册表里动态加能力,要求「装置 ≡ 真内核」只会让这张表变成日常噪音。

import A2Contract
import A2Panel

/// 菜单模型的固定装置。
public enum A2PanelFixtures {

    // ============ 能力清单(与内核 manifest 逐字对照;漂移由旗舰 e2e 兜)============

    private static func param(_ name: String, _ type: A2ParameterType, _ required: Bool,
                              _ description: String, _ allowed: [String]? = nil) -> A2ParameterSpec {
        A2ParameterSpec(name: name, type: type, required: required, description: description,
                        allowedValues: allowed)
    }

    /// 壳会用到的那部分能力清单(菜单只投影 `proxy.*`;demo 三条留着是因为内核默认注册表里有它们,
    /// 而「菜单不该为它们生成任何项」本身就是一条要验的事)。
    public static let capabilities: [A2CapabilityDescriptor] = [
        A2CapabilityDescriptor(id: "demo.echo", risk: .safe, summary: "回显一条消息(safe 自检样本)",
                               parameters: [param("message", .string, true, "要回显的文本")]),
        A2CapabilityDescriptor(id: "demo.note.set", risk: .normal, summary: "写一条便签(normal 自检样本)",
                               parameters: [param("key", .string, true, "便签键"),
                                            param("value", .string, true, "便签值"),
                                            param("scope", .string, false, "作用域",
                                                  ["session", "persistent"])]),
        A2CapabilityDescriptor(id: "demo.wipe", risk: .dangerous, summary: "抹掉一块磁盘(dangerous 自检样本)",
                               parameters: [param("target", .string, false, "目标标识")]),

        A2CapabilityDescriptor(id: "proxy.status", risk: .safe, summary: "报告代理控制面实况(只读)",
                               parameters: [], cliAlias: ["proxy", "status"]),
        A2CapabilityDescriptor(id: "proxy.config.get", risk: .safe, summary: "读自管配置的可调项",
                               parameters: [], cliAlias: ["proxy", "config"]),
        A2CapabilityDescriptor(id: "proxy.config.set", risk: .normal, summary: "改自管配置的可调项",
                               parameters: [param("mixedPort", .number, false, "混合入站端口"),
                                            param("allowLan", .boolean, false, "是否允许局域网接入"),
                                            param("logLevel", .string, false, "日志档位",
                                                  ["silent", "error", "warning", "info", "debug"]),
                                            param("mode", .string, false, "默认模式",
                                                  ["rule", "global", "direct"])],
                               cliAlias: ["proxy", "config", "set"]),
        A2CapabilityDescriptor(id: "proxy.mode.get", risk: .safe, summary: "读当前模式",
                               parameters: [], cliAlias: ["proxy", "mode", "get"]),
        A2CapabilityDescriptor(id: "proxy.mode.set", risk: .normal, summary: "切换代理模式",
                               parameters: [param("mode", .string, true, "目标模式",
                                                  ["rule", "global", "direct"])],
                               cliAlias: ["proxy", "mode"]),
        A2CapabilityDescriptor(id: "proxy.groups.list", risk: .safe, summary: "列出可切换的代理分组",
                               parameters: [], cliAlias: ["proxy", "groups"]),
        A2CapabilityDescriptor(id: "proxy.node.select", risk: .normal, summary: "在某个分组里选一个节点",
                               parameters: [param("group", .string, true, "分组名"),
                                            param("node", .string, true, "节点名")],
                               cliAlias: ["proxy", "node"]),
        A2CapabilityDescriptor(id: "proxy.latency.test", risk: .safe, summary: "按分组测各节点延迟",
                               parameters: [param("group", .string, true, "分组名"),
                                            param("url", .string, false, "测速 URL"),
                                            param("timeout", .number, false, "单节点超时(毫秒)")],
                               cliAlias: ["proxy", "ping"]),
        A2CapabilityDescriptor(id: "proxy.system.status", risk: .safe, summary: "读系统代理接管态与实况",
                               parameters: [], cliAlias: ["proxy", "system"]),
        A2CapabilityDescriptor(id: "proxy.system.enable", risk: .normal, summary: "把系统代理指向本机内核",
                               parameters: [], cliAlias: ["proxy", "on"]),
        A2CapabilityDescriptor(id: "proxy.system.disable", risk: .normal, summary: "按快照还原系统代理",
                               parameters: [], cliAlias: ["proxy", "off"]),
        A2CapabilityDescriptor(id: "proxy.subscription.list", risk: .safe, summary: "列出订阅与激活项",
                               parameters: [], cliAlias: ["proxy", "subscription", "list"]),
        A2CapabilityDescriptor(id: "proxy.subscription.add", risk: .dangerous, summary: "新增或替换订阅源(dangerous)",
                               parameters: [param("name", .string, true, "订阅展示名"),
                                            param("source", .string, true, "订阅源地址")],
                               cliAlias: ["proxy", "subscription", "add"]),
        A2CapabilityDescriptor(id: "proxy.subscription.update", risk: .normal, summary: "重新拉取一条订阅",
                               parameters: [param("id", .string, true, "订阅 id")],
                               cliAlias: ["proxy", "subscription", "update"]),
        A2CapabilityDescriptor(id: "proxy.subscription.activate", risk: .normal, summary: "激活一条订阅",
                               parameters: [param("id", .string, true, "订阅 id")],
                               cliAlias: ["proxy", "subscription", "activate"]),
        A2CapabilityDescriptor(id: "proxy.subscription.remove", risk: .dangerous, summary: "删除一条订阅(dangerous)",
                               parameters: [param("id", .string, true, "订阅 id")],
                               cliAlias: ["proxy", "subscription", "remove"]),
        A2CapabilityDescriptor(id: "proxy.supervision.get", risk: .safe, summary: "读 mihomo 存活观测",
                               parameters: [], cliAlias: ["proxy", "supervision"]),
        A2CapabilityDescriptor(id: "arbitration.status", risk: .safe, summary: "读仲裁面(只读查询)",
                               parameters: [], cliAlias: ["arbitration", "status"]),
    ]

    /// 内核**当前停用**的能力 id(2026-08-12 用户裁定:「restful 控制 mihomo 的功能暂时关闭掉,
    /// 读一下 mihomo 状态就够了;mihomo 应该让用户自己用 agent 去配置」)。
    ///
    /// 这份名单必须与内核 `capability/proxy.ts` 的 `DISABLED_CAPABILITY_IDS` 一致 ——
    /// 旗舰 e2e 的 `PANEL_MANIFEST` 拿真内核快照对 `liveCapabilities`,不一致当场红。
    public static let disabledCapabilityIDs: Set<String> = [
        "proxy.config.set", "proxy.mode.set", "proxy.node.select", "proxy.latency.test",
        "proxy.subscription.list", "proxy.subscription.add", "proxy.subscription.update",
        "proxy.subscription.activate", "proxy.subscription.remove",
    ]

    /// 内核**此刻真会注册**的那一份 —— 对账用。
    ///
    /// 为什么不直接把停用的九条从 `capabilities` 里删掉:上面那份是**渲染器的覆盖面**。
    /// 模式项、节点子菜单、订阅三组的渲染逻辑一行没删(裁定说的是「暂时」),那些断言必须继续跑,
    /// 否则能力恢复注册的那天,渲染面是一片没人验过的代码。两份清单各司其职:
    /// `capabilities` 喂渲染器,`liveCapabilities` 喂对账。
    public static let liveCapabilities: [A2CapabilityDescriptor] =
        capabilities.filter { !disabledCapabilityIDs.contains($0.id) }

    /// **有意不进菜单**的 normal/dangerous 代理能力,逐条带理由。
    ///
    /// 这张表是「反向交叉核对」的唯一豁免口:真内核里每一条可发起的 `proxy.*` 能力,
    /// 要么在菜单里露出,要么在这里记一笔。**空理由不接受**。
    ///
    /// (2026-08-12 起为空:唯一的常客 `proxy.config.set` 随写面一并停用 —— 它已经不在内核注册表里,
    /// 再留一条豁免记录就成了「幽灵名」,探针第⑤条会判红。恢复它的注册时把下面这条理由搬回来:
    /// 「自管配置的可调项不在 04 票 In 清单里,而且它改的是 mihomo 的配置文件而非『当下用哪条线路』——
    /// 属安装/调优面,归 CLI;菜单里给一个能改监听端口的入口,只会让用户在不知道后果的时候改坏一台
    /// 正在用的机器。」)
    public static let menuExemptCapabilities: [String: String] = [
        // 2026-08-22 用户裁定:**开启**系统代理改走 agent(接管要看本机网络环境现场判断),
        // 菜单里那一项降为「复制指令给 AI 助手」的本地项,不再经 UDS 发起 —— 能力本身照常注册,
        // agent 调得到。**关闭那条刻意留在菜单**(救命按钮:代理指向死端口时用户只剩菜单可点),
        // 所以这张表里只有 enable 一条,disable 永远不该出现在这里。
        "proxy.system.enable":
            "开启系统代理改由 agent 执行(2026-08-22 裁定);菜单只留复制指令的本地项。关闭仍是菜单直发的救命按钮。",
    ]

    /// 04 票 In 清单六项各自**背后是哪条能力** —— 覆盖面断言据此区分两件事:
    /// 「这一项没露出来是因为回归了」与「它背后的能力当前根本没注册,本就不该露出来」。
    ///
    /// 写在这里而不是散在断言里,是因为它是一条**产品承诺与实现的对账表**:哪天某项承诺被收回
    /// 或恢复,改的是这一行,而不是某个 if。
    public static let userActionCapabilities: [String: [String]] = [
        "systemProxyToggle": ["proxy.system.enable", "proxy.system.disable"],
        "modeSwitch": ["proxy.mode.set"],
        "nodeSelect": ["proxy.node.select"],
        "subscriptionManage": [
            "proxy.subscription.list", "proxy.subscription.activate",
            "proxy.subscription.update", "proxy.subscription.remove",
        ],
        "latencyTest": ["proxy.latency.test"],
        "basicStatus": ["proxy.status"],
    ]

    // ============ 三种「主要菜单状态」 ============

    /// 一个固定装置 = 稳定名(产物文件名)+ 人读标题 + 状态。
    ///
    /// 16 票加了第二份状态 `bootstrap`(面板本地的引导状态)。缺省 `.hidden` —— 没有内嵌 bin,
    /// 引导区段整块不出现,于是 10 票那四份装置连同它们的 golden **一个字节都不用动**。
    public struct Fixture: Sendable {
        public let name: String
        public let title: String
        public let state: A2PanelState
        public let bootstrap: A2BootstrapState
        public init(name: String, title: String, state: A2PanelState,
                    bootstrap: A2BootstrapState = .hidden) {
            self.name = name; self.title = title; self.state = state; self.bootstrap = bootstrap
        }
    }

    /// 快照里那份 `status`(壳只用它的 version;其余字段照契约填成合法值)。
    static let kernelStatus = A2StatusResult(
        version: "0.1.0", pid: 4242, startedAt: "2026-08-05T04:00:00.000Z", uptimeMs: 600_000,
        home: "/Users/alice/.a2", socketPath: "/Users/alice/.a2/run/kernel.sock")

    /// 确认器在场(壳自己就是它)、无在途请求。
    static let arbitrationIdle = A2ArbitrationState(
        confirmerPresent: true, confirmers: 1, subscribers: 0, timeoutMs: 120_000, pending: [])

    /// ① mihomo 未运行(壳已连上内核 —— 这两件事是**独立**的,新架构的第一课)。
    public static let mihomoDown = Fixture(
        name: "01-mihomo-down",
        title: "已连内核,mihomo 未运行",
        state: A2PanelState(
            connection: .connected,
            kernelStatus: kernelStatus,
            capabilities: capabilities,
            arbitration: arbitrationIdle,
            proxy: A2ProxyView(kernelRunning: false, systemProxySupported: true)))

    /// ② mihomo 运行中:rule 模式 + 已选节点 + 两个代理组 + 系统代理已接管。
    public static let mihomoRunning = Fixture(
        name: "02-mihomo-running",
        title: "mihomo 运行中(rule 模式 · 节点 HK-01 · 系统代理已接管)",
        state: A2PanelState(
            connection: .connected,
            kernelStatus: kernelStatus,
            capabilities: capabilities,
            arbitration: arbitrationIdle,
            proxy: A2ProxyView(
                kernelRunning: true,
                apiReachable: true,
                kernelVersion: "v1.19.28",
                mode: "rule",
                mixedPort: 7890,
                currentNode: "HK-01",
                systemProxyTakenOver: true,
                systemProxySupported: true,
                groups: [
                    A2ProxyView.Group(name: "PROXY", type: "Selector", now: "HK-01",
                                      all: ["HK-01", "JP-02", "DIRECT"]),
                    A2ProxyView.Group(name: "GLOBAL", type: "Selector", now: "PROXY",
                                      all: ["PROXY", "DIRECT"])
                ])))

    /// ③ 有激活订阅(两条订阅,激活其一)。
    public static let activeSubscription = Fixture(
        name: "03-active-subscription",
        title: "有激活订阅(激活「机场 A」)",
        state: A2PanelState(
            connection: .connected,
            kernelStatus: kernelStatus,
            capabilities: capabilities,
            arbitration: arbitrationIdle,
            proxy: A2ProxyView(
                kernelRunning: true,
                apiReachable: true,
                kernelVersion: "v1.19.28",
                mode: "global",
                mixedPort: 7890,
                currentNode: "JP-02",
                systemProxyTakenOver: false,
                systemProxySupported: true,
                groups: [
                    A2ProxyView.Group(name: "PROXY", type: "Selector", now: "JP-02",
                                      all: ["HK-01", "JP-02"])
                ],
                subscriptions: [
                    A2ProxyView.Subscription(id: "sub-jichang-a-1a2b3c", name: "机场 A"),
                    A2ProxyView.Subscription(id: "sub-jichang-b-4d5e6f", name: "机场 B")
                ],
                activeSubscriptionID: "sub-jichang-a-1a2b3c")))

    /// ④ **壳与内核断连** —— 新架构才有的一态,而且是用户最容易误读的一态
    /// (断连 ≠ 断网:数据面不随控制面起落)。菜单必须把这件事说清楚,故它进快照。
    public static let disconnected = Fixture(
        name: "04-disconnected",
        title: "与内核断连(代理照跑)",
        state: A2PanelState(
            connection: .disconnected("与内核断开,正在重连"),
            kernelStatus: kernelStatus,
            capabilities: capabilities,
            arbitration: nil,
            proxy: A2ProxyView(
                kernelRunning: true, apiReachable: true, kernelVersion: "v1.19.28",
                mode: "rule", mixedPort: 7890, currentNode: "HK-01",
                systemProxyTakenOver: true, systemProxySupported: true,
                notes: ["与内核断开,以下代理状态是断开前最后一次读到的"])))

    // ============ 引导装置(16 票 / ADR 0012:六条新分支各一张)============
    //
    // 前四种装置刻意保持 `.hidden`(= 10 票的原样),这六种才是引导区段的覆盖面。
    // 分工与上面那四种相同:**快照画的**与**断言验的**是同一批状态,物理上同一份。

    /// 「还没连上过内核」的那份状态:能力清单**是空的**,因为它只来自快照,而快照要连上才有。
    /// 这正是一个全新用户第一次打开 `.app` 时菜单真实的样子 —— 装置不许比现实好看。
    static func neverConnected(_ reason: String) -> A2PanelState {
        A2PanelState(connection: .disconnected(reason),
                     kernelStatus: nil,
                     capabilities: [],
                     arbitration: nil,
                     proxy: A2ProxyView())
    }

    /// ⑤ 断连 + 内核未安装 → 「安装并启动内核」(首启说明框背后的那一态)。
    public static let bootstrapNotInstalled = Fixture(
        name: "05-bootstrap-not-installed",
        title: "断连 · 内核未安装(有内嵌 bin → 可一键装)",
        state: neverConnected("内核未安装"),
        bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                    embeddedKernelVersion: "0.1.0",
                                    serviceState: .notInstalled))

    /// ⑥ 断连 + 已装未跑 → 标题变「启动内核」,动作仍是**同一条幂等 install**。
    public static let bootstrapInstalledNotRunning = Fixture(
        name: "06-bootstrap-installed-not-running",
        title: "断连 · 服务已装但没在跑(标题变「启动内核」,动作同一条)",
        state: neverConnected("内核未运行"),
        bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                    embeddedKernelVersion: "0.1.0",
                                    serviceState: .installedNotRunning))

    /// ⑦ 在途:项**留着但禁用** + 一条「安装中…」。
    public static let bootstrapInstalling = Fixture(
        name: "07-bootstrap-installing",
        title: "断连 · 安装在途(项禁用 + 「安装中…」)",
        state: neverConnected("内核未安装"),
        bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                    embeddedKernelVersion: "0.1.0",
                                    serviceState: .notInstalled,
                                    inFlight: .install))

    /// ⑧ 失败:如实一行,含 `error.code` 与退出码语义(这里是退出码 6 = 这个 bin 不能自装)。
    public static let bootstrapFailed = Fixture(
        name: "08-bootstrap-failed",
        title: "断连 · 上一次安装失败(退出码 6:这个 bin 不能自装)",
        state: neverConnected("内核未安装"),
        bootstrap: A2BootstrapState(
            embeddedBinAvailable: true,
            embeddedKernelVersion: "0.1.0",
            serviceState: .notInstalled,
            lastFailure: A2BootstrapFailure(
                code: "service_self_copy_unsupported",
                message: "当前这个 a2 不是可分发的单文件产物,没有「自身」可以拷进 A2_HOME。",
                exitCode: 6)))

    /// ⑨ 已连 + 版本失配 → 「升级内核 vX→vY」。线上版本取 `snapshot.status.version`。
    public static let bootstrapUpgrade = Fixture(
        name: "09-bootstrap-upgrade",
        title: "已连 · 包里的内核比线上的新(出「升级内核 v0.1.0→v0.2.0」)",
        state: mihomoDown.state,
        bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                    embeddedKernelVersion: "0.2.0",
                                    serviceState: .running))

    /// ⑩ 已连 + 版本一致 → 引导区段只剩「高级」(能装就能卸,但日常不该和它并排)。
    public static let bootstrapAdvanced = Fixture(
        name: "10-bootstrap-advanced",
        title: "已连 · 版本一致(引导区段只剩「高级 → 停止并卸载内核服务」)",
        state: mihomoDown.state,
        bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                    embeddedKernelVersion: "0.1.0",
                                    serviceState: .running))

    /// ⑪ 已连 + 上一次 purge 被拒(17 票 CR 尾款)——**失败面把内核给的指引原样摊开**。
    ///
    /// 为什么值一张图:`guidanceLines` 是"拒绝即指引"在壳上的最后一跳。前十张里没有一张带 guidance
    /// 的失败(08 那条的内核报文本来就没有 guidance),于是这条从解析到菜单的路只有单测走过、
    /// 没有任何一份 golden 画过它。这一张把它钉在两个渲染器上(文本 + 像素)。
    ///
    /// 报文逐字取自金标 `response-service-purge-blocked.json`(那是内核那条拒绝的手写镜像)。
    public static let bootstrapPurgeBlocked = Fixture(
        name: "11-bootstrap-purge-blocked",
        title: "已连 · 勾了「同时删除 ~/.a2」但系统代理还没还原(拒绝 + 指引原样呈现)",
        state: mihomoDown.state,
        bootstrap: A2BootstrapState(
            embeddedBinAvailable: true,
            embeddedKernelVersion: "0.1.0",
            serviceState: .running,
            lastFailure: A2BootstrapFailure(
                code: "service_purge_blocked",
                message: "系统代理仍由 a2 接管着,已拒绝 --purge —— 什么都没删。",
                exitCode: 1,
                guidance: A2Guidance(
                    summary: "先显式还原系统代理,再来 purge。还原是一条独立命令 —— 内核不在卸载里替你改网络设置。",
                    steps: [
                        A2GuidanceStep(description: "还原系统代理(命令行,不需要 daemon 在跑)",
                                       command: "a2 proxy off"),
                        A2GuidanceStep(description: "或在面板里点:菜单「关闭系统代理(还原)」"),
                        A2GuidanceStep(description: "还原之后再来一次",
                                       command: "a2 service uninstall --purge --json"),
                        A2GuidanceStep(description: "或者这次就只拆服务(数据与 $A2_HOME 原样留下)",
                                       command: "a2 service uninstall"),
                    ]))))

    // ============ mihomo 区段装置(08 票:安装入口 + 尚未配置节点)============
    //
    // 前十一份装置的 `mihomoFacts` 全是 nil(= 面板还没问到 / 问失败),于是 mihomo 区段只出
    // 「初始化 A2（添加到 AI 助手）」一项。这两份是**第一次**把那份事实喂进来的装置 ——
    // 08 票新增/改判的两个可点项,各由一张 golden 画着。

    /// ⑫ 已连 + mihomo 未启用 → 「安装 mihomo(复制指令给 AI 助手)」(08 票的小白入口)。
    ///
    /// 断连时**有意没有**对位装置:那一态该出的是「安装并启动内核」,而不是让人去装 mihomo
    /// (判据在构造器里,`A2BootstrapMenuTests` 有断言钉着)。
    public static let mihomoOffInstallPrompt = Fixture(
        name: "12-mihomo-off-install-prompt",
        title: "已连 · mihomo 未启用(出「安装 mihomo(复制指令给 AI 助手)」)",
        state: mihomoDown.state,
        bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                    embeddedKernelVersion: "0.1.0",
                                    serviceState: .running,
                                    mihomoFacts: A2BootstrapMihomoFacts(
                                        mode: .off, embeddedState: .stopped, hasProxies: false)))

    /// ⑬ 已连 + embedded 跑着但配置里没节点 → 状态行 + 「⚠ 尚未配置节点」(**复制的是同一段指令**)。
    public static let mihomoEmbeddedNoProxies = Fixture(
        name: "13-mihomo-embedded-noproxies",
        title: "已连 · 内置代理内核运行中但没节点(「⚠ 尚未配置节点」复制同一段指令)",
        state: mihomoRunning.state,
        bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                    embeddedKernelVersion: "0.1.0",
                                    serviceState: .running,
                                    mihomoFacts: A2BootstrapMihomoFacts(
                                        mode: .embedded, embeddedState: .running, hasProxies: false)))

    /// 快照与状态反映断言共用的全部状态(顺序即产物编号顺序)。
    public static let fixtures: [Fixture] = [
        mihomoDown, mihomoRunning, activeSubscription, disconnected,
        bootstrapNotInstalled, bootstrapInstalledNotRunning, bootstrapInstalling,
        bootstrapFailed, bootstrapUpgrade, bootstrapAdvanced, bootstrapPurgeBlocked,
        mihomoOffInstallPrompt, mihomoEmbeddedNoProxies,
    ]

    // ============ 确认器装置 ============

    /// 一条 dangerous 确认请求(换订阅源)——`input` 里那两个值就是要被**原样呈现**的东西。
    public static let confirmationRequest = A2ConfirmationRequest(
        id: "cfm-7f3a91",
        capability: "proxy.subscription.add",
        descriptor: capabilities.first { $0.id == "proxy.subscription.add" }!,
        input: ["name": .string("机场 A"),
                "source": .string("https://example.invalid/sub/a.yaml")],
        requestedAt: "2026-08-05T04:10:00.000Z",
        expiresAt: "2026-08-05T04:12:00.000Z")
}
