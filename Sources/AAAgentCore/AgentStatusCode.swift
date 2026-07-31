// AAAgentCore —— status 型消息的**共用词汇表**(两家 adapter 共用,避免各写各的裸字符串)。
// 依赖边:AAAgentCore → AAContracts(本文件连 AAContracts 都用不上:纯 stdlib 类型;更不 import 任何 Host*)。
//
// 定位:6 型消息里 `status` 型的 `status` 字段是个自由串(为的是能原生保真兜底,如 `"system:api_retry"`
//   / `"unknown:control_request"` / `"unknown-block:<type>"` —— 这些串里嵌着**原生**类型名,
//   是平台没定义过的形状,枚举不该也无法穷举)。
//   但**平台自己定义**的那几个状态必须有唯一出处:否则 Claude adapter 写 "permission-denied"、
//   Codex adapter 写 "permission_denied",上层就得两边都认 —— 这正是要避免的。
//   故:平台词汇进本枚举,原生保真串仍走自由串,两条路各司其职。
//
// 不做成 Codable:它只是 `AgentMessage.status` 字段的**取值来源**(编码时已是 rawValue 串),
//   自身从不单独上线;上层识别用 `msg.status == AgentStatusCode.xxx.rawValue`。

/// 平台共用的 status 词汇表。rawValue 用连字符串(与 `AgentMessageKind` 同款机器面命名)。
public enum AgentStatusCode: String, Sendable, CaseIterable {
    /// 会话起始(Claude `system/init`;Codex `thread.started`)——同时是 sessionID 的产出行。
    case sessionStarted = "session-started"
    /// 回合开始(Codex `turn.started` 的归一化落点)。Claude 侧无对应事件 —— 它的 `system/init` 与 `result`
    /// 就是回合边界,不另发「回合开始」;此处如实只服务 Codex,不为对称而给 Claude 硬造一条。
    case turnStarted = "turn-started"
    /// 回合正常结束(Codex `turn.completed` 的归一化落点)。与终态 `.succeeded` **同一行产出**:
    /// 终态供上层判定,这条 status 让「回合正常收尾」在按序渲染的消息流里也看得见(二者不是重复,是两个消费面)。
    case turnCompleted = "turn-completed"
    /// 触发限流 / 限流状态播报(Claude `rate_limit_event`)。
    case rateLimit = "rate-limit"
    /// 操作被拒(Claude `permission_denials[]` + `is_error:true` 的 tool_result)。
    case permissionDenied = "permission-denied"
    /// 被中断 / 取消(终态判定为 `.aborted` 时额外产出)。
    case interrupted = "interrupted"
    /// 原始行解析失败的降级落点(非 JSON 噪声 / 进程被杀导致的截断行)。
    /// 它虽不是「agent 说的话」,却是**平台自造**的固定词:两家 adapter 都会走这条降级路径,
    /// 故必须有唯一出处,否则一家写 "unparsed"、另一家写 "parse-error",上层就得两边都认。
    case unparsed = "unparsed"
}
