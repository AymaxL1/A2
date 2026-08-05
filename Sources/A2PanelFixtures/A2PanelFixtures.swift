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

    /// **有意不进菜单**的 normal/dangerous 代理能力,逐条带理由。
    ///
    /// 这张表是「反向交叉核对」的唯一豁免口:真内核里每一条可发起的 `proxy.*` 能力,
    /// 要么在菜单里露出,要么在这里记一笔。**空理由不接受**。
    public static let menuExemptCapabilities: [String: String] = [
        "proxy.config.set":
            "自管配置的可调项(mixedPort / allowLan / logLevel / 默认 mode)。不在 04 票 In 清单里,"
            + "而且它改的是 mihomo 的配置文件而非「当下用哪条线路」—— 属安装/调优面,归 CLI(`a2 proxy config`)。"
            + "菜单里给一个能改监听端口的入口,只会让用户在不知道后果的时候改坏一台正在用的机器。",
    ]

    // ============ 三种「主要菜单状态」 ============

    /// 一个固定装置 = 稳定名(产物文件名)+ 人读标题 + 状态。
    public struct Fixture: Sendable {
        public let name: String
        public let title: String
        public let state: A2PanelState
        public init(name: String, title: String, state: A2PanelState) {
            self.name = name; self.title = title; self.state = state
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

    /// 快照与状态反映断言共用的四种主要状态(顺序即产物编号顺序)。
    public static let fixtures: [Fixture] = [mihomoDown, mihomoRunning, activeSubscription, disconnected]

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
