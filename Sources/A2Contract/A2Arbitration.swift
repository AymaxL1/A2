// A2Contract —— 角色注册、三层仲裁与审计(对照 `wire.ts` 的「角色注册、订阅推送与三层仲裁」一节)。
//
// 这一节是安全模型的落点,壳(10 票)全部工作都发生在这里:
//   * 注册 confirm-agent / subscriber —— **在场 = 长连接**,断线即离场;
//   * 收 `ConfirmationRequest`(带 `input`,必须原样展示 —— 防「agent 替用户点确认」的社工话术);
//   * 回 `confirmations.resolve{decision}` —— **确认器明说 approve 是放行的唯一一条路**。
//
// **V1 不验签,这是已知边界,如实记在镜像里**:`identity` 的 `codeDirectoryHash` / `teamIdentifier`
// 是身份强化的插槽,内核收下不校验 —— 壳填了不会更可信,不填也不会被拒。唯一被验证过的身份事实
// 是对端 UID(`RoleRegisterResult.uid`)。

import Foundation

/// 长连接上可注册的角色(对照 `ClientRoleSchema`)。一条连接可多者兼有;重复注册幂等。
public enum A2ClientRole: String, Sendable, Codable, Equatable, CaseIterable {
    /// 确认器:替人类出面呈现 dangerous 确认并安全回传决定。
    case confirmAgent = "confirm-agent"
    /// 订阅者:只收状态投影,不参与仲裁。
    case subscriber
    /// **机械执行器**(url-router 施工 04 票):收内核下发的执行指令帧、调系统 API、原样回传结果。
    ///
    /// 它与确认器是**两把分开的锁**:确认器能替人做决定,执行器只能回报自己执行的结果 ——
    /// 它没有任何批准 dangerous 调用的能力。壳两个都注册,但那是两件事。
    case urlRouterExecutor = "url-router-executor"
}

/// 注册时客户端自报的身份(对照 `ClientIdentitySchema`)。**V1 全部字段只用于展示与审计**。
public struct A2ClientIdentity: Sendable, Equatable {
    /// 自报的名字(如 `a2-panel`)。**不构成身份**。
    public let name: String
    public let version: String?
    /// 预留:代码签名摘要(cdhash)。**V1 内核收下不校验**。
    public let codeDirectoryHash: String?
    /// 预留:团队标识。**V1 内核收下不校验**。
    public let teamIdentifier: String?

    public init(
        name: String, version: String? = nil, codeDirectoryHash: String? = nil,
        teamIdentifier: String? = nil
    ) {
        self.name = name
        self.version = version
        self.codeDirectoryHash = codeDirectoryHash
        self.teamIdentifier = teamIdentifier
    }
}

extension A2ClientIdentity: Codable {
    private enum CodingKeys: String, CodingKey { case name, version, codeDirectoryHash, teamIdentifier }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeNonEmptyString(forKey: .name)
        version = try container.decodeNonEmptyStringIfPresent(forKey: .version)
        codeDirectoryHash = try container.decodeNonEmptyStringIfPresent(forKey: .codeDirectoryHash)
        teamIdentifier = try container.decodeNonEmptyStringIfPresent(forKey: .teamIdentifier)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(codeDirectoryHash, forKey: .codeDirectoryHash)
        try container.encodeIfPresent(teamIdentifier, forKey: .teamIdentifier)
    }
}

/// `roles.register` 的 params(对照 `RoleRegisterParamsSchema`)。**这是要写出去的那一类**。
public struct A2RoleRegisterParams: Sendable, Equatable {
    public let role: A2ClientRole
    public let identity: A2ClientIdentity

    public init(role: A2ClientRole, identity: A2ClientIdentity) {
        self.role = role
        self.identity = identity
    }
}

extension A2RoleRegisterParams: Codable {
    private enum CodingKeys: String, CodingKey { case role, identity }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(A2ClientRole.self, forKey: .role)
        identity = try container.decode(A2ClientIdentity.self, forKey: .identity)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(identity, forKey: .identity)
    }
}

