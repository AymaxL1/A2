// AAAgentCore —— 取消 / 超时中断一次运行中的任务(agent-delegation 05 票第 3 条)。
// 依赖边:本文件零 import(只用同模块类型 + stdlib)。模块级红线同 AgentPort.swift。
//
// 本类型**不碰 IO**:它只做三件事 —— 校验状态、迁状态、向端口发终止意图,然后把「接下来该怎么读流」
//   作为返回值交回调用方(`AgentDrainPolicy`)。真正的读流循环在 run 进程那一侧(06/07 票),
//   它自己知道手里的管道;把 drain 塞进这里会让一个纯逻辑类型长出一条 IO 尾巴,也就没法在 FakeAgentPort 上测了。

/// 取消 / 超时中断的失败原因。
public enum AgentCancellationError: Error, Equatable {
    /// 对一个**不是 running** 的任务发中断(已终态 / 还 pending)。携带当时的状态,便于调用方如实报错。
    case notRunning(AgentTaskState)
}

/// 取消一次运行中的任务(以及看门狗判卡死后的同款终止路径)。
public enum AgentCancellation {
    /// 用户取消:校验状态 → 迁 `cancelled` → 向端口发终止意图 → 交回该 vendor 的 drain 姿态。
    ///
    /// 非 `running` 一律抛 `notRunning`,且**绝不**调用 `port.terminate`:
    ///   对一个已终态(或还没拉起)的任务发取消,是调用方的状态没理清 —— 让它响,
    ///   而不是静默地变成一次真杀。**「既报错又已经把进程杀了」是最坏的一种实现**:
    ///   调用方看到错误以为什么都没发生,实际上句柄对应的进程已经死了(而那个句柄在 pending 态下
    ///   往往属于**别的**任务或早已回收 —— 真实现里句柄 id 会复用)。这条有断言把关(terminateCalls 保持为空)。
    ///
    /// **`pending` 也走抛错这一支**,虽然 `pending → cancelled` 在状态机里是合法迁移:
    ///   那条边是给「还没拉起就被取消」用的,那条路上根本没有进程、没有句柄,
    ///   由调用方直接 `updateMeta` 迁 `cancelled` 即可,不该借道一个要求交出句柄的函数。
    public static func cancel(
        state: inout AgentTaskState,
        handle: AgentProcessHandle,
        port: AgentPort,
        vendor: AgentVendor
    ) throws -> AgentDrainPolicy {
        try interrupt(state: &state, to: .cancelled, handle: handle, port: port, vendor: vendor)
    }

    /// 看门狗判卡死后的终止:与 `cancel` 同款顺序与同款校验,只是状态落点是 `timeout` 而非 `cancelled`。
    ///
    /// 两个落点必须分开,不能都记成 `cancelled`:`cancelled` 是「用户点的」、`timeout` 是「平台判的」,
    ///   混成一个值,用户就再也分不清一个任务是自己取消的还是被看门狗杀的
    ///   (04 的 `AgentTaskState` 注释也把 `timeout` 明确划给看门狗:它不来自 adapter)。
    public static func timeOut(
        state: inout AgentTaskState,
        handle: AgentProcessHandle,
        port: AgentPort,
        vendor: AgentVendor
    ) throws -> AgentDrainPolicy {
        try interrupt(state: &state, to: .timeout, handle: handle, port: port, vendor: vendor)
    }

    // MARK: - 内部

    /// 中断的共同骨架。**顺序是本函数唯一的实质内容,不可颠倒**:
    ///
    ///   ① 校验(非 running 立刻抛,此时一个副作用都还没发生)
    ///   → ② **先迁状态**
    ///   → ③ **再发终止意图**
    ///
    /// 为什么先迁状态再发信号:反过来会存在一个「信号已经发出去、状态里还写着 running」的窗口。
    ///   先迁状态则最坏只剩「状态已是 cancelled 但进程还活着」,那由 `terminate` 的幂等契约兜底
    ///   (重发一次终止即可,`AgentPort.terminate` 对已死 / 未知句柄是 no-op)——**这一侧的残留是可修的**。
    ///
    /// **但本函数只保证「值序」,保证不了「盘序」(两轴 CR 纠正的一处超售)**:这里的 `state` 是内存里的 `inout` 值,
    ///   `meta.json` 的持久化发生在**调用方**、在本函数返回之后 —— 无论 ②③ 在函数内怎么排,信号发出的那一刻
    ///   磁盘上的 meta 都还是 `running`。(何况 `inout` 是 copy-in/copy-out 语义,函数内的赋值顺序对外原则上不可观测。)
    ///   真正封住「宿主在窗口里崩掉 → 残留扫描把我们自己动手的取消误判成 `orphaned`」的,必须是**调用方**
    ///   「先落盘再发信号」的顺序 —— 该义务归 06/07 接线。所幸即便真落进这个窗口也不是死局:
    ///   04 票已放行 `orphaned → 证据终态`(单向),run 进程回来照样能用一手证据把推测纠正回来。
    private static func interrupt(
        state: inout AgentTaskState,
        to next: AgentTaskState,
        handle: AgentProcessHandle,
        port: AgentPort,
        vendor: AgentVendor
    ) throws -> AgentDrainPolicy {
        // ① 只有 running 可中断;顺带过一遍 04 的迁移表(双保险:将来若迁移表收紧,这里跟着收紧)。
        guard state == .running, state.canTransition(to: next) else {
            throw AgentCancellationError.notRunning(state)
        }
        // ② 先迁状态(见上文:只保证值序;盘序是调用方的义务)。
        state = next
        // ③ 再发终止意图(幂等;真实现走进程组 SIGTERM → 宽限 → SIGKILL,反孤儿归 06 票)。
        port.terminate(handle)
        // ④ 交回该 vendor 的读流姿态,由调用方决定是把管道读到底还是就地记账。
        return AgentInterruptPolicy.drainPolicy(for: vendor)
    }
}
