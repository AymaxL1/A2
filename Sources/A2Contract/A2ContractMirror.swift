// A2Contract —— **镜像范围表**:哪些契约 Swift 侧有对照物,哪些有意没有,以及为什么(09 票)。
//
// 这张表不是文档,是**门禁装置**。判据的「全集」取的是 **已登记契约**(`CONTRACT_SCHEMAS` 的导出物 ——
// `kernel/contract/schema/` 里每份文件的 `title`),**不是**金标清单。这个区别是 09 票 CR 抓到的盲区:
// 金标清单只列"有样本的",于是"新契约配了 schema 却还没配样本"会从四层断言底下整个溜过去。
//
// 于是现在:
//   * 有人加了一族新报文(哪怕**一份样本都没配**)→ 名字既不在镜像表也不在豁免表 → **当场红**;
//   * 有人给某个已镜像的契约加了新样本 → 那份样本自动进往返断言(测试按清单遍历,不写死文件名)→
//     镜像少一个字段就红;
//   * 已登记但没有任何样本的契约,必须显式写进 `registeredWithoutGoldenSample` 并留下理由;
//   * 有人想"绕过"这道门,只能显式把名字写进豁免表并留下理由 —— 那是一次可审阅的动作,不是静默漂移。
//
// 判据表在 `Sources/` 而不是 `Tests/`:「这个 Swift 客户端认得哪些契约」是**产品事实**(10 票的壳要照它
// 决定能投影什么),不是测试内部知识。测试只是把它与金标清单对账。

import Foundation

/// Swift 侧**有**手写 Codable 对照物的契约。rawValue 逐字取自金标清单的 `schema` 字段。
public enum A2MirroredContract: String, Sendable, CaseIterable {
    // 基础包封与拒绝即指引 —— 一切报文的地基。
    case requestEnvelope = "RequestEnvelope"
    case responseEnvelope = "ResponseEnvelope"
    case wireError = "WireError"
    case guidance = "Guidance"
    case confirmationError = "ConfirmationError"

    // 长连接面:注册 → 快照 → 增量。
    case roleRegisterParams = "RoleRegisterParams"
    case roleRegisterResult = "RoleRegisterResult"
    case kernelSnapshot = "KernelSnapshot"
    case pushEnvelope = "PushEnvelope"
    case kernelEvent = "KernelEvent"

    // 快照的组成部分(壳直接投影它们)。
    case statusResult = "StatusResult"
    case capabilityDescriptor = "CapabilityDescriptor"
    case arbitrationState = "ArbitrationState"
    case pendingConfirmation = "PendingConfirmation"
    case auditEvent = "AuditEvent"
    case proxySupervisionResult = "ProxySupervisionResult"

    // 确认往返:请求全文进来,决定回出去。
    case confirmationRequest = "ConfirmationRequest"
    case confirmationResolveParams = "ConfirmationResolveParams"
    case confirmationResolveResult = "ConfirmationResolveResult"

    // 增量事件的载荷(七族里唯一带自定义 output 的那一族)。
    case capabilityEvent = "CapabilityEvent"

    // 11 票新增的第七族:能力全集变了(装/卸插件)。**镜像它不是因为壳要展示插件**
    // (菜单只投影 `proxy.*`,有断言钉着),而是因为 `A2KernelEvent` 的未知 kind 会让**整帧解码失败**——
    // 壳不镜像它就会在用户装第一个插件的那一刻开始丢帧。
    case capabilitySetEvent = "CapabilitySetEvent"

    /// 解码 → 重编码。金标往返断言用它:重编码后的 JSON 必须与原样本**语义等价**
    /// (逐字段相等,不比键序)。少一个字段、多一个字段、类型漂了,都会在那一步吵起来。
    ///
    /// 非法样本走同一个入口:解不动就是**抛**,那正是断言要的结果。
    public func decodeThenReencode(_ data: Data) throws -> Data {
        switch self {
        case .requestEnvelope: return try Self.roundTrip(A2RequestEnvelope.self, data)
        case .responseEnvelope: return try Self.roundTrip(A2ResponseEnvelope.self, data)
        case .wireError: return try Self.roundTrip(A2WireError.self, data)
        case .guidance: return try Self.roundTrip(A2Guidance.self, data)
        case .confirmationError: return try Self.roundTrip(A2ConfirmationError.self, data)
        case .roleRegisterParams: return try Self.roundTrip(A2RoleRegisterParams.self, data)
        case .roleRegisterResult: return try Self.roundTrip(A2RoleRegisterResult.self, data)
        case .kernelSnapshot: return try Self.roundTrip(A2KernelSnapshot.self, data)
        case .pushEnvelope: return try Self.roundTrip(A2PushEnvelope.self, data)
        case .kernelEvent: return try Self.roundTrip(A2KernelEvent.self, data)
        case .statusResult: return try Self.roundTrip(A2StatusResult.self, data)
        case .capabilityDescriptor: return try Self.roundTrip(A2CapabilityDescriptor.self, data)
        case .arbitrationState: return try Self.roundTrip(A2ArbitrationState.self, data)
        case .pendingConfirmation: return try Self.roundTrip(A2PendingConfirmation.self, data)
        case .auditEvent: return try Self.roundTrip(A2AuditEvent.self, data)
        case .proxySupervisionResult: return try Self.roundTrip(A2ProxySupervisionResult.self, data)
        case .confirmationRequest: return try Self.roundTrip(A2ConfirmationRequest.self, data)
        case .confirmationResolveParams: return try Self.roundTrip(A2ConfirmationResolveParams.self, data)
        case .confirmationResolveResult: return try Self.roundTrip(A2ConfirmationResolveResult.self, data)
        case .capabilityEvent: return try Self.roundTrip(A2CapabilityEvent.self, data)
        case .capabilitySetEvent: return try Self.roundTrip(A2CapabilitySetEvent.self, data)
        }
    }

