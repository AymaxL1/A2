// AAContracts —— 任意 JSON 值的强类型承载(全平台机读契约的一块基石)。
//
// 用途:call 的入参(WireRequest.input)与出参(CallResult.output)都是「能力自定义的任意 JSON」,
// 无法用某个固定 struct 表达,故引入这个 Codable 的 JSON 值枚举来承载 —— 仍走 Codable,不手拼字符串。
//
// V1 取舍(YAGNI):
//   * 数字统一用 Double 承载(不区分 Int/Double)。demo 能力的数值不涉及大整数精度,足够;
//     若将来需要精确大整数,再在此扩 `.int` 分支(不改外部形状)。
//   * 手写 Codable:singleValueContainer 逐类型试解;编码走同一容器逐类型写。
//     解码顺序 null → bool → number → string → array → object(bool 必须在 number 之前试:
//     Foundation 对布尔/数字虽严格,但把 bool 放前面是稳妥的防串档次序)。

import Foundation

/// 任意 JSON 值。承载 call 的 input / output;也用于 WireRequest.input。
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// 值的类型名(用于 schema 类型校验的报错信息;与 `ParameterSpec.type` 的取值一致)。
    public var typeName: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .bool: return "bool"
        case .object: return "object"
        case .array: return "array"
        case .null: return "null"
        }
    }

    /// 便捷:若是对象则返回其成员字典,否则 nil(能力 handler 取参用)。
    public var objectValue: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }

    /// 便捷:若是字符串则返回其值,否则 nil。
    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别为任一 JSON 值类型")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
