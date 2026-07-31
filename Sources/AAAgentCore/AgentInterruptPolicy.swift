// AAAgentCore —— 两家 agent 中断行为差异的**域逻辑收敛**(agent-delegation 05 票第 4 条)。
// 依赖边:本文件零 import(只用同模块类型 + stdlib)。模块级红线同 AgentPort.swift。
//
// 本文件回答的是一个纯粹的域问题:**发出终止意图之后,读流的姿态该是什么?**
//   两家 spike 实证给出的答案**相反**,而这个不对称不是实现细节、抹不平,只能显式建模:
//
//   * Claude(01 spike `spike-claude-headless/findings.md`):收到信号后**先合成**一条
//     `[Request interrupted by user]` 事件、**再落终态** `result`(`terminal_reason:"aborted_streaming"`)才退出。
//     → 一发信号就弃管道,就把这份真终态丢了(任务只剩「被信号杀」的退出码可猜)。必须 **drain 读到底**。
//   * Codex(02 spike `spike-codex-exec/findings.md` 第 4 节 + 建议 6,样本 exec5):被进程组 SIGTERM 杀时
//     流里**根本没有终态行**(`turn.failed` / `turn.aborted` 一个都没有,流原样截断),退出码 `-15`。
//     → 再怎么读也读不出终态,**只能在发信号那一刻由 job 层自己记账**。
//
// 归一化层已经诚实地把这个不对称交出来了(`CodexAdapter` 交回 `terminal == nil`,见其文件头与 03 票断言组 1e),
//   本文件是它在**中断路径**上的对应物:把「读到底 / 自己记账」这条姿态选择集中到一处,
//   不让每个调用点各自去记「Claude 要读完、Codex 不用」。

/// 被委托的 agent 家族。rawValue 用小写串(与 6 型消息、终态枚举同款机器面命名),可直接落进 meta.json。
public enum AgentVendor: String, Codable, Sendable, CaseIterable {
    case claude = "claude"
    case codex = "codex"
}

/// 发出终止意图之后,读流的姿态。
public enum AgentDrainPolicy: Sendable, Equatable {
    /// **读到底**:Claude 收到信号后会先补一条 `[Request interrupted by user]`、再落终态 `result`
    /// (`terminal_reason:"aborted_streaming"`)才退出 —— 一发信号就弃管道会丢掉真终态。01 spike 实证。
    case drainToEOF
    /// **发信号那刻自标 aborted**:Codex 被中断 / 硬超时时流里**根本没有终态行**(exec3/exec5 实证),
    /// 再怎么读也读不出终态,只能由 job 层在发信号那刻自己记账。02 spike 实证。
    case markAbortedAtSignal
}

/// 中断姿态与终态收敛的集中处。
public enum AgentInterruptPolicy {
    /// 该 vendor 在发出终止意图后应采取的读流姿态(依据见 `AgentDrainPolicy` 各 case 注释)。
    public static func drainPolicy(for vendor: AgentVendor) -> AgentDrainPolicy {
        switch vendor {
        case .claude: return .drainToEOF
        case .codex: return .markAbortedAtSignal
        }
    }

    /// 把「看门狗判过卡死」这一维合进 job 终态收敛的**薄壳**。
    ///
    /// **它不是第二个 `resolve`**:非 timeout 的每一条判据都原样委托给 `AgentTaskState.resolve`
    /// (04 票的唯一实现),本函数只在最前面加一层 timeout 判定。改 04 那个签名会牵动 04 全部断言,
    /// 故这里包壳而不是加参数(04 的注释也明确把「静默多久」与「执行结束了算什么」分成两件事)。
    ///
    /// 判定顺序,以及每一步为什么在这个位置:
    /// 1. `terminal` 说 **succeeded** → 走 04 的收敛(落 `.completed`)。**timeout 不越过一份有效产出**:
    ///    竞态里 agent 恰好在我们那一刀落地前交出了成功终态,报 `.timeout` 等于把这份结果丢掉 ——
    ///    与 04「terminal 优先于 cancelRequested」是同一个理由(证据 > 我们自己的推测),
    ///    差别只在:`failed` / `aborted` 并不产出任何结果,没有「丢掉产出」的顾虑,故不在豁免之列。
    /// 2. `timedOut` → `.timeout`。此处它必须压过 `terminal == .aborted`、`cancelRequested` 与负退出码:
    ///    这三样在超时路径上**全是我们自己那一刀的回声** —— Claude 侧 drain 读到底拿回的
    ///    `aborted_streaming` 正是我们发的信号造成的,把它记成 `.cancelled` 就抹掉了「是看门狗判的卡死」
    ///    这个唯一有诊断价值的事实(用户会以为是自己点了取消)。
    /// 3. 其余全部原样委托 `AgentTaskState.resolve`(terminal → cancelRequested → 负退出码 → 0/正 → 兜 failed)。
    ///
    /// `timedOut == false` 时本函数与 `AgentTaskState.resolve` **逐值相同**(有断言逐组合钉死):
    /// 薄壳绝不产生第二套判定。
    public static func resolveIncludingTimeout(
        terminal: AgentTerminalStatus?,
        exitCode: Int32?,
        cancelRequested: Bool,
        timedOut: Bool
    ) -> AgentTaskState {
        if timedOut && terminal?.outcome != .succeeded { return .timeout }
        return AgentTaskState.resolve(
            terminal: terminal,
            exitCode: exitCode,
            cancelRequested: cancelRequested
        )
    }
}