    private static func roundTrip<T: Codable>(_ type: T.Type, _ data: Data) throws -> Data {
        let value = try JSONDecoder().decode(type, from: data)
        return try JSONEncoder().encode(value)
    }
}

/// Swift 侧**有意没有**对照物的契约,以及理由。
///
/// 一条统一的界(09 票 CR 校准过措辞):**不是「壳消费不到」,而是「壳即便消费,也不为它建 typed struct」**。
/// 这些全是各能力自己的 result —— 它们经 `capabilities.call` 的 `output` 回来,而 `output` 在契约里
/// 就是任意 JSON,由 `A2JSON` 原样承载。壳完全可以从 `A2JSON` 里取字段投影到菜单上
/// (10 票的代理状态、节点列表、订阅列表就是这么用的),**只是不多建一个会独立漂移的 Swift 类型**。
///
/// 为什么这条界值得守:每多一个镜像类型,就多一处要跟 TS 同步的地方,而它换来的只是"取值时省一次
/// 可选解包"。真正需要 typed 的是**协议骨架**(包封、注册、快照、六族事件、确认往返)——那些是壳的
/// 状态机依据,错一个字段是行为错;能力 output 只是展示数据,错一个字段是显示错,而且金标对不上时
/// TS 侧那半边照样会红。
///
/// **10 票预告**:`ProxyStatusResult` / `ProxyGroupsResult` / `SubscriptionListResult` 三条是菜单模型
/// 的主要投影源,届时若发现 `A2JSON` 取值太啰嗦,把它们挪进 `A2MirroredContract` 即可 ——
/// 挪动本身会被对账断言逼着做完整(金标样本自动进往返断言)。这不属于 09 票。
public enum A2UnmirroredContract: String, Sendable, CaseIterable {
    case versionResult = "VersionResult"
    case helpResult = "HelpResult"
    case capabilityListResult = "CapabilityListResult"
    case capabilityDescribeResult = "CapabilityDescribeResult"
    case capabilityCallResult = "CapabilityCallResult"
    case arbitrationStatusResult = "ArbitrationStatusResult"
    case serviceStatusResult = "ServiceStatusResult"
    case serviceChangeResult = "ServiceChangeResult"
    case mihomoStatusResult = "MihomoStatusResult"
    case mihomoChangeResult = "MihomoChangeResult"
    case proxyStatusResult = "ProxyStatusResult"
    case proxyConfigResult = "ProxyConfigResult"
    case proxyGroupsResult = "ProxyGroupsResult"
    case proxyModeResult = "ProxyModeResult"
    case proxyNodeSelectResult = "ProxyNodeSelectResult"
    case proxyLatencyResult = "ProxyLatencyResult"
    case subscriptionListResult = "SubscriptionListResult"
    case subscriptionChangeResult = "SubscriptionChangeResult"
    case systemProxyStatusResult = "SystemProxyStatusResult"
    case systemProxyChangeResult = "SystemProxyChangeResult"

    // 11 票的插件面。前三条是**内核 ↔ 插件**那条接口(壳根本不在那条链上),
    // 后三条是 `a2 plugin …` 的 CLI 机读面。
    case pluginDescribeResult = "PluginDescribeResult"
    case pluginCallRequest = "PluginCallRequest"
    case pluginCallOutput = "PluginCallOutput"
    case pluginRecord = "PluginRecord"
    case pluginListResult = "PluginListResult"
    case pluginChangeResult = "PluginChangeResult"

    /// 13 票:`a2 about` 的机读面(GPL 义务的必有落点)。
    case aboutResult = "AboutResult"

