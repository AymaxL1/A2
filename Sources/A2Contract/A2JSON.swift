// A2Contract —— a2 内核线协议的 Swift 侧**手写 Codable 镜像**(09 票)。
//
// 事实源是 TS(ADR 0010:契约 TS 为源,导出 JSON Schema,Swift 手写对照,**不引入代码生成链**)。
// 本模块与 `kernel/src/contract/wire.ts` 一一对照,两侧对同一批金标样本(`kernel/contract/golden/`)
// 编解码 —— 任一侧改了契约而另一侧没跟,门禁当场红(见 `Tests/A2ContractTests/`)。
//
// 与既有 `AAContracts` 的关系:**没有关系,故意的**。AAContracts 是旧 Swift 宿主(aahost)的线协议,
// 与 a2 内核不是同一份契约(op 名、错误码、包封形状都不同)。09 票是 expand 半步:新 target 长出来,
// 旧的一行不动;10 票原子切换时旧的才退场。两者共存期间**绝不互相 import**。
//
// 本文件:任意 JSON 值。`params` / `result` / 能力 `input` / `output` 都是"能力自定义的任意 JSON",
// 没有固定 struct 可言,故用一个 Codable 的值枚举承载。

import Foundation

/// 任意 JSON 值(对照 `wire.ts` 的 `JsonValueSchema`)。
///
/// **整数与浮点分开承载**,这不是洁癖:金标样本里 `pid: 4242`、`timeoutMs: 120000` 全是整数,
/// 若统一按 Double 收再编回去,`4242` 可能变成 `4242.0` —— 双端金标对照会因为一次无谓的类型漂移而红,
/// 或者更糟:红得让人以为契约变了。分开承载,原样进原样出。
public enum A2JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    indirect case array([A2JSON])
    indirect case object([String: A2JSON])

    /// 若是对象则返回其成员字典,否则 nil。
    public var objectValue: [String: A2JSON]? {
        if case let .object(members) = self { return members }
        return nil
    }

    /// 若是字符串则返回其值,否则 nil。
    public var stringValue: String? {
        if case let .string(text) = self { return text }
        return nil
    }
}

extension A2JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // 顺序有讲究:Bool 必须在数字之前试(JSON 的 true/false 与 1/0 是两回事,
        // 串档会让 `"push": true` 这类判别字段悄悄变成数字)。Int 在 Double 之前试,理由见类型头注。
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
            return
        }
        if let integer = try? container.decode(Int.self) {
            self = .int(integer)
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .double(number)
            return
        }
        if let text = try? container.decode(String.self) {
            self = .string(text)
            return
        }
        if let items = try? container.decode([A2JSON].self) {
            self = .array(items)
            return
        }
        if let members = try? container.decode([String: A2JSON].self) {
            self = .object(members)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别为任一 JSON 值类型")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(flag): try container.encode(flag)
        case let .int(integer): try container.encode(integer)
        case let .double(number): try container.encode(number)
        case let .string(text): try container.encode(text)
        case let .array(items): try container.encode(items)
        case let .object(members): try container.encode(members)
        }
    }
}
