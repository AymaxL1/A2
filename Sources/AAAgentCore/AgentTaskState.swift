// AAAgentCore —— 委托任务的 **job 级**状态机(与 adapter 级终态 `AgentTerminalOutcome` 是两件事)。
// 依赖边:本文件零 import(纯 stdlib 类型)。
//
// 两级状态别混(`AgentTerminalStatus.swift` 文件头已从另一侧写过一遍,这里给出**代码化**的映射):
//   * adapter 级(`AgentTerminalOutcome`,三值)只回答「agent 自己的事件流说这次执行怎么结束的」;
//   * job 级(本枚举,七值)还要回答「进程死没死、静默多久、用户点没点取消、宿主崩过没有」——
//     这些信息 agent 的事件流里**根本没有**,故 `timeout` / `orphaned` 绝不来自 adapter:
//     `timeout` 由看门狗(05 票)判、`orphaned` 由残留扫描(本票 `AgentTaskWorkspace.scanForOrphans`)判。
//
// **一条实证约束(03 票 CR 回填,状态机不得违背)**:Codex 的 `item.*` 事件**不保证被 turn 边界包住** ——
//   02 spike 的 exec6 样本里 `item.completed`(type=error)出现在 `turn.started` **之前**,exec7 里 item error
//   夹在回合中段的重连噪音之间。故本状态机**不拿 turn 边界当闸门**:它压根不消费 turn 事件,
//   状态只由「拉起 / 终态解析 / 退出码 / 探活」四类事实驱动;消息落盘(`AgentTaskWorkspace.appendNormalized`)
//   同样全量照收、不按 turn 边界过滤(丢 pre-turn 的 item 就是丢诊断信息)。

/// 委托任务的 job 级状态(七值,穷尽)。rawValue 用小写串(与 6 型消息、终态枚举同款机器面命名),
/// 直接落进 meta.json 的 `state` 字段。
public enum AgentTaskState: String, Codable, Sendable, CaseIterable {
    /// 已创建工作区、尚未拉起 agent 进程。
    case pending = "pending"
    /// agent 进程已拉起、正在跑。
    case running = "running"
    /// 正常完成(adapter 终态 `.succeeded` 的落点)。
    case completed = "completed"
    /// 失败(adapter 终态 `.failed`,或 terminal 缺失时正退出码的落点)。
    case failed = "failed"
    /// 被取消(adapter 终态 `.aborted`,或 terminal 缺失时「负退出码 = 被信号杀」/ 收到取消意图的落点)。
    case cancelled = "cancelled"
    /// 看门狗判定的静默超时(05 票;**不来自 adapter**)。
    case timeout = "timeout"
    /// 崩溃残留:meta 记着 `running` 但 pid 已死(**不来自 adapter**;由残留扫描判出,证据一律保留)。
    case orphaned = "orphaned"

