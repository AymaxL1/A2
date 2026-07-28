// AAContracts —— 能力描述符(能力清单里的一行)。
// 宿主注册表产出、经 UDS 线协议下发、由 aa 反解并打印,三方共用同一个 Codable 类型(spec 用户故事 12:契约集中,禁裸 dict)。
//
// 注意:这里只放「清单视图」需要的字段——完整的 JSON Schema 归 03 票的 `capabilities describe`。
// 本票的 schemaSummary 只是一句人/agent 可读的入参出参速览(可空),不承担机器校验职责。

/// 单个能力的清单级描述符。
///
/// 字段:
/// - `id`:能力稳定标识(如 `demo.echo` / 将来 `proxy.status`),点分域命名。
/// - `risk`:风险三档强类型(见 `RiskLevel`);这是 S2 spike 里 String risk 的强类型升级。
/// - `summary`:一句话人读摘要(同时兼作 agent 可读短描述)。
/// - `schemaSummary`:入参/出参速览,可空;完整 schema 归 03 票 describe,清单层不携带。
public struct CapabilityDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let risk: RiskLevel
    public let summary: String
    public let schemaSummary: String?

    public init(id: String, risk: RiskLevel, summary: String, schemaSummary: String? = nil) {
        self.id = id
        self.risk = risk
        self.summary = summary
        self.schemaSummary = schemaSummary
    }
}
