// A2Contract —— 包封、结构化错误、拒绝即指引(对照 `wire.ts` 的「拒绝即指引」「结构化错误」「包封」三节)。

import Foundation

/// 线协议常量。
public enum A2Protocol {
    /// 线协议版本(对照 `PROTOCOL_VERSION`)。不兼容变更才 +1。
    public static let version = 1
}

// MARK: - 拒绝即指引

/// 指引的一步(对照 `GuidanceStepSchema`)。
/// `command` 是**给人类原样执行**的精确命令;没有命令的说明步骤只填 `description`。
public struct A2GuidanceStep: Sendable, Equatable {
    public let description: String
    public let command: String?

    public init(description: String, command: String? = nil) {
        self.description = description
        self.command = command
    }
}

extension A2GuidanceStep: Codable {
    private enum CodingKeys: String, CodingKey { case description, command }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decodeNonEmptyString(forKey: .description)
        command = try container.decodeNonEmptyStringIfPresent(forKey: .command)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(command, forKey: .command)
    }
}

/// 「拒绝即指引」载荷(对照 `GuidanceSchema`)。`steps` **不得为空** —— 没有下一步的指引等于没有指引。
public struct A2Guidance: Sendable, Equatable {
    public let summary: String
    public let steps: [A2GuidanceStep]
    /// 给 agent 免猜的事实(展开后的路径等),值一律字符串。
    public let context: [String: String]?

    public init(summary: String, steps: [A2GuidanceStep], context: [String: String]? = nil) {
        self.summary = summary
        self.steps = steps
        self.context = context
    }
}

extension A2Guidance: Codable {
    private enum CodingKeys: String, CodingKey { case summary, steps, context }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeNonEmptyString(forKey: .summary)
        steps = try container.decodeNonEmptyArray([A2GuidanceStep].self, forKey: .steps)
        context = try container.decodeIfPresent([String: String].self, forKey: .context)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encode(steps, forKey: .steps)
        try container.encodeIfPresent(context, forKey: .context)
    }
}

// MARK: - 结构化错误

/// 统一错误载荷(对照 `WireErrorSchema`)。
///
/// `guidance` 在**包封这一层是可选的**,这是真话:`unknown_op` / `bad_request` 这类"你敲错了"
/// 本来就没有"人类如何完成"可言。真正必带指引的是仲裁三码,由 `A2ConfirmationError` 单独收窄。
public struct A2WireError: Sendable, Equatable {
    public let code: String
    public let message: String
    public let detail: String?
    public let guidance: A2Guidance?

    public init(code: String, message: String, detail: String? = nil, guidance: A2Guidance? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
        self.guidance = guidance
    }
}

extension A2WireError: Codable {
    private enum CodingKeys: String, CodingKey { case code, message, detail, guidance }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeNonEmptyString(forKey: .code)
        message = try container.decodeNonEmptyString(forKey: .message)
        detail = try container.decodeNonEmptyStringIfPresent(forKey: .detail)
        guidance = try container.decodeIfPresent(A2Guidance.self, forKey: .guidance)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(guidance, forKey: .guidance)
    }
}

/// 已登记的 `error.code`(对照 `ErrorCode`)。**取值即契约**,这里只镜像壳与客户端会分支的那些。
///
/// 有意**不做成 enum**:内核新增错误码时客户端不该炸(旧壳收到新码应当照常显示 message,
/// 而不是解码失败把整条响应丢掉)。字符串常量表既能对号,又不封死取值域。
public enum A2ErrorCode {
    public static let badRequest = "bad_request"
    public static let unknownOp = "unknown_op"
    public static let internalError = "internal_error"
    public static let daemonUnreachable = "daemon_unreachable"
    public static let usage = "usage"

    /// dangerous 被调用但**没有确认器在场**(第①层默拒);在途时确认器全断线也复用这一码。
    public static let confirmationUnavailable = "confirmation_unavailable"
    /// 确认器在场,人类**明确点了拒绝**。
    public static let confirmationDenied = "confirmation_denied"
    /// 确认器在场、请求送到了,但窗口内没人做决定(超时即拒,fail-closed)。
    public static let confirmationTimeout = "confirmation_timeout"

    /// 对端不是同一个 UID —— 连接当场被拒。
    public static let peerRejected = "peer_rejected"
    /// `confirmations.resolve` 指向的确认请求不存在或已收场。
    public static let confirmationUnknown = "confirmation_unknown"
    /// 这条连接没注册所需角色就来干这个角色的活。
    public static let roleNotRegistered = "role_not_registered"

    /// 仲裁三码 —— 这三条**必带 guidance**(由 `A2ConfirmationError` 在契约层强制)。
    public static let confirmationCodes: [String] = [
        confirmationUnavailable, confirmationDenied, confirmationTimeout,
    ]
}

