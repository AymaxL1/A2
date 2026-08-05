// A2Panel —— 壳的**状态**:内核事件流的投影结果(10 票)。
//
// ============================================================================
// 喂养源换了(14 票 → 10 票),这是本票的核心改动
// ============================================================================
// 14 票的菜单状态取自**宿主进程内**的注册表与三个 Port —— 壳与业务逻辑同进程。
// 本票起壳是**对等客户端**:状态只有两个来源,一个都不许多:
//   ① `roles.register` 那一次往返带回的**全量快照**(`A2KernelSnapshot`)—— 基线;
//   ② 之后内核推来的**增量事件**(六族)—— 叠加。
// 壳自己**不查**任何本机事实(不读文件、不探端口、不问 supervisor)。
//
// ⚠️ **代理域是个例外,而且这条例外是契约写明的**:实时 mode/节点/组/订阅不在快照里
//    (`A2KernelSnapshot` 头注:「那要问 external-controller」),壳按需调三条 **safe 只读能力**
//    (`proxy.status` / `proxy.groups.list` / `proxy.subscription.list`)取一次,
//    此后靠 `capability` 事件**触发重取**。这仍然是零轮询 —— 没有任何定时器,
//    读只发生在「内核说有人改了状态」的那一刻。
//
// ⚠️ **为什么是「事件触发重取」而不是「拿事件载荷直接改本地状态」**(这条是红线的具体落实):
//    `capability` 事件带的是那条能力自己的 output(如 `SubscriptionChangeResult{id, action, …}`)。
//    要把它叠进本地清单,壳就得知道「`replaced` 该覆盖哪一条、`removed` 该删哪一条、
//    激活项该怎么跟着变」—— 那是**订阅域的业务语义**,内核里已经有一份权威实现。
//    壳再抄一份,就是 ADR 0008 第 5 条明禁的「壳含业务逻辑」,而且必然与内核漂移。
//    所以壳只做一件事:**知道该重读哪一族,然后重读**。语义永远只有内核一份。

import A2Contract

// ============================================================================
// 代理域视图(14 票 `AAProxyUIState` 的对位物,喂养源换成能力 output)
// ============================================================================

/// 菜单要呈现的「代理域当前状态」(纯数据)。
///
/// 字段与三条 **safe 只读能力** 的 output 一一对应,不多不少:
///   * `proxy.status`            → running / apiReachable / version / mode / mixedPort / node / systemProxy
///   * `proxy.groups.list`       → groups
///   * `proxy.subscription.list` → subscriptions / active
///
/// 取值经 `A2JSON`,**不为这三条 result 建 typed struct** —— 那是 09 票立的界
/// (`A2UnmirroredContract` 的理由原文:「壳会消费,但不另建一个会独立漂移的 typed 类型」)。
/// 本票据此执行,并把那条「10 票预告」结账为**维持豁免**。
public struct A2ProxyView: Sendable, Equatable {
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
    /// 系统代理**此刻是不是被 a2 接管着**。
    ///
    /// 14 票在这里记过一条「已知缺口」:旧架构没有任何只读能力面暴露接管态,菜单因此不显示勾选。
    /// 新架构把它写进了契约(`ProxyStatusResult.systemProxy.takenOver`,07 票新增
    /// `proxy.system.status` 能力),**缺口就此填上** —— 菜单可以如实显示勾选态了。
    public var systemProxyTakenOver: Bool
    /// 本平台有没有已支持的接管路径(`systemProxy.supported`)。
    public var systemProxySupported: Bool
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
                systemProxyTakenOver: Bool = false,
                systemProxySupported: Bool = false,
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
        self.systemProxyTakenOver = systemProxyTakenOver
        self.systemProxySupported = systemProxySupported
        self.groups = groups
        self.subscriptions = subscriptions
        self.activeSubscriptionID = activeSubscriptionID
        self.notes = notes
    }

    /// 从三条 safe 能力的 output 组装(纯函数,可单测)。
    ///
    /// 任一输入为 nil / 形状不对 → 该维度按「取不到」处理并往 `notes` 记一条,**绝不臆造默认值**
    /// (例如 groups 取不到就是空数组 + 一条说明,而不是假装「有一个叫 PROXY 的组」)。
    public static func from(status: A2JSON?,
                            groups: A2JSON?,
                            subscriptions: A2JSON?,
                            extraNotes: [String] = []) -> A2ProxyView {
        var view = A2ProxyView()
        view.notes = extraNotes

        if let obj = status?.objectValue {
            view.kernelRunning = boolOf(obj["running"]) ?? false
            view.apiReachable = boolOf(obj["apiReachable"]) ?? false
            view.kernelVersion = obj["version"]?.stringValue
            view.mode = obj["mode"]?.stringValue
            view.mixedPort = intOf(obj["mixedPort"])
            view.currentNode = obj["node"]?.stringValue
            if let sp = obj["systemProxy"]?.objectValue {
                view.systemProxyTakenOver = boolOf(sp["takenOver"]) ?? false
                view.systemProxySupported = boolOf(sp["supported"]) ?? false
            } else {
                view.notes.append("系统代理接管态读取失败(proxy.status 缺 systemProxy)")
            }
        } else {
            view.notes.append("内核状态读取失败(proxy.status 不可用)")
        }

        if let arr = arrayOf(groups?.objectValue?["groups"]) {
            view.groups = arr.compactMap { entry in
                guard let g = entry.objectValue, let name = g["name"]?.stringValue else { return nil }
                return Group(name: name,
                             type: g["type"]?.stringValue ?? "",
                             now: g["now"]?.stringValue,
                             all: (arrayOf(g["all"]) ?? []).compactMap { $0.stringValue })
            }
        } else if groups != nil {
            view.notes.append("代理组读取失败(proxy.groups.list 输出形状不符)")
        }

        if let obj = subscriptions?.objectValue {
            // 契约是 `active: z.string().nullable()` —— **null 是合法取值**(没有激活项),
            //   与「键不在」是两件事;`stringValue` 对 `.null` 返回 nil,两者在这里恰好同归,如实。
            view.activeSubscriptionID = obj["active"]?.stringValue
            view.subscriptions = (arrayOf(obj["subscriptions"]) ?? []).compactMap { entry in
                guard let s = entry.objectValue,
                      let id = s["id"]?.stringValue,
                      let name = s["name"]?.stringValue else { return nil }
                return Subscription(id: id, name: name)
            }
        } else if subscriptions != nil {
            view.notes.append("订阅清单读取失败(proxy.subscription.list 输出形状不符)")
        }

        return view
    }

    private static func boolOf(_ v: A2JSON?) -> Bool? {
        if case .bool(let b)? = v { return b }
        return nil
    }
    private static func intOf(_ v: A2JSON?) -> Int? {
        if case .int(let n)? = v { return n }
        if case .double(let n)? = v, n.isFinite { return Int(n) }
        return nil
    }
    private static func arrayOf(_ v: A2JSON?) -> [A2JSON]? {
        if case .array(let a)? = v { return a }
        return nil
    }
}

