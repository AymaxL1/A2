// A2Panel —— **投影**:快照当基线,增量事件叠上去(10 票)。
//
// ============================================================================
// 记账口径(09 票交接单第 ② 条,一字不改地执行)
// ============================================================================
// **快照即基线,别自己去重**:`roles.register` 的响应是这条连接的第一帧;快照里的 `arbitration`
//   计数**已经含这条连接自己**,内核**不会**再把自己的 `confirmer_joined` 推给它。
//   所以壳的算法就是最简单那种:快照当初值,之后每条事件直接叠上去。
//
// **断线即离场,没有重连恢复会话**:重连要重新 `roles.register`,并以内核推来的 `arbitration`
//   事件为准刷新待办 —— 在途请求可能在断线期间已被降级/取消。故 `disconnect()` 会把
//   待办清空:壳绝不留着一份可能已经作废的「待人拍板」清单。
//
// 本文件是**纯函数**(除了 `inout` 的状态本身,不碰任何 I/O),所以「事件流 → 菜单」这条链
// 在 `swift test` 里可以逐族喂事件、逐条断言,不必起任何进程。

import A2Contract

/// 投影一条事件之后,**壳应当去做的事**。
///
/// 为什么要有这个返回值:有些事件的后果不是「改一个字段」,而是「去重读某一族」或「弹一个窗」。
/// 把它做成**数据**而不是回调,纯逻辑测试才验得到「收到这条事件之后壳打算干什么」。
public enum A2PanelEffect: Sendable, Equatable {
    /// 什么都不用做(状态已就地更新)。
    case none
    /// 代理域被改动了 —— 重读那三条 safe 能力。**这不是轮询**:没有定时器,
    /// 读只发生在内核明说「有人改了状态」的那一刻。
    case refreshProxy
    /// 有一条 dangerous 请求要人拍板 —— 呈现确认器界面(**必须原样展示 input**)。
    case presentConfirmation(A2ConfirmationRequest)
    /// 某条在途确认已经收场(批准/拒绝/超时/降级/取消)—— 关掉对应的界面。
    case dismissConfirmations([String])
}

public enum A2PanelProjection {

    // ========================================================================
    // 基线
    // ========================================================================

    /// 快照 → 状态(注册那一次往返的产物)。
    public static func base(from snapshot: A2KernelSnapshot) -> A2PanelState {
        A2PanelState(
            connection: .connected,
            kernelStatus: snapshot.status,
            capabilities: snapshot.capabilities,
            arbitration: snapshot.arbitration,
            supervision: snapshot.supervision,
            proxy: A2ProxyView(),
            pendingConfirmations: [],
            audit: Array(snapshot.audit.suffix(A2PanelState.auditWindow)))
    }

    /// 断连:保留「最后看到的样子」供菜单如实呈现,但**清空待办**(见文件头「断线即离场」)。
    public static func disconnect(_ state: inout A2PanelState, reason: String) {
        state.connection = .disconnected(reason)
        state.pendingConfirmations = []
    }

    // ========================================================================
    // 增量
    // ========================================================================

    /// 叠加一条推送事件,返回壳该做的事。
    ///
    /// 七族全部有分支,**一族都不许默默吞掉** —— 未知族在解码层就已经被拒
    /// (`A2KernelEvent` 的 `kind` 是封闭词表,有 invalid 金标守着),所以这里的 switch 是穷尽的。
    public static func apply(_ event: A2KernelEvent, to state: inout A2PanelState) -> A2PanelEffect {
        switch event {
        case let .arbitration(_, arbitration):
            let before = Set(state.pendingConfirmations.map(\.id))
            let after = Set(arbitration.pending.map(\.id))
            state.arbitration = arbitration
            // 内核那份 `pending` 是**权威**:壳手里那条若已不在其中,说明它已经收场了
            //   (批准/拒绝/超时/降级/取消都会走到这里),界面必须跟着关 —— 否则用户会对着
            //   一条早已作废的请求点「批准」,而那次点击只会换回一句 `unknown_confirmation`。
            let gone = before.subtracting(after)
            if gone.isEmpty { return .none }
            state.pendingConfirmations.removeAll { gone.contains($0.id) }
            return .dismissConfirmations(gone.sorted())

        case let .confirmation(_, request):
            // 重复推同一条(理论上不会,但客户端不该因此叠出两个窗)。
            if state.pendingConfirmations.contains(where: { $0.id == request.id }) { return .none }
            state.pendingConfirmations.append(request)
            return .presentConfirmation(request)

        case .confirmationPending:
            // 「我把你这条转给人了」—— **只推给发起方**。壳作为确认器不会收到指向自己的这一帧;
            //   万一收到(壳自己也发起了一条 dangerous 调用),那是那次调用的等待逻辑在管,
            //   与菜单状态无关。如实不改状态。
            return .none

        case let .audit(_, audit):
            state.audit.append(audit)
            if state.audit.count > A2PanelState.auditWindow {
                state.audit.removeFirst(state.audit.count - A2PanelState.auditWindow)
            }
            return .none

        case let .supervision(_, supervisionEvent):
            // 观测事件只更新「最近事件」那一段:`A2ProxySupervisionResult` 的其余字段
            //   (watching / intervalMs / checks / target …)是**内核的进程内计数**,
            //   壳无从推算,也不该猜。整份 result 只在快照/重连时刷新。
            if var current = state.supervision {
                var events = current.events
                events.append(supervisionEvent)
                if events.count > A2PanelState.auditWindow {
                    events.removeFirst(events.count - A2PanelState.auditWindow)
                }
                current = A2ProxySupervisionResult(
                    watching: current.watching, intervalMs: current.intervalMs, checks: current.checks,
                    target: current.target,
                    // 只有这两条能从事件本身如实推出来:up/down 就是可达性本身。
                    alive: supervisionEvent.kind == .instanceUp ? true
                        : (supervisionEvent.kind == .instanceDown ? false : current.alive),
                    lastCheckAt: supervisionEvent.at,
                    lastTransitionAt: (supervisionEvent.kind == .instanceUp
                                       || supervisionEvent.kind == .instanceDown)
                        ? supervisionEvent.at : current.lastTransitionAt,
                    logPath: current.logPath, events: events)
                state.supervision = current
            }
            // mihomo 起落会改变「内核在不在」这条菜单事实 —— 重读一次代理域。
            return .refreshProxy

        case let .capability(_, capabilityEvent):
            // **只对代理域重读**:内核只对 normal/dangerous 发这一族,而壳的菜单只投影 `proxy.*`。
            //   别的域(插件能力)改了状态与本菜单无关,不必白跑一趟。
            return capabilityEvent.capability.hasPrefix("proxy.") ? .refreshProxy : .none

        case let .capabilitySet(_, change):
            // 能力全集变了(agent 装/卸了一个插件,11 票)。壳**整份替换**自己那张表 ——
            //   载荷里带的就是变化后的全集,不必按 added/removed 做加减法(那是内核已经算好的账)。
            //
            //   **菜单不会因此多出一项**:菜单只投影 `proxy.*`(有断言钉着),插件能力要进菜单
            //   得是壳的一次显式改动。但这张表还是要跟上 —— 确认器呈现 dangerous 请求时
            //   要按 id 找 manifest,而插件工具**照样会走仲裁**(它与内置能力是同一种东西)。
            state.capabilities = change.capabilities
            return .none
        }
    }
}
