// A2Contract —— **执行指令帧与回执**(对照 `wire.ts` 的「执行指令帧与回执」一节,url-router 施工 04 票)。
//
// 这一对是**内核 ↔ 机械执行器**之间的全部协议,壳两个方向都要用:
//   * 解 `A2URLRouterExecuteCommand`(内核推来的指令);
//   * 拼 `A2URLRouterExecutorReportParams`(壳回去的结果)。
//
// 它与确认器那一对形状同构、语义完全不同,而那个不同正是壳这一侧最该守住的边界:
//   * 确认器收到的是「有人要干这件事,你替人看一眼」——它的回答是**决定**;
//   * 执行器收到的是「去把这件事做了」——它的回答是**结果**。
//
// **执行器零判断**(ADR 0008 第 5 条修订的第②条受限例外):唯一合法反应是照帧上写的调系统 API,
// 再把 completion 原样回传。它不许挑 scheme、不许改 bundleID、不许自己决定要不要弹框
// (弹不弹是 OS 的事)、更不许判断 NSError 是不是"用户取消"——那种判断一旦写进壳,
// 就等于让壳替内核决定一次 dangerous 调用的收场。

import Foundation

/// 能被接管的两个 scheme(对照 `UrlRouterSchemeSchema`)。**只有这两个**,词表封闭。
public enum A2URLRouterScheme: String, Sendable, Codable, Equatable, CaseIterable {
    case http
    case https
}

/// 执行指令帧的动作词表(对照 `UrlRouterExecuteOpSchema`)。
///
/// **白名单是有意的**:壳只认得它认得的那几件事。收到不在表上的 op,整帧解不动是**对的** ——
/// 壳宁可吵起来,也不能猜内核想让它干什么(而它干的事会改全系统的状态)。
public enum A2URLRouterExecuteOp: String, Sendable, Codable, Equatable, CaseIterable {
    case setDefaultHandler = "set-default-handler"
}

/// 内核 → 壳的执行指令帧(对照 `UrlRouterExecuteCommandSchema`,spec §6.3)。
public struct A2URLRouterExecuteCommand: Sendable, Equatable {
    /// 这一次执行的 id;回执必须**原样带回来**(首个回话收场胜出)。
    public let id: String
    public let op: A2URLRouterExecuteOp
    /// 要设的那些 scheme。http 与 https 各弹一次系统框是 OS 行为,壳如实等两次 completion。
    public let schemes: [A2URLRouterScheme]
    /// 要成为这些 scheme 默认 handler 的 bundle id。
    public let bundleID: String
    /// **内核那一侧**的等待窗(秒)。壳知道它,但**不据此设第二个钟** —— 一件事只该有一个人计时。
    public let timeoutSeconds: Int

    public init(
        id: String, op: A2URLRouterExecuteOp, schemes: [A2URLRouterScheme], bundleID: String,
        timeoutSeconds: Int
    ) {
        self.id = id
        self.op = op
        self.schemes = schemes
        self.bundleID = bundleID
        self.timeoutSeconds = timeoutSeconds
    }
}

extension A2URLRouterExecuteCommand: Codable {
    private enum CodingKeys: String, CodingKey { case id, op, schemes, bundleID, timeoutSeconds }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeNonEmptyString(forKey: .id)
        op = try container.decode(A2URLRouterExecuteOp.self, forKey: .op)
        schemes = try container.decode([A2URLRouterScheme].self, forKey: .schemes)
        // 契约是 `.min(1)`:一个 scheme 都不设的指令没有意义,收到它只说明有一侧写错了。
        guard !schemes.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemes, in: container, debugDescription: "schemes 至少要有一个")
        }
        bundleID = try container.decodeNonEmptyString(forKey: .bundleID)
        timeoutSeconds = try container.decodePositiveInt(forKey: .timeoutSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(op, forKey: .op)
        try container.encode(schemes, forKey: .schemes)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    }
}

/// 一个 scheme 上系统 API 回来的**原样** NSError(对照 `UrlRouterExecutorErrorSchema`)。
///
/// 三件套原样序列化、不翻译、不归类。spec §11 遗留项:用户取消时这三个字段的实际取值要在
/// 06 票的真机弹框旅程里回填 —— 在那之前**没有人编造它**,壳也不靠它做任何判断。
public struct A2URLRouterExecutorError: Sendable, Equatable {
    public let domain: String
    /// `NSError.code` 原值(**可能是负数** —— NSOSStatusErrorDomain 那一族就是)。
    public let code: Int
    /// `localizedDescription` 原文。
    public let description: String

    public init(domain: String, code: Int, description: String) {
        self.domain = domain
        self.code = code
        self.description = description
    }
}

extension A2URLRouterExecutorError: Codable {
    private enum CodingKeys: String, CodingKey { case domain, code, description }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decodeNonEmptyString(forKey: .domain)
        // **不收严成非负**:契约是 `z.number().int()`,而系统错误码本来就常常是负的。
        code = try container.decode(Int.self, forKey: .code)
        description = try container.decodeNonEmptyString(forKey: .description)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(code, forKey: .code)
        try container.encode(description, forKey: .description)
    }
}

