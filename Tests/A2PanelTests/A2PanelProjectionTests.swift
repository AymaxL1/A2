// 10 票:**事件投影**的纯逻辑断言 —— 「subscriber 投影驱动菜单」这条验收的可机读形态。
//
// 缝在 `A2PanelProjection`(纯函数:快照 → 状态;事件 → 状态 + 该做的事)。
// 真事件流那一关归旗舰 e2e(真内核推真事件);这里验的是**收到某一族事件之后壳打算干什么**,
// 那件事真内核构造不出全部分支(比如「确认在途时对端断了」要精确编排两条连接的时序)。

import Testing
import A2Contract
import A2Panel
import A2PanelFixtures

@Suite("10 事件投影(快照即基线 + 八族增量 + 断线即离场)")
struct A2PanelProjectionTests {

    // ---- 装置 ----

    private static let status = A2StatusResult(
        version: "0.1.0", pid: 4242, startedAt: "2026-08-05T04:00:00.000Z", uptimeMs: 600_000,
        home: "/tmp/a2home", socketPath: "/tmp/a2home/run/kernel.sock")

    private static func arbitration(pending: [A2PendingConfirmation] = [],
                                    confirmers: Int = 1) -> A2ArbitrationState {
        A2ArbitrationState(confirmerPresent: confirmers > 0, confirmers: confirmers,
                           subscribers: 0, timeoutMs: 120_000, pending: pending)
    }

    private static func supervision(events: [A2ProxySupervisionEvent] = []) -> A2ProxySupervisionResult {
        A2ProxySupervisionResult(
            watching: true, intervalMs: 200, checks: 3,
            target: A2ProxyEndpoint(owner: .a2, controller: "127.0.0.1:19090", managed: true),
            alive: true, lastCheckAt: "2026-08-05T04:05:00.000Z",
            lastTransitionAt: "2026-08-05T04:01:00.000Z",
            logPath: "/tmp/a2home/log/proxy-supervision.log", events: events)
    }

    private static func snapshot(pending: [A2PendingConfirmation] = [],
                                audit: [A2AuditEvent] = [],
                                fallbackBrowser: String = "com.google.Chrome") -> A2KernelSnapshot {
        A2KernelSnapshot(status: status, capabilities: A2PanelFixtures.capabilities,
                         arbitration: arbitration(pending: pending), supervision: supervision(),
                         audit: audit,
                         // 有意**不写 Safari**:兜底身份必须是快照里那一份,不是壳的缺省
                         // ——把缺省写死在投影路径上的话,这条断言会当场红(03 票)。
                         urlRouter: A2URLRouterSnapshot(fallbackBrowserBundleID: fallbackBrowser))
    }

    private static let request = A2PanelFixtures.confirmationRequest

    private static func pendingOf(_ request: A2ConfirmationRequest) -> A2PendingConfirmation {
        A2PendingConfirmation(id: request.id, capability: request.capability, risk: .dangerous,
                              requestedAt: request.requestedAt, expiresAt: request.expiresAt)
    }

    // ========================================================================
    // 基线
    // ========================================================================

    @Test("10 快照即基线:能力/仲裁/监督/审计一次到位,代理域留空等第一次读")
    func snapshotIsTheBaseline() {
        let state = A2PanelProjection.base(from: Self.snapshot(audit: [
            A2AuditEvent(at: "2026-08-05T04:00:01.000Z", action: .confirmerJoined)
        ]))
        #expect(state.connection == .connected)
        #expect(state.capabilities.count == A2PanelFixtures.capabilities.count)
        #expect(state.arbitration?.confirmerPresent == true)
        #expect(state.supervision?.watching == true)
        #expect(state.audit.count == 1)
        // 代理域**不在快照里**(契约头注写明:那要问 external-controller),所以基线是空的 ——
        //   壳随后调三条 safe 能力读一次。这条断言钉住「不臆造」这件事。
        #expect(state.proxy == A2ProxyView())
        #expect(state.pendingConfirmations.isEmpty)
    }