/// **仲裁三码的错误载荷**(对照 `ConfirmationErrorSchema`):`WireError` 的收窄版 ——
/// `code` 限定在三码之内,且 `guidance` **必填**。
///
/// 它与 `A2WireError` 是**同一批字节的两种读法**:失败包封里躺着的是 `WireError`,
/// 当 `code` 属于三码时,那份字节必须也能按本类型解开(解不开 = 内核漏了指引 = 契约破了)。
public struct A2ConfirmationError: Sendable, Equatable {
    public let code: String
    public let message: String
    public let detail: String?
    public let guidance: A2Guidance

    public init(code: String, message: String, detail: String? = nil, guidance: A2Guidance) {
        self.code = code
        self.message = message
        self.detail = detail
        self.guidance = guidance
    }
}

extension A2ConfirmationError: Codable {
    private enum CodingKeys: String, CodingKey { case code, message, detail, guidance }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCode = try container.decodeNonEmptyString(forKey: .code)
        guard A2ErrorCode.confirmationCodes.contains(rawCode) else {
            throw DecodingError.dataCorruptedError(
                forKey: .code, in: container,
                debugDescription: "不是仲裁三码之一:\(rawCode)")
        }
        code = rawCode
        message = try container.decodeNonEmptyString(forKey: .message)
        detail = try container.decodeNonEmptyStringIfPresent(forKey: .detail)
        // 必填 —— 这正是本类型存在的理由(「拒绝即指引」从注释变成契约)。
        guidance = try container.decode(A2Guidance.self, forKey: .guidance)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(guidance, forKey: .guidance)
    }
}

// MARK: - 包封

/// 请求包封(对照 `RequestEnvelopeSchema`)。
public struct A2RequestEnvelope: Sendable, Equatable {
    public let v: Int
    public let id: String
    public let op: String
    public let params: [String: A2JSON]?

    public init(id: String, op: String, params: [String: A2JSON]? = nil) {
        self.v = A2Protocol.version
        self.id = id
        self.op = op
        self.params = params
    }
}

extension A2RequestEnvelope: Codable {
    private enum CodingKeys: String, CodingKey { case v, id, op, params }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeProtocolVersion(forKey: .v)
        id = try container.decodeNonEmptyString(forKey: .id)
        op = try container.decodeNonEmptyString(forKey: .op)
        params = try container.decodeIfPresent([String: A2JSON].self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(op, forKey: .op)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

/// 成功响应(对照 `SuccessResponseSchema`):`ok=true` 恒带 `result`。
public struct A2SuccessResponse: Sendable, Equatable {
    public let v: Int
    public let id: String
    public let result: A2JSON

    public init(id: String, result: A2JSON) {
        self.v = A2Protocol.version
        self.id = id
        self.result = result
    }
}

extension A2SuccessResponse: Codable {
    private enum CodingKeys: String, CodingKey { case v, id, ok, result }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeProtocolVersion(forKey: .v)
        id = try container.decodeNonEmptyString(forKey: .id)
        try container.decodeLiteralBool(true, forKey: .ok)
        // `result: null` 是合法的成功响应;**缺席不是**。
        result = try container.decodeRequiredJSON(forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(true, forKey: .ok)
        try container.encode(result, forKey: .result)
    }
}

/// 失败响应(对照 `FailureResponseSchema`):`ok=false` 恒带 `error`。
public struct A2FailureResponse: Sendable, Equatable {
    public let v: Int
    public let id: String
    public let error: A2WireError

    public init(id: String, error: A2WireError) {
        self.v = A2Protocol.version
        self.id = id
        self.error = error
    }
}

extension A2FailureResponse: Codable {
    private enum CodingKeys: String, CodingKey { case v, id, ok, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeProtocolVersion(forKey: .v)
        id = try container.decodeNonEmptyString(forKey: .id)
        try container.decodeLiteralBool(false, forKey: .ok)
        error = try container.decode(A2WireError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(false, forKey: .ok)
        try container.encode(error, forKey: .error)
    }
}

/// 响应包封 = 成功 | 失败(对照 `ResponseEnvelopeSchema`,**按 `ok` 判别**)。
public enum A2ResponseEnvelope: Sendable, Equatable {
    case success(A2SuccessResponse)
    case failure(A2FailureResponse)

    public var id: String {
        switch self {
        case let .success(response): return response.id
        case let .failure(response): return response.id
        }
    }

    public var isOK: Bool {
        if case .success = self { return true }
        return false
    }

    /// 成功时的 result;失败时 nil。
    public var result: A2JSON? {
        if case let .success(response) = self { return response.result }
        return nil
    }

    /// 失败时的 error;成功时 nil。
    public var error: A2WireError? {
        if case let .failure(response) = self { return response.error }
        return nil
    }
}

extension A2ResponseEnvelope: Codable {
    private enum CodingKeys: String, CodingKey { case ok }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 判别只看 `ok` —— 与 TS 侧的 `z.discriminatedUnion("ok", …)` 同一条判据。
        let ok = try container.decode(Bool.self, forKey: .ok)
        if ok {
            self = .success(try A2SuccessResponse(from: decoder))
        } else {
            self = .failure(try A2FailureResponse(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .success(response): try response.encode(to: encoder)
        case let .failure(response): try response.encode(to: encoder)
        }
    }
}
