// AAAgentCore —— 一次 agent 执行的**平台统一终态**(两家 adapter 共用的收敛落点)。
// 依赖边:AAAgentCore → AAContracts(本文件连 AAContracts 都用不上:纯 stdlib 类型;更不 import 任何 Host*)。
//
// 为什么独立成文件、名字不带 Claude:终态是**跨平台**词汇。
//   Claude 侧要联合 `is_error` / `terminal_reason` / `api_error_status` 三个字段才收敛得出终态
//   (**不能只看 `subtype`** —— 05 spike 实证:invalid-model 时 subtype 仍是 "success" 但 exit 1);
//   Codex 侧则是另一套原生形状(`error.message` 等,归 03 票)。两家各自的 adapter 把各自的原生
//   多字段判定收敛到这里的同一个三值枚举,上层只认这一种终态,底下换哪家 agent 都行。
//
// fail-closed 姿态:归一化规则里「都不匹配」的兜底是 `.failed` 而非 `.succeeded` ——
//   宁可把成功误报为失败(上层重试/告警),也绝不把失败误报为成功(上层据此当已完成)。
//
// **与 spec 的 job 状态枚举是两件事(别混)**:spec 写的统一终态含 `timeout`,票 04 的任务状态机还含
//   `pending/running/cancelled/orphaned`。那是**job 级**状态,由状态机(04)与看门狗(05)拥有——
//   它们的判据是「进程死没死、静默多久、用户点没点取消」,agent 的事件流里根本没有这些信息。
//   本枚举是**adapter 级**终态:只回答「agent 自己的事件流说这次执行怎么结束的」,故只有三值。
//   映射关系:adapter `.succeeded/.failed/.aborted` 是 job 状态的**输入之一**,job 侧的 `timeout` /
//   `cancelled` / `orphaned` 由状态机独立判出(Codex 被中断时事件流里连终态行都没有,02 spike 实证 ——
//   届时 adapter 交回 `terminal == nil`,更说明 job 终态不能只由 adapter 决定)。
//   命名上 `succeeded` 与 spec 字面的 `completed` 有一处漂移,是**刻意**的:避免与 job 状态的 `completed`
//   同名而被误当同一个值。

/// 一次 agent 执行的统一终态(三值,穷尽 —— 见文件头「与 job 状态枚举是两件事」)。
/// rawValue 用小写串(与 6 型消息同款机器面命名)。
public enum AgentTerminalOutcome: String, Codable, Sendable, CaseIterable {
    /// 正常完成。
    case succeeded = "succeeded"
    /// agent 侧报错终止(API 错 / model 错 / 业务失败)。
    case failed = "failed"
    /// 被中断 / 取消(宿主发信号、用户取消等)。
    case aborted = "aborted"
}

/// 统一终态 + 原生理由 + 终局答复:`outcome` 供上层判定,`reason` 保真原生细节,`finalText` 承载终局答复文本。
///
/// `reason` 的取值:Claude 取 `terminal_reason`(缺失退回 `subtype`);Codex 取 `error.message`(03 票)。
/// 刻意保留原生串而不再枚举化:诊断面要如实,判定面才要收敛 —— 二者分开,避免为了枚举干净而丢证据。
///
/// **`finalText` 为什么在终态里、而不是消息流里的一条 `.text`**:Claude 的 `result.result` 实测是**最后一条
///   assistant text 的逐字回显**(01/02/03/05/07 五个有答复的样本无一例外)。若把它也产成一条 `.text` 消息,
///   报告与日志就会把同一段结论打印两遍,且两条 `.text` 无任何标记可区分「过程文本」与「终局答复」。
///   放进终态则语义精确:消息流 = 过程,终态 = 结论。票 04 的「report.html 缺失时用最终文本套兜底模板」
///   直接读这里,不必去消息流里猜哪条是结论。
///   Codex 侧 `turn.completed` 原生没有对应字段 → `finalText` 为 nil,04 退回「取最后一条 `.text` 消息」。
public struct AgentTerminalStatus: Codable, Sendable, Equatable {
    /// 收敛后的统一终态。
    public let outcome: AgentTerminalOutcome
    /// 原生终态理由(Claude: `terminal_reason`;Codex: `error.message`),缺失为 nil。
    public let reason: String?
    /// 终局答复文本(Claude: `result.result`;Codex 无对应字段恒为 nil),缺失 / 空串为 nil。
    public let finalText: String?

    public init(outcome: AgentTerminalOutcome, reason: String?, finalText: String? = nil) {
        self.outcome = outcome
        self.reason = reason
        self.finalText = finalText
    }
}