/// 单个 scheme 的执行结果(对照 `UrlRouterSchemeReportSchema`)。
public struct A2URLRouterSchemeReport: Sendable, Equatable {
    public let ok: Bool
    /// `ok == false` 时的原样 NSError(成了就**整个键不出现**)。
    public let error: A2URLRouterExecutorError?

    public init(ok: Bool, error: A2URLRouterExecutorError? = nil) {
        self.ok = ok
        self.error = error
    }
}

extension A2URLRouterSchemeReport: Codable {
    private enum CodingKeys: String, CodingKey { case ok, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(A2URLRouterExecutorError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// 逐 scheme 的执行结果表(对照 `UrlRouterPerSchemeSchema`)。
///
/// 两个成员**都可缺席**,而缺席是一句真话:「这个 scheme 压根没轮到」(壳可能在解析目标 app
/// 那一步就失败了,一个系统调用都没发)。它与 `ok: false`(轮到了、没成)是两件事。
public struct A2URLRouterPerScheme: Sendable, Equatable {
    public let http: A2URLRouterSchemeReport?
    public let https: A2URLRouterSchemeReport?

    public init(http: A2URLRouterSchemeReport? = nil, https: A2URLRouterSchemeReport? = nil) {
        self.http = http
        self.https = https
    }

    public subscript(scheme: A2URLRouterScheme) -> A2URLRouterSchemeReport? {
        switch scheme {
        case .http: return http
        case .https: return https
        }
    }

    /// 逐条装配(执行器一个 scheme 一个 scheme 地填)。
    public func setting(
        _ scheme: A2URLRouterScheme, _ report: A2URLRouterSchemeReport
    ) -> A2URLRouterPerScheme {
        switch scheme {
        case .http: return A2URLRouterPerScheme(http: report, https: https)
        case .https: return A2URLRouterPerScheme(http: http, https: report)
        }
    }
}

extension A2URLRouterPerScheme: Codable {
    private enum CodingKeys: String, CodingKey { case http, https }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        http = try container.decodeIfPresent(A2URLRouterSchemeReport.self, forKey: .http)
        https = try container.decodeIfPresent(A2URLRouterSchemeReport.self, forKey: .https)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(http, forKey: .http)
        try container.encodeIfPresent(https, forKey: .https)
    }
}

/// 壳自报的收场词(对照 `UrlRouterExecutionOutcomeSchema`)。**词表封闭**。
///
/// **本版的壳只会产出 `confirmed` 与 `error`**,这是如实记下的边界而不是遗漏:
/// 分辨"用户点了取消"要靠 completion 那个 NSError 的 domain/code,而那两个值要到 06 票的
/// 真机弹框旅程才拿得到(spec §11)。`denied` / `timeout` 先立在词表里、内核那侧的映射也已就位 ——
/// 06 回填之后壳只需在**一处**加一个判断,协议一个字都不用改。
public enum A2URLRouterExecutionOutcome: String, Sendable, Codable, Equatable, CaseIterable {
    case confirmed
    case denied
    case timeout
    case error
}

/// 壳 → 内核的回执(对照 `UrlRouterExecutorReportParamsSchema`)。**这是要写出去的那一类**。
public struct A2URLRouterExecutorReportParams: Sendable, Equatable {
    /// 对应指令帧的 `id`。
    public let execution: String
    public let outcome: A2URLRouterExecutionOutcome
    public let perScheme: A2URLRouterPerScheme
    /// 一句话说明(如「目标 app 不存在」)。**不替代 perScheme 里的原样 NSError**。
    public let error: String?

    public init(
        execution: String, outcome: A2URLRouterExecutionOutcome,
        perScheme: A2URLRouterPerScheme, error: String? = nil
    ) {
        self.execution = execution
        self.outcome = outcome
        self.perScheme = perScheme
        self.error = error
    }
}

extension A2URLRouterExecutorReportParams: Codable {
    private enum CodingKeys: String, CodingKey { case execution, outcome, perScheme, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        execution = try container.decodeNonEmptyString(forKey: .execution)
        outcome = try container.decode(A2URLRouterExecutionOutcome.self, forKey: .outcome)
        perScheme = try container.decode(A2URLRouterPerScheme.self, forKey: .perScheme)
        error = try container.decodeNonEmptyStringIfPresent(forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(execution, forKey: .execution)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(perScheme, forKey: .perScheme)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// `url-router.executor.report` 的 result(对照 `UrlRouterExecutorReportResultSchema`)。
/// `accepted` 恒 true —— 没被收下的情形一律走失败包封。
public struct A2URLRouterExecutorReportResult: Sendable, Equatable {
    public let execution: String
    public let accepted: Bool

    public init(execution: String) {
        self.execution = execution
        self.accepted = true
    }
}

extension A2URLRouterExecutorReportResult: Codable {
    private enum CodingKeys: String, CodingKey { case execution, accepted }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        execution = try container.decodeNonEmptyString(forKey: .execution)
        try container.decodeLiteralBool(true, forKey: .accepted)
        accepted = true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(execution, forKey: .execution)
        try container.encode(accepted, forKey: .accepted)
    }
}