// ============================================================================
// 壳的整体状态
// ============================================================================

/// 壳与内核的连接态。**在场 = 长连接**(ADR 0005 修订版):断了就是不在场,没有中间态。
public enum A2PanelConnection: Sendable, Equatable {
    /// 还没连上(或已断开),带一句人读原因。
    case disconnected(String)
    /// 连上且已注册角色。
    case connected
}

/// 壳的全部状态。菜单模型是它的**纯函数**(`A2MenuModelBuilder.build`)。
public struct A2PanelState: Sendable, Equatable {
    public var connection: A2PanelConnection
    /// 内核自报的运行事实(快照第一块)。断连时保留最后一次,并由 `connection` 说明它已过时。
    public var kernelStatus: A2StatusResult?
    /// 能力全集 —— **只来自快照**。壳绝不自带一份会漂的能力名单。
    public var capabilities: [A2CapabilityDescriptor]
    /// 仲裁面(有没有确认器在场、在途几条)。壳自己就是那个确认器,这里能看到内核**是否已认到它**。
    public var arbitration: A2ArbitrationState?
    /// mihomo 存活观测。
    public var supervision: A2ProxySupervisionResult?
    /// 代理域视图(三条 safe 能力的投影)。
    public var proxy: A2ProxyView
    /// 待人拍板的确认请求(**带 input,必须原样呈现**)。按到达顺序。
    public var pendingConfirmations: [A2ConfirmationRequest]
    /// 最近若干条审计事件(快照给基线,`audit` 事件叠加)。
    public var audit: [A2AuditEvent]

    public init(connection: A2PanelConnection = .disconnected("未连接"),
                kernelStatus: A2StatusResult? = nil,
                capabilities: [A2CapabilityDescriptor] = [],
                arbitration: A2ArbitrationState? = nil,
                supervision: A2ProxySupervisionResult? = nil,
                proxy: A2ProxyView = A2ProxyView(),
                pendingConfirmations: [A2ConfirmationRequest] = [],
                audit: [A2AuditEvent] = []) {
        self.connection = connection
        self.kernelStatus = kernelStatus
        self.capabilities = capabilities
        self.arbitration = arbitration
        self.supervision = supervision
        self.proxy = proxy
        self.pendingConfirmations = pendingConfirmations
        self.audit = audit
    }

    /// 审计事件保留条数(与内核快照给的条数同量级;壳不做日志,只做「最近发生了什么」的呈现)。
    public static let auditWindow = 20
}
