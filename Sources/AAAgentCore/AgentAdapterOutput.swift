// AAAgentCore —— 一次归一化的产出(两家 adapter 的**共用**返回类型)。
// 依赖边:本文件零 import(全部类型来自本模块与 stdlib)。
//
// 为什么独立成文件、不住在某一家 adapter 里:它是 ClaudeAdapter 与 CodexAdapter 共同的公开返回类型,
//   住在其中一家的文件里会让人误以为它是那家的私产。与 `AgentStatusCode` / `AgentTerminalStatus`
//   同样处理(本模块惯例:共用词汇不住单家文件)。

/// 一行(或多行)原始事件归一化后的产出。
///
/// 三个字段各有明确来源,不重叠:`messages` 是 6 型消息序列;`terminal` 仅终态行非 nil;
/// `sessionID` 仅会话起始行非 nil(Claude `system/init` 的 `session_id`;Codex `thread.started` 的 `thread_id`)。
///
/// **`terminal` 为 nil 不等于「还没结束」**:Codex 被中断 / 硬超时时事件流里根本没有终态行(02 spike 实证),
///   整条流跑完 `terminal` 仍是 nil 是**正常**情形。此时 job 终态由进程退出码 + 取消记账决定(票 05)。
public struct AgentAdapterOutput: Sendable, Equatable {
    /// 本次归一化产出的统一消息(按原生次序)。
    public var messages: [AgentMessage]
    /// 统一终态 —— 仅终态行非 nil(见类型注释:nil 是 Codex 的正常情形之一)。
    public var terminal: AgentTerminalStatus?
    /// 会话标识 —— 仅会话起始行非 nil。
    public var sessionID: String?

    public init(messages: [AgentMessage] = [], terminal: AgentTerminalStatus? = nil, sessionID: String? = nil) {
        self.messages = messages
        self.terminal = terminal
        self.sessionID = sessionID
    }
}