/// 确认器能给的两种决定(对照 `ConfirmationDecisionSchema`)。**没有第三种** ——
/// 「不理」不是决定,那是超时(内核自己裁,超时即拒)。
public enum A2ConfirmationDecision: String, Sendable, Codable, Equatable, CaseIterable {
    case approve
    case deny
}

/// `confirmations.resolve` 的 params(对照 `ConfirmationResolveParamsSchema`)。**要写出去的那一类**。
public struct A2ConfirmationResolveParams: Sendable, Equatable {
    /// 要决定的那条确认请求的 id(来自推给确认器的 `confirmation` 事件)。
    public let confirmation: String
    public let decision: A2ConfirmationDecision
    /// 人类给的理由(可选,进审计日志)。
    public let reason: String?

    public init(confirmation: String, decision: A2ConfirmationDecision, reason: String? = nil) {
        self.confirmation = confirmation
        self.decision = decision
        self.reason = reason
    }
}

extension A2ConfirmationResolveParams: Codable {
    private enum CodingKeys: String, CodingKey { case confirmation, decision, reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmation = try container.decodeNonEmptyString(forKey: .confirmation)
        decision = try container.decode(A2ConfirmationDecision.self, forKey: .decision)
        reason = try container.decodeNonEmptyStringIfPresent(forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(confirmation, forKey: .confirmation)
        try container.encode(decision, forKey: .decision)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

/// `confirmations.resolve` 的 result(对照 `ConfirmationResolveResultSchema`)。
/// `settled` 恒 true —— 决定没被采纳的情形一律走失败包封。
public struct A2ConfirmationResolveResult: Sendable, Equatable {
    public let confirmation: String
    public let decision: A2ConfirmationDecision
    public let settled: Bool

    public init(confirmation: String, decision: A2ConfirmationDecision) {
        self.confirmation = confirmation
        self.decision = decision
        self.settled = true
    }
}

extension A2ConfirmationResolveResult: Codable {
    private enum CodingKeys: String, CodingKey { case confirmation, decision, settled }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmation = try container.decodeNonEmptyString(forKey: .confirmation)
        decision = try container.decode(A2ConfirmationDecision.self, forKey: .decision)
        try container.decodeLiteralBool(true, forKey: .settled)
        settled = true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(confirmation, forKey: .confirmation)
        try container.encode(decision, forKey: .decision)
        try container.encode(settled, forKey: .settled)
    }
}

/// 一条在途的待确认请求(对照 `PendingConfirmationSchema`)—— **只有坐标,没有 input**。
///
/// 这不是省字段,是边界:快照与 `arbitration` 事件发给**所有**订阅者,而 `input` 是人类要亲眼核对的东西,
/// 它只出现在推给 confirm-agent 的 `A2ConfirmationRequest` 里。
public struct A2PendingConfirmation: Sendable, Equatable {
    public let id: String
    public let capability: String
    /// 恒为 `dangerous`(只有这一档会进仲裁)。
    public let risk: A2RiskLevel
    public let requestedAt: String
    /// 超过这个时刻还没人决定就算超时(内核算好的绝对时刻,客户端不必再加)。
    public let expiresAt: String

