// AAContracts —— 能力描述符(能力清单里的一行 + 结构化 schema)。
// 宿主注册表产出、经 UDS 线协议下发、由 aa 反解并打印,三方共用同一个 Codable 类型(spec 用户故事 12:契约集中,禁裸 dict)。
//
// 03 票:给描述符加 `parameters`(结构化最小 schema)。describe 必须能拿到 parameters,好让 agent
// 不读源码就能构造合法调用;list 也整体回(轻量与否是实现细节,单一描述符类型贯穿三方,最省心)。
// V1 不上重量级 JSON Schema(YAGNI),就这套 name/type/required/description 的最小结构化 schema。

/// 单个参数的结构化 schema(最小可用集)。
///
/// - `name`:参数名(input 对象里的键)。
/// - `type`:简单类型串,取值 `"string" | "number" | "bool" | "object" | "array"`(与 `JSONValue.typeName` 对齐)。
/// - `required`:是否必填(宿主侧集中校验缺失即报 `missing_parameter`)。
/// - `description`:一句话人/agent 可读说明。
public struct ParameterSpec: Codable, Sendable, Equatable {
    public let name: String
    public let type: String
    public let required: Bool
    public let description: String

    public init(name: String, type: String, required: Bool, description: String) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
    }
}

/// 单个能力的描述符。
///
/// 字段:
/// - `id`:能力稳定标识(如 `demo.echo` / 将来 `proxy.status`),点分域命名。
/// - `risk`:风险三档强类型(见 `RiskLevel`);这是 S2 spike 里 String risk 的强类型升级。
/// - `summary`:一句话人读摘要(同时兼作 agent 可读短描述)。
/// - `schemaSummary`:入参/出参速览一句话,可空(人读友好;机器校验以下面的 `parameters` 为准)。
/// - `parameters`:结构化最小 schema(03 票新增);describe 输出它,invoke 据它做集中校验。
public struct CapabilityDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let risk: RiskLevel
    public let summary: String
    public let schemaSummary: String?
    public let parameters: [ParameterSpec]

    public init(id: String, risk: RiskLevel, summary: String, schemaSummary: String? = nil, parameters: [ParameterSpec] = []) {
        self.id = id
        self.risk = risk
        self.summary = summary
        self.schemaSummary = schemaSummary
        self.parameters = parameters
    }
}
