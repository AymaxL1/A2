// AAContracts —— IPC 线协议(宿主 ⇄ aa,经 UDS)。
//
// 协议形态(S2 spike 已趟通、本票沿用并强类型化):
//   * 连接即请求:客户端连上 UDS、写一行 JSON 请求、读一行 JSON 响应、关连接。
//   * 逐行 JSON:请求与响应各为单行 UTF-8 JSON,以 '\n' 收尾。
//   * 全部经 JSONEncoder / JSONDecoder 编解码 —— 禁止手拼字符串(spec:契约用 Codable)。
//
// 本文件定义请求、响应信封、错误三类 Codable。02 票只实现 `capabilities.list`;
// 03 票在此基础上加 `capabilities.describe` / `capabilities.call`(新增 op 常量,并可为
// WireRequest 追加可选字段——可选字段向后兼容,老宿主/老客户端解码不受影响)。

import Foundation

/// 已知操作码集合。请求经 `op` 字段路由;留字符串是为了让增量扩展(describe/call)而不改类型形状。
public enum WireOp {
    /// 列出已注册能力(轻量清单视图)。
    public static let capabilitiesList = "capabilities.list"
    /// 取单个能力的完整描述符(含结构化 parameters,供 agent 不读源码即可构造调用)。
    public static let capabilitiesDescribe = "capabilities.describe"
    /// 调用单个能力(带 input,经宿主侧集中 schema 校验与风险路由)。
    public static let capabilitiesCall = "capabilities.call"
}

/// 统一 `error.code` 常量表(单一来源)。粗分类走退出码(见 `AAExitCode`),细因走这里的字符串码。
/// 宿主(Registry/UDSServer)产码、aa 依码映射退出码,双方都引用同一份常量,杜绝散写魔法字符串。
public enum WireErrorCode {
    // —— 请求/协议层 ——
    /// 请求非合法 JSON 或缺 op。
    public static let badRequest = "bad_request"
    /// 未知 op。
    public static let unknownOp = "unknown_op"
    /// 请求参数非法(如 call/describe 缺 capability 字段)。
    public static let invalidParams = "invalid_params"
    // —— 能力校验层(→ 退出码 6)——
    /// 未知能力 id。
    public static let unknownCapability = "unknown_capability"
    /// 缺必填参数。
    public static let missingParameter = "missing_parameter"
    /// 参数类型与 schema 声明不符。
    public static let typeMismatch = "type_mismatch"
    // —— 能力业务层(→ 退出码 5)——
    /// 能力执行了但返回业务错误。
    public static let capabilityFailed = "capability_failed"
    // —— 预留 ——
    /// dangerous 能力的宿主确认尚未实现(留给 04 票)。
    public static let notImplemented = "not_implemented"
    /// dangerous 被拒(04 票产生,→ 退出码 2;本票仅登记常量)。
    public static let denied = "denied"
    // —— 服务端内部 ——
    /// 响应编码失败。
    public static let encodeFailed = "encode_failed"
}

/// 线协议请求。`op` 必填;`capability`/`input` 为可选扩展字段(list 请求不带,向后兼容:
/// 老宿主/老客户端缺这两键解码得 nil,不受影响)。call 带 capability+input;describe 带 capability。
public struct WireRequest: Codable, Sendable, Equatable {
    /// 操作码,取值见 `WireOp`。
    public let op: String
    /// 目标能力 id(call / describe 用;list 省略)。
    public let capability: String?
    /// 调用输入(call 用;任意 JSON,经 `JSONValue` 承载;list/describe 省略)。
    public let input: JSONValue?

    public init(op: String, capability: String? = nil, input: JSONValue? = nil) {
        self.op = op
        self.capability = capability
        self.input = input
    }
}

/// 统一错误载荷。`code` 供机器分支(取值见 `WireErrorCode`),`detail` 供人/agent 阅读。
/// 兼作 `Error`,以便宿主侧 handler 用 `Result<JSONValue, WireError>` 表达业务错误。
public struct WireError: Codable, Sendable, Equatable, Error {
    public let code: String
    public let detail: String

    public init(code: String, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// 统一响应信封(泛型于具体 result 形状,一种信封贯穿所有 op)。
///
/// 线上形态:`{ "ok": Bool, "result": {...}?, "error": {"code","detail"}? }`。
/// - 成功:`ok=true`,`result` 存在,`error` 省略。
/// - 失败:`ok=false`,`error` 存在,`result` 省略。
/// (可选字段经合成 Codable 的 encodeIfPresent 编码 —— nil 时整键省略,不产 `"result":null`。)
public struct WireResponse<Result: Codable & Sendable>: Codable, Sendable {
    public let ok: Bool
    public let result: Result?
    public let error: WireError?

    public init(ok: Bool, result: Result?, error: WireError?) {
        self.ok = ok
        self.result = result
        self.error = error
    }

    /// 成功信封构造。
    public static func success(_ result: Result) -> WireResponse {
        WireResponse(ok: true, result: result, error: nil)
    }

    /// 失败信封构造。
    public static func failure(_ error: WireError) -> WireResponse {
        WireResponse(ok: false, result: nil, error: error)
    }
}

/// `capabilities.list` 的 result 载荷。
public struct CapabilityListResult: Codable, Sendable, Equatable {
    public let capabilities: [CapabilityDescriptor]

    public init(capabilities: [CapabilityDescriptor]) {
        self.capabilities = capabilities
    }
}

/// `capabilities.describe` 的 result 载荷:承载完整描述符(含结构化 `parameters`)。
public struct DescribeResult: Codable, Sendable, Equatable {
    public let descriptor: CapabilityDescriptor

    public init(descriptor: CapabilityDescriptor) {
        self.descriptor = descriptor
    }
}

/// `capabilities.call` 的 result 载荷:承载能力输出(任意 JSON,经 `JSONValue`)。
public struct CallResult: Codable, Sendable, Equatable {
    public let output: JSONValue

    public init(output: JSONValue) {
        self.output = output
    }
}
