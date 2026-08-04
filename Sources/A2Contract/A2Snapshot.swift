// A2Contract —— 快照、增量推送、服务端帧(对照 `wire.ts` 的 `KernelSnapshotSchema` /
// `KernelEventSchema` / `PushEnvelopeSchema` / `ServerFrameSchema` / `RoleRegisterResultSchema`)。
//
// **注册往返是原子的**:`roles.register` 的响应里就带着全量快照 —— 没有"注册成功但还没拿到状态"的中间态,
// 注册那条连接也不会收到由它自己入场触发的事件。快照即基线,此后全是增量。
//
// **帧判别是结构性的**:响应有 `ok`,推送有 `push`,**永不同现**。别用"有没有 error"去判(那是 04 票
// 之前的老习惯,现在会把成功响应与推送混作一谈)。

import Foundation

/// 注册那一刻回给客户端的**全量快照**(对照 `KernelSnapshotSchema`)。
///
/// 为什么快照就是这五样:客户端要投影的东西全在内核的**进程内状态**里,取它们不发一次网络请求 ——
/// 快照必须廉价且瞬时一致,否则"注册即快照"会变成一次慢启动。
/// (代理的实时模式/节点不在此列:那要问 external-controller。壳按需调 `proxy.status` 能力,
/// 此后靠 `capability` 事件跟进变化 —— 仍然零轮询。)
public struct A2KernelSnapshot: Sendable, Equatable {
    public let status: A2StatusResult
    /// 能力全集。
    public let capabilities: [A2CapabilityDescriptor]
    public let arbitration: A2ArbitrationState
    /// 存活监督的当下观测 + 最近事件。
    public let supervision: A2ProxySupervisionResult
    /// 最近若干条审计事件(全量在 `arbitration.log` 里)。
    public let audit: [A2AuditEvent]

    public init(
        status: A2StatusResult, capabilities: [A2CapabilityDescriptor],
        arbitration: A2ArbitrationState, supervision: A2ProxySupervisionResult, audit: [A2AuditEvent]
    ) {
        self.status = status
        self.capabilities = capabilities
        self.arbitration = arbitration
        self.supervision = supervision
        self.audit = audit
    }
}

extension A2KernelSnapshot: Codable {
    private enum CodingKeys: String, CodingKey { case status, capabilities, arbitration, supervision, audit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(A2StatusResult.self, forKey: .status)
        capabilities = try container.decode([A2CapabilityDescriptor].self, forKey: .capabilities)
        arbitration = try container.decode(A2ArbitrationState.self, forKey: .arbitration)
        supervision = try container.decode(A2ProxySupervisionResult.self, forKey: .supervision)
        audit = try container.decode([A2AuditEvent].self, forKey: .audit)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(arbitration, forKey: .arbitration)
        try container.encode(supervision, forKey: .supervision)
        try container.encode(audit, forKey: .audit)
    }
}

/// `roles.register` 的 result(对照 `RoleRegisterResultSchema`):确认注册了什么 + 全量快照。
public struct A2RoleRegisterResult: Sendable, Equatable {
    public let role: A2ClientRole
    /// 这条连接在本内核里的 id(进审计,便于把日志与连接对上)。
    public let connection: String
    /// 内核校验到的对端 uid。**缺省 = 这台机器上取不到 peer credential**(FFI 不可用等)——
    /// 此时连接照常可用,把关的是 `run/` 0700 与 socket 0600 那两道 OS 强制的门。
    public let uid: Int?
    /// 本次注册后已持有的全部角色(重复注册幂等)。
    public let roles: [A2ClientRole]
    public let snapshot: A2KernelSnapshot

    public init(
        role: A2ClientRole, connection: String, uid: Int? = nil, roles: [A2ClientRole],
        snapshot: A2KernelSnapshot
    ) {
        self.role = role
        self.connection = connection
        self.uid = uid
        self.roles = roles
        self.snapshot = snapshot
    }
}

extension A2RoleRegisterResult: Codable {
    private enum CodingKeys: String, CodingKey { case role, connection, uid, roles, snapshot }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(A2ClientRole.self, forKey: .role)
        connection = try container.decodeNonEmptyString(forKey: .connection)
        uid = try container.decodeNonNegativeIntIfPresent(forKey: .uid)
        roles = try container.decode([A2ClientRole].self, forKey: .roles)
        snapshot = try container.decode(A2KernelSnapshot.self, forKey: .snapshot)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(connection, forKey: .connection)
        try container.encodeIfPresent(uid, forKey: .uid)
        try container.encode(roles, forKey: .roles)
        try container.encode(snapshot, forKey: .snapshot)
    }
}

/// 增量事件的六族判别值(对照 `KernelEventSchema` 的 `kind`)。
public enum A2KernelEventKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// 仲裁面变了(整份 state,推给全体)。
    case arbitration
    /// 有 dangerous 请求要人拍板 —— **只推给 confirm-agent**(带 input)。
    case confirmation
    /// 「我转给人了,最多等这么久」—— **只推给发起那次调用的那条连接**。
    case confirmationPending = "confirmation-pending"
    /// 审计留痕(推给全体)。
    case audit
    /// mihomo 存活观测(推给全体)。
    case supervision
    /// 有人改了状态,带能力自己的 output(推给全体)。
    case capability
}

