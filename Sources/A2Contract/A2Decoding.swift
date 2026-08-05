// A2Contract —— 手写 Codable 的公共判据(09 票)。
//
// TS 侧的 zod 契约不只声明"有没有这个字段",还声明**取值约束**:`z.string().min(1)`、
// `z.array(...).min(1)`、`z.number().int().positive()`。金标里有专门为这些约束准备的 invalid 样本
// (如 `invalid-guidance-empty-steps.json`:steps 为空数组必须被拒)。
//
// 若 Swift 侧只按类型解码、不校验取值,那些 invalid 样本会**解得动** —— 双端门禁就漏了一格,
// 而漏的正是"拒绝即指引里有一条空指引"这种真会伤到人的形状。故这里把约束做成可复用的判据。
//
// ## 用法铁律:**更严只允许出现在 TS 也严的地方**
//
// 本文件的每个 `decodeNonEmpty*` / `decodePositive*` 都只能用在**契约原文写了对应约束**的字段上:
//   * `z.string().min(1)`      → `decodeNonEmptyString` / `decodeNonEmptyStringIfPresent`
//   * `z.string()`(**没有 min**)→ 就用 `decode(String.self)` / `decodeIfPresent(String.self)`,**不许收严**
//   * `z.array(X).min(1)`      → `decodeNonEmptyArray*`;元素也带 `min(1)` 时才用 `decodeNonEmptyStringArrayIfPresent`
//   * `z.number().int().positive()` / `.nonnegative()` → 对应的整数判据
//
// 为什么这条要写成铁律(09 票 CR 抓到的硬违反):镜像比契约**严**,后果是**内核发得出、壳收不下** ——
// 一条 `detail: ""` 的合法帧被 Swift 当场拒掉,整帧丢弃。那不是"更安全",那是自造一次不兼容:
// 镜像的职责是**照抄**,收严与放松同样是漂移。反向(镜像比契约松)则由非法金标样本兜。
// 两个方向都有断言守着,见 `Tests/A2ContractTests/OptionalStrictnessTests.swift`。
//
// **有意不做的**:不校验时间戳格式、不校验 id 形状、不拒绝未知字段。
//   * 前两者 TS 侧也只要求非空字符串(`z.string().min(1)`),这边照抄,不自作主张更严;
//   * 未知字段:TS 的 zod object 默认**剥掉**未知键而不是报错,Swift 侧对照物是"解码时忽略"。
//     真正把关的是金标往返断言 —— 样本里出现了镜像不认识的字段,重编码后就对不上,当场红。

import Foundation

extension KeyedDecodingContainer {
    /// 解一个**非空**字符串(对照 `z.string().min(1)`)。
    func decodeNonEmptyString(forKey key: Key) throws -> String {
        let value = try decode(String.self, forKey: key)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "字符串不得为空")
        }
        return value
    }

    /// 解一个可选的非空字符串:键不在 → nil;键在但为空串 → 报错(空串是错,不是"没填")。
    func decodeNonEmptyStringIfPresent(forKey key: Key) throws -> String? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "字符串不得为空")
        }
        return value
    }

    /// 解一个**非空**数组(对照 `z.array(...).min(1)`)。
    func decodeNonEmptyArray<T: Decodable>(_ type: [T].Type, forKey key: Key) throws -> [T] {
        let value = try decode([T].self, forKey: key)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "数组不得为空")
        }
        return value
    }

    /// 解一个可选的非空数组(键不在 → nil;在但为空 → 报错)。
    func decodeNonEmptyArrayIfPresent<T: Decodable>(_ type: [T].Type, forKey key: Key) throws -> [T]? {
        guard let value = try decodeIfPresent([T].self, forKey: key) else { return nil }
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "数组不得为空")
        }
        return value
    }

    /// 解一个可选的非空字符串数组,且**每个元素也不得为空**
    /// (对照 `z.array(z.string().min(1)).min(1).optional()` —— `cliAlias` 是唯一一处)。
    ///
    /// 元素级那道约束不是摆设:`cliAlias` 是 argv 的 token 序列,里面混进一个空串意味着
    /// `a2 proxy "" add` —— 那条命令拼出来就是坏的,让它在解码时就吵出来。
    func decodeNonEmptyStringArrayIfPresent(forKey key: Key) throws -> [String]? {
        guard let value = try decodeNonEmptyArrayIfPresent([String].self, forKey: key) else { return nil }
        guard !value.contains(where: \.isEmpty) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "数组元素不得为空串")
        }
        return value
    }

    /// 解一个正整数(对照 `z.number().int().positive()`)。
    func decodePositiveInt(forKey key: Key) throws -> Int {
        let value = try decode(Int.self, forKey: key)
        guard value > 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "必须为正整数,实际 \(value)")
        }
        return value
    }

    func decodePositiveIntIfPresent(forKey key: Key) throws -> Int? {
        guard let value = try decodeIfPresent(Int.self, forKey: key) else { return nil }
        guard value > 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "必须为正整数,实际 \(value)")
        }
        return value
    }

    /// 解一个非负整数(对照 `z.number().int().nonnegative()`)。
    func decodeNonNegativeInt(forKey key: Key) throws -> Int {
        let value = try decode(Int.self, forKey: key)
        guard value >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "必须为非负整数,实际 \(value)")
        }
        return value
    }

    func decodeNonNegativeIntIfPresent(forKey key: Key) throws -> Int? {
        guard let value = try decodeIfPresent(Int.self, forKey: key) else { return nil }
        guard value >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "必须为非负整数,实际 \(value)")
        }
        return value
    }

    /// 解一个**必填但可为 JSON null** 的值(对照 `z.object({ result: JsonValueSchema })`:
    /// `result: null` 合法,**键缺席**不合法)。
    ///
    /// 不能直接 `decode(A2JSON.self, forKey:)` —— Foundation 对 null 值的泛型解码行为在不同版本上
    /// 有过分歧(valueNotFound vs 交给类型自己判)。这里把"在不在"与"是不是 null"拆成两步,不赌那个行为。
    func decodeRequiredJSON(forKey key: Key) throws -> A2JSON {
        guard contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(codingPath: codingPath, debugDescription: "缺必填字段 \(key.stringValue)"))
        }
        return try decodeIfPresent(A2JSON.self, forKey: key) ?? .null
    }

    /// 解一个字面量布尔判别字段(对照 `z.literal(true)`):值不是期望的那个就报错。
    func decodeLiteralBool(_ expected: Bool, forKey key: Key) throws {
        let value = try decode(Bool.self, forKey: key)
        guard value == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "判别字段必须为 \(expected),实际 \(value)")
        }
    }

    /// 解协议版本(对照 `z.literal(PROTOCOL_VERSION)`):版本不对当场拒,**不做"兼容尝试"**。
    func decodeProtocolVersion(forKey key: Key) throws -> Int {
        let value = try decode(Int.self, forKey: key)
        guard value == A2Protocol.version else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "线协议版本不匹配:期望 \(A2Protocol.version),实际 \(value)")
        }
        return value
    }
}
