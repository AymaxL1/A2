// AAAgentCore —— 「宿主调用本地 agent」适配层的平台统一 6 型消息模型。
// 依赖边:AAAgentCore → AAContracts(仅此;不 import Foundation、不 import 任何 Host*)。
//
// 归一化契约(spec「消息归一化」节):两家 agent 迥异的原生事件流(Claude 的 stream-json、
//   Codex exec 的 NDJSON)由各自 adapter 翻译成同一套 6 型消息(text/thinking/tool-use/
//   tool-result/status/error);上层只认这一种模型,底下换哪家 agent 都行。
//   **工具调用 CallID 全链保留**——修 multica 在 daemon 边界丢 CallID 的有损点。
//   本模型是适配层内部词汇(暂不进 Contracts:它非三方共用契约,只服务 AAAgentCore 内部)。
//
// Codable 约定:可选字段一律经 `encodeIfPresent` 编码 —— nil 时整键省略(不产 `"tool":null`),
//   与 `AAContracts.WireResponse` 同款「nil 不产键」约定。此处**手写** CodingKeys + encode/init
//   把该行为显式定死,不依赖合成 Codable 的隐式次序;`kind` 为唯一必填键,恒被编码。

import AAContracts

/// 6 型统一消息种类。rawValue 用连字符串(agent 机器面 / CLI-JSON 生态惯例),与上层的 Swift 驼峰命名解耦。
public enum AgentMessageKind: String, Codable, Sendable, CaseIterable {
    case text = "text"
    case thinking = "thinking"
    case toolUse = "tool-use"
    case toolResult = "tool-result"
    case status = "status"
    case error = "error"
}

/// 平台统一消息:一条被归一化后的 agent 事件。`kind` 决定其余字段的语义,故其余字段皆可选、按型填充。
///
/// 字段与 6 型的对应关系:
/// - `text`   —— text / thinking / error 三型的文本内容;
/// - `tool`   —— tool-use 的工具名;
/// - `callID` —— tool-use / tool-result 的调用标识,**全链保留**(工具调用与其结果据此配对);
/// - `input`  —— tool-use 的入参(任意 JSON);
/// - `output` —— tool-result 的产物(任意 JSON);
/// - `isError`—— tool-result 是否为错误结果(Claude `is_error` 的归一化落点);
/// - `status` —— status 型的具体状态串。
public struct AgentMessage: Codable, Sendable, Equatable {
    /// 消息种类(6 型之一)——唯一必填字段。
    public let kind: AgentMessageKind
    /// text / thinking / error 内容。
    public var text: String?
    /// tool-use 工具名。
    public var tool: String?
    /// tool-use / tool-result 调用标识——全链保留(修 multica 丢 CallID 的有损点)。
    public var callID: String?
    /// tool-use 入参。
    public var input: JSONValue?
    /// tool-result 产物。
    public var output: JSONValue?
    /// tool-result 是否错误结果(Claude is_error 归一化用)。
    public var isError: Bool?
    /// status 具体状态串。
    public var status: String?

    /// 全字段构造:`kind` 必填,其余默认 nil(按型只填相关字段)。
    public init(
        kind: AgentMessageKind,
        text: String? = nil,
        tool: String? = nil,
        callID: String? = nil,
        input: JSONValue? = nil,
        output: JSONValue? = nil,
        isError: Bool? = nil,
        status: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.tool = tool
        self.callID = callID
        self.input = input
        self.output = output
        self.isError = isError
        self.status = status
    }

    // —— 手写 Codable:显式 encodeIfPresent 让 nil 键省略(与 WireResponse 同款约定)——
    private enum CodingKeys: String, CodingKey {
        case kind, text, tool, callID, input, output, isError, status
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)                       // kind 必填,恒编码
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(tool, forKey: .tool)
        try c.encodeIfPresent(callID, forKey: .callID)
        try c.encodeIfPresent(input, forKey: .input)
        try c.encodeIfPresent(output, forKey: .output)
        try c.encodeIfPresent(isError, forKey: .isError)
        try c.encodeIfPresent(status, forKey: .status)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(AgentMessageKind.self, forKey: .kind)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.tool = try c.decodeIfPresent(String.self, forKey: .tool)
        self.callID = try c.decodeIfPresent(String.self, forKey: .callID)
        self.input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
        self.output = try c.decodeIfPresent(JSONValue.self, forKey: .output)
        self.isError = try c.decodeIfPresent(Bool.self, forKey: .isError)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    // —— 6 型便利构造器(adapter 归一化时按型直造,免散写全字段 init)——

    /// text:纯文本内容。
    public static func text(_ content: String) -> AgentMessage {
        AgentMessage(kind: .text, text: content)
    }
    /// thinking:模型思考流内容(与 text 同承载于 `text` 字段,按 kind 区分)。
    public static func thinking(_ content: String) -> AgentMessage {
        AgentMessage(kind: .thinking, text: content)
    }
    /// tool-use:一次工具调用(工具名 + 入参 + 调用标识 callID,全链保留)。
    public static func toolUse(callID: String, tool: String, input: JSONValue?) -> AgentMessage {
        AgentMessage(kind: .toolUse, tool: tool, callID: callID, input: input)
    }
    /// tool-result:一次工具调用的结果(据 callID 与其 tool-use 配对;isError 归一化 Claude is_error)。
    public static func toolResult(callID: String, output: JSONValue?, isError: Bool?) -> AgentMessage {
        AgentMessage(kind: .toolResult, callID: callID, output: output, isError: isError)
    }
    /// status:一条状态消息(如「操作被拒」归一化落点)。
    public static func status(_ state: String) -> AgentMessage {
        AgentMessage(kind: .status, status: state)
    }
    /// error:一条错误消息(内容承载于 `text`)。
    public static func error(_ content: String) -> AgentMessage {
        AgentMessage(kind: .error, text: content)
    }
}