/// 增量推送的事件族(对照 `KernelEventSchema`,按 `kind` 判别的联合)。
///
/// **推送对象各不相同,这是协议的一部分**:`confirmation` 只给确认器,`confirmation-pending` 只给发起方,
/// 其余给全体已注册连接。
public enum A2KernelEvent: Sendable, Equatable {
    case arbitration(at: String, state: A2ArbitrationState)
    case confirmation(at: String, request: A2ConfirmationRequest)
    case confirmationPending(at: String, requestId: String, timeoutMs: Int, confirmation: A2PendingConfirmation)
    case audit(at: String, audit: A2AuditEvent)
    case supervision(at: String, supervision: A2ProxySupervisionEvent)
    case capability(at: String, capability: A2CapabilityEvent)

    public var kind: A2KernelEventKind {
        switch self {
        case .arbitration: return .arbitration
        case .confirmation: return .confirmation
        case .confirmationPending: return .confirmationPending
        case .audit: return .audit
        case .supervision: return .supervision
        case .capability: return .capability
        }
    }

    /// 事件发生时刻(六族都有)。
    public var at: String {
        switch self {
        case let .arbitration(at, _): return at
        case let .confirmation(at, _): return at
        case let .confirmationPending(at, _, _, _): return at
        case let .audit(at, _): return at
        case let .supervision(at, _): return at
        case let .capability(at, _): return at
        }
    }
}

extension A2KernelEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, at, state, request, requestId, timeoutMs, confirmation, audit, supervision, capability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 未知 kind **必须**解码失败(有 invalid 金标 `invalid-push-envelope-unknown-event.json` 守着):
        // 壳收到不认识的事件族时宁可吵起来,也不能装作收到了一件它其实没看懂的事。
        let kind = try container.decode(A2KernelEventKind.self, forKey: .kind)
        let at = try container.decodeNonEmptyString(forKey: .at)
        switch kind {
        case .arbitration:
            self = .arbitration(at: at, state: try container.decode(A2ArbitrationState.self, forKey: .state))
        case .confirmation:
            self = .confirmation(
                at: at, request: try container.decode(A2ConfirmationRequest.self, forKey: .request))
        case .confirmationPending:
            self = .confirmationPending(
                at: at,
                requestId: try container.decodeNonEmptyString(forKey: .requestId),
                timeoutMs: try container.decodePositiveInt(forKey: .timeoutMs),
                confirmation: try container.decode(A2PendingConfirmation.self, forKey: .confirmation))
        case .audit:
            self = .audit(at: at, audit: try container.decode(A2AuditEvent.self, forKey: .audit))
        case .supervision:
            self = .supervision(
                at: at, supervision: try container.decode(A2ProxySupervisionEvent.self, forKey: .supervision))
        case .capability:
            self = .capability(
                at: at, capability: try container.decode(A2CapabilityEvent.self, forKey: .capability))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(at, forKey: .at)
        switch self {
        case let .arbitration(_, state):
            try container.encode(state, forKey: .state)
        case let .confirmation(_, request):
            try container.encode(request, forKey: .request)
        case let .confirmationPending(_, requestId, timeoutMs, confirmation):
            try container.encode(requestId, forKey: .requestId)
            try container.encode(timeoutMs, forKey: .timeoutMs)
            try container.encode(confirmation, forKey: .confirmation)
        case let .audit(_, audit):
            try container.encode(audit, forKey: .audit)
        case let .supervision(_, supervision):
            try container.encode(supervision, forKey: .supervision)
        case let .capability(_, capability):
            try container.encode(capability, forKey: .capability)
        }
    }
}

/// 推送帧(对照 `PushEnvelopeSchema`)。
///
/// `id` 是这条推送**自己的** id(不对应任何请求)。唯一的例外语义在 `confirmation-pending` 事件里:
/// 它自带 `requestId` 指回那条正在等的请求。
public struct A2PushEnvelope: Sendable, Equatable {
    public let v: Int
    public let id: String
    public let event: A2KernelEvent

    public init(id: String, event: A2KernelEvent) {
        self.v = A2Protocol.version
        self.id = id
        self.event = event
    }
}

extension A2PushEnvelope: Codable {
    private enum CodingKeys: String, CodingKey { case v, id, push, event }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeProtocolVersion(forKey: .v)
        id = try container.decodeNonEmptyString(forKey: .id)
        try container.decodeLiteralBool(true, forKey: .push)
        event = try container.decode(A2KernelEvent.self, forKey: .event)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(true, forKey: .push)
        try container.encode(event, forKey: .event)
    }
}

/// 服务端可能写到连接上的一切:响应 | 推送(对照 `ServerFrameSchema`)。长连接客户端按这个解。
///
/// 判别**只看结构**:有 `ok` 是响应,有 `push` 是推送,两者永不同现;两个都没有 = 不是本协议的帧。
public enum A2ServerFrame: Sendable, Equatable {
    case response(A2ResponseEnvelope)
    case push(A2PushEnvelope)
}

extension A2ServerFrame: Codable {
    private enum CodingKeys: String, CodingKey { case ok, push }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasOK = container.contains(.ok)
        let hasPush = container.contains(.push)
        guard hasOK != hasPush else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: hasOK
                    ? "同一帧里 ok 与 push 同时出现 —— 判别是结构性的,两者永不同现"
                    : "既没有 ok 也没有 push —— 不是服务端帧")
        }
        if hasOK {
            self = .response(try A2ResponseEnvelope(from: decoder))
        } else {
            self = .push(try A2PushEnvelope(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .response(envelope): try envelope.encode(to: encoder)
        case let .push(envelope): try envelope.encode(to: encoder)
        }
    }
}
