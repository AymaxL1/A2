// A2Contract —— **镜像范围表**:哪些契约 Swift 侧有对照物,哪些有意没有,以及为什么(09 票)。
//
// 这张表不是文档,是**门禁装置**。金标清单(`kernel/contract/golden/index.json`)里出现的每一个
// schema 名,必须落在下面两张表之一;两张表合起来必须**恰好**等于金标清单的 schema 全集。
// 于是:
//   * 08 票之后有人加了一族新报文并配了金标 → Swift 侧没跟 → 名字既不在镜像表也不在豁免表 → **当场红**;
//   * 有人给某个已镜像的契约加了新样本 → 那份样本自动进往返断言(测试按清单遍历,不写死文件名)→
//     镜像少一个字段就红;
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
    case guidance = "Guidance"
    case confirmationError = "ConfirmationError"

    // 长连接面:注册 → 快照 → 增量。
    case roleRegisterParams = "RoleRegisterParams"
    case roleRegisterResult = "RoleRegisterResult"
    case kernelSnapshot = "KernelSnapshot"
    case pushEnvelope = "PushEnvelope"

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

    // 增量事件的载荷(六族里唯一带自定义 output 的那一族)。
    case capabilityEvent = "CapabilityEvent"

    /// 解码 → 重编码。金标往返断言用它:重编码后的 JSON 必须与原样本**语义等价**
    /// (逐字段相等,不比键序)。少一个字段、多一个字段、类型漂了,都会在那一步吵起来。
    ///
    /// 非法样本走同一个入口:解不动就是**抛**,那正是断言要的结果。
    public func decodeThenReencode(_ data: Data) throws -> Data {
        switch self {
        case .requestEnvelope: return try Self.roundTrip(A2RequestEnvelope.self, data)
        case .responseEnvelope: return try Self.roundTrip(A2ResponseEnvelope.self, data)
        case .guidance: return try Self.roundTrip(A2Guidance.self, data)
        case .confirmationError: return try Self.roundTrip(A2ConfirmationError.self, data)
        case .roleRegisterParams: return try Self.roundTrip(A2RoleRegisterParams.self, data)
        case .roleRegisterResult: return try Self.roundTrip(A2RoleRegisterResult.self, data)
        case .kernelSnapshot: return try Self.roundTrip(A2KernelSnapshot.self, data)
        case .pushEnvelope: return try Self.roundTrip(A2PushEnvelope.self, data)
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
        }
    }

    private static func roundTrip<T: Codable>(_ type: T.Type, _ data: Data) throws -> Data {
        let value = try JSONDecoder().decode(type, from: data)
        return try JSONEncoder().encode(value)
    }
}

/// Swift 侧**有意没有**对照物的契约,以及理由。
///
/// 一条统一的界:**壳(10 票)消费不到的东西不镜像**。这些全是 CLI 面的 result —— agent 用
/// `a2 … --json` 读 stdout 就够了,壳要它们时走的是 `capabilities.call` 的 `output`(任意 JSON,
/// 由 `A2JSON` 承载),而不是各建一个会漂的 struct。**镜像多一个类型就是多一处要同步的地方**。
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

    /// 为什么不镜像。**每一条都要能经得起问**:理由是"壳不消费"或"CLI 自己的输出面",
    /// 不是"来不及写"。真到 10 票发现壳要投影某一条,就把它挪进 `A2MirroredContract` 并补断言。
    public var reason: String {
        switch self {
        case .versionResult, .helpResult:
            return "bin 自报的本地事实(无 op),CLI 输出面专用;壳从快照的 status 里就拿得到版本与协议号。"
        case .capabilityListResult, .capabilityDescribeResult:
            return "能力清单壳经**快照** capabilities 拿(注册那一次往返就带全量),不必再走这两条查询面。"
        case .capabilityCallResult:
            return "壳发起调用后要的是 output 本身;output 是任意 JSON,由 A2JSON 承载,不为每条能力建 struct。"
        case .arbitrationStatusResult:
            return "仲裁面壳经快照 arbitration + arbitration/audit 两族推送拿到同一批事实,这条是 CLI 的查询面。"
        case .serviceStatusResult, .serviceChangeResult:
            return "服务面问的是系统 supervisor,daemon 没跑时更要能答话 —— 那是 CLI 的活,壳不装服务。"
        case .mihomoStatusResult, .mihomoChangeResult:
            return "mihomo 共存阶梯是安装期决策(CLI 面);壳只关心「它此刻活没活着」,那走 supervision 事件。"
        case .proxyStatusResult, .proxyConfigResult, .proxyGroupsResult, .proxyModeResult,
             .proxyNodeSelectResult, .proxyLatencyResult, .subscriptionListResult,
             .subscriptionChangeResult, .systemProxyStatusResult, .systemProxyChangeResult:
            return "代理域各能力的 result:壳按需调能力、拿 output(任意 JSON)直接投影,并靠 capability 事件跟进变化。"
        }
    }
}

/// 镜像范围的对账口径(测试与 10 票共用的判据集合)。
public enum A2ContractCoverage {
    /// 已镜像的契约名。
    public static var mirrored: Set<String> { Set(A2MirroredContract.allCases.map(\.rawValue)) }

    /// 有意未镜像的契约名。
    public static var unmirrored: Set<String> { Set(A2UnmirroredContract.allCases.map(\.rawValue)) }

    /// **已镜像、但金标里一份样本都没有**的契约 —— 如实记账,不装作全覆盖。
    ///
    /// 目前只有 `RoleRegisterResult`:08 票造了它的 JSON Schema 却没造样本(它内嵌一整份快照,
    /// 手写样本几乎等于把 `kernel-snapshot.json` 再抄一遍)。Swift 侧对它的覆盖来自**活体烟测**
    /// (`Scripts/a2-smoke-09.sh` 真起内核注册一次,解得动才算过)。
    /// 哪天金标补了这份样本,对账断言会红 —— 那时把它从这里删掉即可,白捡一份静态覆盖。
    public static let mirroredWithoutGoldenSample: Set<String> = ["RoleRegisterResult"]
}
