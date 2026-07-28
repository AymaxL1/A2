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

/// 已知操作码集合。请求经 `op` 字段路由;留字符串是为了让 03 票增量扩展(describe/call)而不改类型形状。
public enum WireOp {
    /// 列出已注册能力(02 票唯一实现的 op)。
    public static let capabilitiesList = "capabilities.list"
    // 03 票将追加:capabilities.describe / capabilities.call
}

/// 线协议请求。02 票只用到 `op`;03 票可为本类型追加可选字段(如 capability / input)而保持向后兼容。
public struct WireRequest: Codable, Sendable, Equatable {
    /// 操作码,取值见 `WireOp`。
    public let op: String

    public init(op: String) {
        self.op = op
    }
}

/// 统一错误载荷。`code` 供机器分支(如 `unknown_op`),`detail` 供人/agent 阅读。
public struct WireError: Codable, Sendable, Equatable {
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