    @Test("10 快照即基线:不去重、不二次核对 —— 计数直接取内核给的那份")
    func snapshotCountsAreTakenAsIs() {
        // 09 票交接单第 ② 条:快照里的 arbitration 计数**已经含这条连接自己**,
        //   内核不会再把自己的 confirmer_joined 推给它。壳不该做任何"扣掉自己"的算术。
        let state = A2PanelProjection.base(from: Self.snapshot())
        #expect(state.arbitration?.confirmers == 1)
    }

    // ========================================================================
    // 六族增量
    // ========================================================================

    @Test("10 confirmation 事件 → 进待办并要求呈现(带 input)")
    func confirmationEventPresents() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        let effect = A2PanelProjection.apply(
            .confirmation(at: "2026-08-05T04:10:00.000Z", request: Self.request), to: &state)
        #expect(state.pendingConfirmations.map(\.id) == [Self.request.id])
        guard case let .presentConfirmation(presented) = effect else {
            Issue.record("应当要求呈现确认,实际 \(effect)"); return
        }
        #expect(presented.input == Self.request.input, "input 必须原样传到呈现层")
    }

    @Test("10 confirmation 事件重复到达不叠窗(幂等)")
    func duplicateConfirmationIsIdempotent() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        _ = A2PanelProjection.apply(.confirmation(at: "t1", request: Self.request), to: &state)
        let second = A2PanelProjection.apply(.confirmation(at: "t2", request: Self.request), to: &state)
        #expect(state.pendingConfirmations.count == 1)
        #expect(second == .none)
    }

    @Test("10 arbitration 事件是权威:内核的 pending 里没有了 → 关掉对应的窗")
    func arbitrationDrivesDismissal() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        _ = A2PanelProjection.apply(.confirmation(at: "t1", request: Self.request), to: &state)
        // 内核那侧收场了(批准/拒绝/超时/降级/取消都会走到这条)。
        let effect = A2PanelProjection.apply(
            .arbitration(at: "t2", state: Self.arbitration(pending: [])), to: &state)
        #expect(effect == .dismissConfirmations([Self.request.id]))
        #expect(state.pendingConfirmations.isEmpty,
                "内核说它不在途了,壳手里那条就必须消失 —— 否则用户会对着一条早已作废的请求点批准")
    }

    @Test("10 arbitration 事件里那条还在 → 不关窗、不重复呈现")
    func arbitrationKeepsLivePending() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        _ = A2PanelProjection.apply(.confirmation(at: "t1", request: Self.request), to: &state)
        let effect = A2PanelProjection.apply(
            .arbitration(at: "t2", state: Self.arbitration(pending: [Self.pendingOf(Self.request)])),
            to: &state)
        #expect(effect == .none)
        #expect(state.pendingConfirmations.count == 1)
    }

    @Test("10 arbitration 事件:确认器归零如实反映(dangerous 会降回默拒)")
    func arbitrationReflectsConfirmerLoss() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        _ = A2PanelProjection.apply(
            .arbitration(at: "t2", state: Self.arbitration(confirmers: 0)), to: &state)
        #expect(state.arbitration?.confirmerPresent == false)
        let menu = A2MenuModelBuilder.build(state: state)
        #expect(menu.flattened.contains { $0.title.contains("确认器:不在场") },
                "菜单要如实说出「此刻 dangerous 一律默拒」")
    }

    @Test("10 confirmation-pending 事件不改状态(那是发起方的事,不是确认器的)")
    func confirmationPendingIsInert() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        let before = state
        let effect = A2PanelProjection.apply(
            .confirmationPending(at: "t", requestId: "req-1", timeoutMs: 120_000,
                                 confirmation: Self.pendingOf(Self.request)),
            to: &state)
        #expect(effect == .none)
        #expect(state == before)
    }

    @Test("10 audit 事件叠加并按窗口截断(壳不做日志,只做「最近发生了什么」)")
    func auditAccumulatesWithinWindow() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        for i in 0..<(A2PanelState.auditWindow + 5) {
            _ = A2PanelProjection.apply(
                .audit(at: "t\(i)", audit: A2AuditEvent(at: "t\(i)", action: .requested)), to: &state)
        }
        #expect(state.audit.count == A2PanelState.auditWindow)
        #expect(state.audit.last?.at == "t\(A2PanelState.auditWindow + 4)")
    }

    @Test("10 supervision 事件:up/down 改可达性并触发一次代理域重读")
    func supervisionEventUpdatesLiveness() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        let down = A2ProxySupervisionEvent(
            at: "2026-08-05T04:20:00.000Z", kind: .instanceDown, controller: "127.0.0.1:19090",
            owner: .a2, detail: "REST 不可达")
        let effect = A2PanelProjection.apply(.supervision(at: "t", supervision: down), to: &state)
        #expect(effect == .refreshProxy)
        #expect(state.supervision?.alive == false)
        #expect(state.supervision?.lastTransitionAt == down.at)
        #expect(state.supervision?.events.last == down)
    }

    @Test("10 capability 事件:proxy 域触发重读,别的域不白跑")
    func capabilityEventRefreshesOnlyProxy() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        let proxyEvent = A2CapabilityEvent(capability: "proxy.mode.set", risk: .normal,
                                           output: .object(["mode": .string("global")]))
        #expect(A2PanelProjection.apply(.capability(at: "t", capability: proxyEvent), to: &state)
                == .refreshProxy)
        let otherEvent = A2CapabilityEvent(capability: "demo.note.set", risk: .normal,
                                           output: .object(["key": .string("k")]))
        #expect(A2PanelProjection.apply(.capability(at: "t", capability: otherEvent), to: &state)
                == .none)
    }

    @Test("10 capability 事件不被壳自己解读:本地状态一个字段都没动")
    func capabilityEventDoesNotMutateLocally() {
        // 红线:把 `SubscriptionChangeResult` 叠进本地清单需要复制订阅域的业务语义(ADR 0008 第 5 条明禁)。
        //   壳只知道「该重读了」,语义永远只有内核一份。
        var state = A2PanelProjection.base(from: Self.snapshot())
        state.proxy = A2PanelFixtures.activeSubscription.state.proxy
        let before = state.proxy
        let event = A2CapabilityEvent(
            capability: "proxy.subscription.remove", risk: .dangerous,
            output: .object(["id": .string("sub-jichang-a-1a2b3c"), "action": .string("removed")]))
        _ = A2PanelProjection.apply(.capability(at: "t", capability: event), to: &state)
        #expect(state.proxy == before,
                "壳不许自己去删本地那一条 —— 它只该重读,然后照内核给的清单显示")
    }

    @Test("11 capability-set 事件:能力全集整份替换,但菜单不因此多出一项")
    func capabilitySetEventReplacesTheWholeTable() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        let before = state.capabilities
        let plugged = A2CapabilityDescriptor(
            id: "plugin.hello.greet", risk: .normal, summary: "打个招呼", parameters: [])
        let event = A2CapabilitySetEvent(
            action: .added, plugin: "hello", added: [plugged], removed: [],
            capabilities: before + [plugged])

        let effect = A2PanelProjection.apply(.capabilitySet(at: "t", capabilities: event), to: &state)

        // 整份替换:客户端不做加减法(内核已经算好了全集)。
        #expect(state.capabilities == before + [plugged])
        // 没有额外效应:插件能力**不进菜单**(菜单只投影 proxy.*,由另一条断言钉着)。
        #expect(effect == .none)
    }

    // ========================================================================
    // 断线
    // ========================================================================

    @Test("10 断线即离场:待办清空(在途请求可能已被降级/取消),但最后看到的状态如实留着")
    func disconnectClearsPendingButKeepsLastKnown() {
        var state = A2PanelProjection.base(from: Self.snapshot())
        _ = A2PanelProjection.apply(.confirmation(at: "t1", request: Self.request), to: &state)
        state.proxy = A2PanelFixtures.mihomoRunning.state.proxy
        A2PanelProjection.disconnect(&state, reason: "内核关闭了连接")
        #expect(state.pendingConfirmations.isEmpty,
                "重连要重新注册并以内核的 arbitration 为准 —— 旧待办一条都不能留")
        #expect(state.connection == .disconnected("内核关闭了连接"))
        #expect(state.proxy.kernelRunning, "最后看到的代理状态留着(菜单会标明它已过时)")
    }
}