    /// 为什么不镜像。**每一条都要能经得起问**:理由是"壳不消费"或"CLI 自己的输出面",
    /// 不是"来不及写"。真到 10 票发现壳要投影某一条,就把它挪进 `A2MirroredContract` 并补断言。
    public var reason: String {
        switch self {
        case .versionResult, .helpResult:
            return "bin 自报的本地事实(无 op),CLI 输出面专用;壳要版本与协议号从快照的 status 里就拿得到,这两条它压根不会请求。"
        case .capabilityListResult, .capabilityDescribeResult:
            return "能力清单壳经**快照** capabilities 拿(注册那一次往返就带全量,已是 typed),不必再走这两条查询面。"
        case .capabilityCallResult:
            return "壳发起调用后要的是 output 本身,而 output 在契约里就是任意 JSON —— 给它套一层 typed 包装并不能让里面的东西变 typed。"
        case .arbitrationStatusResult:
            return "仲裁面壳经快照 arbitration + arbitration/audit 两族推送拿到同一批事实(已是 typed),这条是 CLI 的查询面。"
        case .serviceStatusResult, .serviceChangeResult:
            // 15 票改口径:**壳现在真的会调这三条命令**(ADR 0012「面板自足」的执行器白名单 ——
            // 首启点「安装并启动」走的就是 `a2 service install --copy-to-home --json`)。
            // 但界没变:那是**经 CLI 机读面**拿到的一条包封,不是长连接上的协议帧 ——
            // 壳的状态机依据仍然是快照与七族事件,service 的 result 只在引导那一刻读一次
            // (取 `state` / `binPath` / `actions` 三个字段),经 A2JSON 取值即可。
            return "服务面问的是系统 supervisor,daemon 没跑时更要能答话 —— 那是 CLI 面。15 票起壳会在首启引导时调它(经嵌入 bin 的 `service install --copy-to-home --json`),但只读 state/binPath/actions 三个字段一次,经 A2JSON 取值即可,不值得为一次性引导多建两个会独立漂移的 typed 类型;真到面板票嫌取值啰嗦,挪进镜像表即可(样本已就位,挪动会被对账断言逼着做完整)。"
        case .mihomoStatusResult, .mihomoChangeResult:
            return "mihomo 共存阶梯是安装期决策(CLI 面);壳只关心「它此刻活没活着」,那走 supervision 事件(已是 typed)。"
        case .proxyStatusResult, .proxyGroupsResult, .subscriptionListResult:
            return "**壳会消费**(菜单的代理状态 / 节点列表 / 订阅列表就投影自它们),但取自 capabilities.call 的 output —— 任意 JSON,经 A2JSON 取值即可,不另建一个会独立漂移的 typed 类型。10 票若嫌取值啰嗦可挪进镜像表。"
        case .proxyConfigResult, .proxyModeResult, .proxyNodeSelectResult, .proxyLatencyResult,
             .subscriptionChangeResult, .systemProxyStatusResult, .systemProxyChangeResult:
            return "代理域的写面/测速面 result:壳发起后只看成败与随后的 capability 事件,output 里的细节不进菜单模型,更不必 typed。"
        case .pluginDescribeResult, .pluginCallRequest, .pluginCallOutput:
            return "**内核 ↔ 插件**那条接口(exec 一次一调)的报文:两端都是内核与插件子进程,壳不在这条链上,一个字节都不经手。它们登记成契约是为了让写插件的 agent 有机器可读的规格,不是为了给 Swift 客户端消费。"
        case .pluginRecord, .pluginListResult, .pluginChangeResult:
            return "`a2 plugin add|list|remove` 的 CLI 机读面。壳不装插件也不列插件 —— 它只需要知道「能调的东西变了」,那走已镜像的 `CapabilitySetEvent`(快照 capabilities 同一形状)。"
        case .aboutResult:
            return "`a2 about` 的 CLI 机读面,**不经协议**(无 op、不走 UDS —— 义务落点不许依赖 daemon 在不在)。壳侧的对位物是 `A2AboutWindow.declaration` 那份静态文本:它有意**不**向内核请求任何东西(关掉内核、没装内核,关于页照样打得开),所以壳这边没有可解的报文,镜像它只会多一处会漂的类型。"
        }
    }
}

/// 镜像范围的对账口径(测试与 10 票共用的判据集合)。
public enum A2ContractCoverage {
    /// 已镜像的契约名。
    public static var mirrored: Set<String> { Set(A2MirroredContract.allCases.map(\.rawValue)) }

    /// 有意未镜像的契约名。
    public static var unmirrored: Set<String> { Set(A2UnmirroredContract.allCases.map(\.rawValue)) }

    /// **已登记(有 JSON Schema)、但金标里一份独立样本都没有**的契约 —— 连同理由。
    ///
    /// 这是 09 票 CR 补上的那道账:判据的全集取「已登记契约」而不是「金标清单」之后,
    /// 「有 schema 没样本」不再是盲区,而是**必须显式记在这里**的一条账。**空表最好**;
    /// 每一条都要能经得起问,而不是"来不及写"的托词。
    ///
    /// (`RoleRegisterResult` 原本在这张表里,理由是"08 票只造了 schema 没造样本"——
    /// CR 判定那不是好理由:它正是壳注册那一刻收到的东西。样本已于本次补齐,这条账随之销掉。)
    public static let registeredWithoutGoldenSample: [String: String] = [
        "WireError":
            "嵌套类型:它只作为失败包封的 error 字段出现,由 12 份 ResponseEnvelope 合法样本 + 2 份非法样本传递覆盖(其中 invalid-response-error-missing-message 正是冲它去的)。单造一份等于把同一批字节再抄一遍。",
        "KernelEvent":
            "嵌套类型:它只作为推送帧的 event 字段出现,由 6 份 PushEnvelope 样本(六族各一)+ 1 份未知 kind 的非法样本传递覆盖。",
    ]
}