    public init(id: String, capability: String, risk: A2RiskLevel, requestedAt: String, expiresAt: String) {
        self.id = id
        self.capability = capability
        self.risk = risk
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

extension A2PendingConfirmation: Codable {
    private enum CodingKeys: String, CodingKey { case id, capability, risk, requestedAt, expiresAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeNonEmptyString(forKey: .id)
        capability = try container.decodeNonEmptyString(forKey: .capability)
        risk = try container.decode(A2RiskLevel.self, forKey: .risk)
        requestedAt = try container.decodeNonEmptyString(forKey: .requestedAt)
        expiresAt = try container.decodeNonEmptyString(forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(capability, forKey: .capability)
        try container.encode(risk, forKey: .risk)
        try container.encode(requestedAt, forKey: .requestedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
    }
}

/// 仲裁面此刻的状态(对照 `ArbitrationStateSchema`)。快照里有一份,变化时整份推一次。
public struct A2ArbitrationState: Sendable, Equatable {
    /// 有没有确认器在场 —— **这就是 dangerous 能不能走通的那条运行时事实**。
    public let confirmerPresent: Bool
    public let confirmers: Int
    public let subscribers: Int
    /// 确认超时窗口(毫秒)。
    public let timeoutMs: Int
    public let pending: [A2PendingConfirmation]

    public init(
        confirmerPresent: Bool, confirmers: Int, subscribers: Int, timeoutMs: Int,
        pending: [A2PendingConfirmation]
    ) {
        self.confirmerPresent = confirmerPresent
        self.confirmers = confirmers
        self.subscribers = subscribers
        self.timeoutMs = timeoutMs
        self.pending = pending
    }
}

extension A2ArbitrationState: Codable {
    private enum CodingKeys: String, CodingKey {
        case confirmerPresent, confirmers, subscribers, timeoutMs, pending
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmerPresent = try container.decode(Bool.self, forKey: .confirmerPresent)
        confirmers = try container.decodeNonNegativeInt(forKey: .confirmers)
        subscribers = try container.decodeNonNegativeInt(forKey: .subscribers)
        timeoutMs = try container.decodePositiveInt(forKey: .timeoutMs)
        pending = try container.decode([A2PendingConfirmation].self, forKey: .pending)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(confirmerPresent, forKey: .confirmerPresent)
        try container.encode(confirmers, forKey: .confirmers)
        try container.encode(subscribers, forKey: .subscribers)
        try container.encode(timeoutMs, forKey: .timeoutMs)
        try container.encode(pending, forKey: .pending)
    }
}

/// 推给**确认器**的待确认请求全文(对照 `ConfirmationRequestSchema`)。
///
/// `descriptor` 与 `input` 都在:确认器必须能原样展示"这是哪条能力、这次到底要干什么"。
/// **`input` 必须原样呈现** —— 那是防社工话术的关键(壳的红线,见 10 票交接单第 ② 条)。
public struct A2ConfirmationRequest: Sendable, Equatable {
    public let id: String
    public let capability: String
    /// 完整 manifest —— 确认器不该自己存一份会漂的副本。
    public let descriptor: A2CapabilityDescriptor
    /// 本次调用的**真实入参**。
    public let input: [String: A2JSON]
    public let requestedAt: String
    public let expiresAt: String

    public init(
        id: String, capability: String, descriptor: A2CapabilityDescriptor,
        input: [String: A2JSON], requestedAt: String, expiresAt: String
    ) {
        self.id = id
        self.capability = capability
        self.descriptor = descriptor
        self.input = input
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

extension A2ConfirmationRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, capability, descriptor, input, requestedAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeNonEmptyString(forKey: .id)
        capability = try container.decodeNonEmptyString(forKey: .capability)
        descriptor = try container.decode(A2CapabilityDescriptor.self, forKey: .descriptor)
        // 空对象是合法入参(`demo.wipe` 不带参数也要能触发仲裁),但**键必须在**。
        input = try container.decode([String: A2JSON].self, forKey: .input)
        requestedAt = try container.decodeNonEmptyString(forKey: .requestedAt)
        expiresAt = try container.decodeNonEmptyString(forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(capability, forKey: .capability)
        try container.encode(descriptor, forKey: .descriptor)
        try container.encode(input, forKey: .input)
        try container.encode(requestedAt, forKey: .requestedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
    }
}

/// 审计动作(对照 `AuditActionSchema`,**词表封闭**:未知取值必须解码失败,有 invalid 金标守着)。
public enum A2AuditAction: String, Sendable, Codable, Equatable, CaseIterable {
    /// dangerous 调用进了仲裁(此刻还不知道会怎么收场)。
    case requested
    /// 确认器批准 —— 只有这一条之后 handler 才会被执行。
    case approved
    /// 确认器明确拒绝。
    case denied
    /// 等确认超时(fail-closed)。
    case timedOut = "timed_out"
    /// 无确认器在场,直接默拒(第①层)。
    case unavailable
    /// **在途时确认器全部断线** → 立即降回默拒。
    case downgraded
    /// **发起那次调用的连接断开了** → 在途确认取消(没人在等这个答案了)。
    case cancelled
    case confirmerJoined = "confirmer_joined"
    case confirmerLeft = "confirmer_left"
    case subscriberJoined = "subscriber_joined"
    case subscriberLeft = "subscriber_left"
    /// 机械执行器进/离场(04 票)。「执行器什么时候在」正是接管能不能走通的那条运行时事实。
    case executorJoined = "executor_joined"
    case executorLeft = "executor_left"
    /// 对端 UID 与内核不符,连接被拒。
    case peerRejected = "peer_rejected"
    /// 对端凭据**问不出来**,连接照常放行(fail-open)。正常机器上一次都不该出现。
    case peerUnverified = "peer_unverified"
    /// 推送积压超限,该连接被判定为**慢消费者**并断连(它重连会拿到新的全量快照)。
    case backpressureDropped = "backpressure_dropped"
    /// **装了一个插件**(11 票)。装载零闸(ADR 0011),所以这条留痕是那条路上唯一的可审计物。
    case pluginAdded = "plugin_added"
    /// 卸了一个插件:它的能力当场从注册表消失。
    case pluginRemoved = "plugin_removed"
}

/// 审计事件里的客户端事实(对照 `AuditClientSchema`)。
/// `uid` 是**唯一被验证过的**那一个,`name` 只是自称。
public struct A2AuditClient: Sendable, Equatable {
    public let role: A2ClientRole?
    public let name: String?
    public let uid: Int?

    public init(role: A2ClientRole? = nil, name: String? = nil, uid: Int? = nil) {
        self.role = role
        self.name = name
        self.uid = uid
    }
}

extension A2AuditClient: Codable {
    private enum CodingKeys: String, CodingKey { case role, name, uid }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(A2ClientRole.self, forKey: .role)
        name = try container.decodeNonEmptyStringIfPresent(forKey: .name)
        uid = try container.decodeNonNegativeIntIfPresent(forKey: .uid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(uid, forKey: .uid)
    }
}

/// 一条审计事件(对照 `AuditEventSchema`)。NDJSON 落 `<A2_HOME>/log/arbitration.log`,同时推给订阅者与确认器。
public struct A2AuditEvent: Sendable, Equatable {
    public let at: String
    public let action: A2AuditAction
    public let capability: String?
    /// 确认请求 id(第①层默拒也有一个,好让"请求—收场"能配对)。
    public let confirmation: String?
    public let client: A2AuditClient?
    public let detail: String?

    public init(
        at: String, action: A2AuditAction, capability: String? = nil, confirmation: String? = nil,
        client: A2AuditClient? = nil, detail: String? = nil
    ) {
        self.at = at
        self.action = action
        self.capability = capability
        self.confirmation = confirmation
        self.client = client
        self.detail = detail
    }
}

extension A2AuditEvent: Codable {
    private enum CodingKeys: String, CodingKey { case at, action, capability, confirmation, client, detail }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decodeNonEmptyString(forKey: .at)
        action = try container.decode(A2AuditAction.self, forKey: .action)
        // 这三个在契约里都是**纯 `z.string().optional()`**(没有 min(1)),照抄,不收严。
        capability = try container.decodeIfPresent(String.self, forKey: .capability)
        confirmation = try container.decodeIfPresent(String.self, forKey: .confirmation)
        client = try container.decodeIfPresent(A2AuditClient.self, forKey: .client)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(at, forKey: .at)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(capability, forKey: .capability)
        try container.encodeIfPresent(confirmation, forKey: .confirmation)
        try container.encodeIfPresent(client, forKey: .client)
        try container.encodeIfPresent(detail, forKey: .detail)
    }
}