    /// 是否终态。`pending` / `running` 之外全是终态 —— 用「反过来列举活态」而不是列举五个终态,
    /// 是为了将来若真要加第八个状态,漏改这里的概率更低(新状态默认被当成终态,是 fail-closed 的那一侧)。
    public var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        case .completed, .failed, .cancelled, .timeout, .orphaned: return true
        }
    }

    /// 本状态能否迁到 `next`。**其余一律非法**,由 `AgentTaskWorkspace.updateMeta` 抛错拦下(不静默改写)。
    ///
    /// - `pending` → `running`(拉起成功)/ `failed`(拉起就失败)/ `cancelled`(还没拉起就被取消);
    /// - `running` → `completed` / `failed` / `cancelled` / `timeout` / `orphaned`;
    /// - `orphaned` → `completed` / `failed` / `cancelled` / `timeout`(**唯一一条终态出边**,见下);
    /// - 其余四个终态 → 无。**含终态→自身**:终态是一次性的,「再确认一遍」这种写法多半是调用方状态没理清,
    ///   与其容忍不如让它响。
    ///
    /// **为什么只有 `orphaned` 有出边(证据可以纠正推测,反过来不行)**:
    ///   `orphaned` 不是任何人报上来的事实,而是残留扫描**按「meta 记着 running 但 pid 已死」猜出来的**
    ///   推测性终态 —— 它的判据里没有一个字来自 agent 自己或 run 进程。而 `finish` 手里的是**一手证据**:
    ///   run 进程亲眼看着子进程退出、把事件流读到底、拿到了退出码与终态行。
    ///
    ///   真实失败时序(两轴 CR 独立收敛到的同一条):agent 子进程退出 → run 进程还在 drain 读到底(可达秒级)
    ///   → 另一个终端跑 `list` 触发 `scanForOrphans` → 看到 running + pid 已死 → 标 `orphaned` → run 进程随后
    ///   `finish(.completed)`。若 `orphaned` 零出边,一次**成功**的任务就被永久记成孤儿、报告缺失,
    ///   且没有任何纠正路径 —— 那等于把一个猜测冻成不可反证的结论。
    ///
    ///   方向是**单向**的:证据可以覆盖推测,推测绝不能退回证据 —— `completed/failed/cancelled/timeout → orphaned`
    ///   仍然非法(否则一次迟到的扫描就能把已经收好的终态改成孤儿)。
    public func canTransition(to next: AgentTaskState) -> Bool {
        switch self {
        case .pending:
            return next == .running || next == .failed || next == .cancelled
        case .running:
            return next == .completed || next == .failed || next == .cancelled
                || next == .timeout || next == .orphaned
        case .orphaned:
            // 单向的证据升级:只放行「推测 → 证据」,不放行迁回自身(重复标记仍是调用方没理清)。
            return next == .completed || next == .failed || next == .cancelled || next == .timeout
        case .completed, .failed, .cancelled, .timeout:
            return false
        }
    }

    /// adapter 级终态 → job 级状态的**唯一**映射表(别在别处再写一份)。
    ///
    /// `.succeeded → .completed` 的命名漂移是刻意的(见 `AgentTerminalStatus` 文件头):
    ///   两级各有自己的词,避免同名值被误当同一个东西。
    public static func from(_ outcome: AgentTerminalOutcome) -> AgentTaskState {
        switch outcome {
        case .succeeded: return .completed
        case .failed: return .failed
        case .aborted: return .cancelled
        }
    }

    /// 收敛一次执行的 job 终态。**「adapter 没给终态」绝不能让任务永远挂在 running** ——
    /// 这条是 02 spike 逼出来的:Codex 被中断 / 硬超时时事件流里**根本没有终态行**(exec3/exec5 实证),
    /// adapter 会诚实交回 `terminal == nil`。此时判据只剩进程退出码与是否收到过取消意图:
    ///
    /// 1. `terminal` 非 nil → 走上面的映射表(agent 自己说了话,以它为准);
    /// 2. 收到过取消意图 → `.cancelled`(是我们自己动的手,退出码怎样都不改变这个事实);
    /// 3. 退出码为负 → `.cancelled`(负值 = 被信号杀,`-SIGTERM` / `-SIGKILL`);
    /// 4. 退出码 0 → `.completed`;正数 → `.failed`;
    /// 5. 退出码**未知**(进程状态都拿不到)→ `.failed` —— fail-closed:宁可把成功误报为失败(上层重试 / 告警),
    ///    也绝不把失败误报为成功,更不留在 running 让任务永远悬着。
    ///
    /// 注意 `timeout` 不在本函数的值域:超时是看门狗按「静默多久」判的(05 票),
    /// 它有自己的判据与自己的迁移调用,不该混进这条「执行已经结束了,那结果算什么」的收敛路径。
    public static func resolve(
        terminal: AgentTerminalStatus?,
        exitCode: Int32?,
        cancelRequested: Bool
    ) -> AgentTaskState {
        if let outcome = terminal?.outcome { return from(outcome) }
        if cancelRequested { return .cancelled }
        guard let code = exitCode else { return .failed }
        if code < 0 { return .cancelled }
        return code == 0 ? .completed : .failed
    }
}
