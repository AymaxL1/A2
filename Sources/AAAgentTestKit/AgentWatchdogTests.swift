// AAAgentTestKit —— 消息静默看门狗 + 取消语义的纯逻辑测试(agent-delegation 05)。
// 依赖边:AAAgentTestKit → AAAgentCore、AAContracts(+ 系统 Foundation)。
//
// **全票零真实等待、零真进程**:时间一律由测试自己喂 epoch 秒(生产侧由 `AgentClockPort` 注入),
//   进程一律是 `FakeAgentPort`。本套件里任何一处 `sleep` / 真实计时 / `Date()` 都是 bug ——
//   门禁必须毫秒级跑完。
//
// 覆盖的七件事(与票面 5 条 checkbox 逐条对齐):
//   ① 默认阈值有实证依据(两处 spike 的数量级);
//   ② 静默超阈判 stalled,**边界严格大于**(差 1 秒 / 恰好等于阈值都仍 healthy);
//   ③ 工具在途放宽不误杀(含 Codex 实测 40+ 秒重连链路的具名断言);
//   ④ 工具闭合后阈值**动态**退回 idle 档(不是一旦有过工具就永久放宽);
//   ⑤ 畸形消息:callID 为 nil/空的 tool-use 不进在途集合、没配上的 tool-result 不减到负数;
//   ⑥ 取消 / 超时中断:running → 迁 cancelled·timeout + 终止调用被记到;
//      **非 running 抛错且 terminateCalls 保持为空**(绝不既报错又已经把进程杀了);
//   ⑦ 两家中断姿态收敛(Claude drainToEOF / Codex markAbortedAtSignal)+ 终态收敛五步顺序逐条钉死,
//      含 timeout 合流点(timedOut 压过 cancelRequested 与 aborted 回声,但不压过一份成功产出)。
//
// 说明:本套件由 check.sh 动态生成的 runner 执行,打印 report.lines;各描述串是 check.sh 阶段 B
//   assert_contains 的定长子串目标,**不得随意改字**(改则同步改 check.sh 断言组 1g)。

import Foundation
import AAContracts
import AAAgentCore

/// 看门狗 + 取消语义的纯逻辑测试。
public enum AgentWatchdogTests {
    /// 全套断言共用的起跑时刻(一个普通的 epoch 秒,数值本身无意义 —— 重要的只有差值)。
    private static let t0 = 1_785_508_320

    public static func run() -> AgentTestReport {
        var report = AgentTestReport()
        testDefaultPolicyIsEvidenceBacked(&report)
        testClockPortDrivesTheWatchdog(&report)
        testIdleSilenceTriggersStall(&report)
        testToolInFlightRelaxesBudget(&report)
        testToolClosureRestoresIdleBudget(&report)
        testMalformedToolMessages(&report)
        testAnyMessageRefreshesActivity(&report)
        testCancelMovesStateAndTerminates(&report)
        testCancelOnNonRunningThrowsAndNeverTerminates(&report)
        testWatchdogStallDrivesTimeoutTermination(&report)
        testVendorDrainPolicies(&report)
        testTerminalResolutionOrder(&report)
        testTimeoutMergePoint(&report)
        return report
    }

    // MARK: - 助手

    /// 造一个 running 的假进程句柄(端口 + 句柄一起交回,便于逐条断言 terminateCalls)。
    private static func makeLaunched() -> (FakeAgentPort, AgentProcessHandle)? {
        let port = FakeAgentPort()
        let spec = AgentLaunchSpec(
            executablePath: "/usr/local/bin/claude",
            arguments: ["-p", "--output-format", "stream-json"],
            environment: [:],
            workingDirectory: "/fake/agent-tasks/t1/work",
            stdin: .writeThenKeepOpen(#"{"prompt":"hi"}"#)
        )
        guard let handle = try? port.launch(spec) else { return nil }
        return (port, handle)
    }

    private static func isHealthy(_ verdict: AgentWatchdogVerdict) -> Bool {
        verdict == .healthy
    }

    // MARK: - ① 默认阈值的实证依据

    private static func testDefaultPolicyIsEvidenceBacked(_ report: inout AgentTestReport) {
        let p = AgentWatchdogPolicy.default
        report.check(p.idleTimeoutSeconds == 120,
                     "看门狗:默认 idle 阈值为 120 秒(覆盖 Codex exec3 实测 90 秒硬超时窗口,findings 意外发现 2 的 60-90 秒余量)")
        report.check(p.toolInFlightTimeoutSeconds == 900,
                     "看门狗:默认工具在途阈值为 900 秒(长跑工具 + Claude api_retry 指数退避都不误杀)")
        report.check(p.toolInFlightTimeoutSeconds > p.idleTimeoutSeconds,
                     "看门狗:工具在途阈值严格大于 idle 阈值(放宽档必须真的更宽)")
        // 阈值可配是票面明写的要求(07 票 CLI 要能覆盖),故非默认值必须原样生效。
        let custom = AgentWatchdogPolicy(idleTimeoutSeconds: 7, toolInFlightTimeoutSeconds: 11)
        var w = AgentWatchdog(policy: custom, startedAt: t0)
        w.observe(.text("hello"), at: t0)
        report.check(w.currentTimeoutSeconds == 7 && isHealthy(w.verdict(at: t0 + 7)) && !isHealthy(w.verdict(at: t0 + 8)),
                     "看门狗:自定义阈值原样生效(阈值可配,默认值不是写死的)")
    }

    // MARK: - ①b 时间确实来自 ClockPort(票面第 1 条「以 ClockPort 驱动」的生产接线形状)

    /// 上面各组为了把秒数摆在断言里看得见,直接喂 epoch 整数;本组补一条**端到端经 `AgentClockPort`** 的,
    /// 证明生产侧的接线形状成立:秒数从 `clock.now().epochSeconds` 来,看门狗一个字都不读系统时钟。
    /// `FakeClock` 弹完停在最后一格(其自身契约),故这里按需精确编三格。
    private static func testClockPortDrivesTheWatchdog(_ report: inout AgentTestReport) {
        let clock: AgentClockPort = FakeClock([
            // 注:stamp/iso8601 只是**惰性占位**(本用例没有任何断言读它们),但仍与 `t0` 的真实换算对齐 ——
            //   本套件自己的标准是「数字要有实证」,标签与 epoch 对不上会误导后来者。t0 = 2026-07-31T14:32:00Z。
            AgentWallClock(stamp: "20260731-1432", iso8601: "2026-07-31T14:32:00Z", epochSeconds: t0),
            AgentWallClock(stamp: "20260731-1432", iso8601: "2026-07-31T14:32:10Z", epochSeconds: t0 + 10),
            AgentWallClock(stamp: "20260731-1435", iso8601: "2026-07-31T14:35:20Z", epochSeconds: t0 + 200),
        ])
        var w = AgentWatchdog(policy: .default, startedAt: clock.now().epochSeconds)   // 第 1 格:拉起时刻
        w.observe(.text("working"), at: clock.now().epochSeconds)                      // 第 2 格:一条消息
        let verdict = w.verdict(at: clock.now().epochSeconds)                          // 第 3 格:190 秒后
        report.check(verdict == .stalled(silentSeconds: 190, toolInFlight: false),
                     "看门狗:整条判决链路的时间全部取自 AgentClockPort(经 FakeClock 喂,零真实时钟、零真实等待)")
        report.check((clock as? FakeClock)?.callCount() == 3,
                     "看门狗:时钟端口恰被取用三次(拉起/观察/判决各一次,看门狗自己一个字都不读系统时钟)")
    }

    // MARK: - ② 静默超时触发(边界严格大于)

    private static func testIdleSilenceTriggersStall(_ report: inout AgentTestReport) {
        let w = AgentWatchdog(policy: .default, startedAt: t0)

        report.check(isHealthy(w.verdict(at: t0)),
                     "看门狗:刚拉起零静默判 healthy")
        report.check(w.toolsInFlight == 0 && w.currentTimeoutSeconds == 120,
                     "看门狗:无工具在途时生效阈值是 idle 档 120 秒")
        report.check(isHealthy(w.verdict(at: t0 + 119)),
                     "看门狗:静默 119 秒(差 1 秒到阈值)仍判 healthy(边界不能松)")
        report.check(isHealthy(w.verdict(at: t0 + 120)),
                     "看门狗:静默恰好等于阈值 120 秒仍判 healthy(判据是严格大于,边界上少杀一秒没人受伤)")
        report.check(w.verdict(at: t0 + 121) == .stalled(silentSeconds: 121, toolInFlight: false),
                     "看门狗:静默 121 秒超过 idle 阈值判 stalled(silentSeconds=121、toolInFlight=false,诊断信息不丢)")
        // Codex 侧最典型的「还在正常重试」窗口:exec3 被本机 90s 硬超时兜底,全程都是重连提示。
        report.check(isHealthy(w.verdict(at: t0 + 90)),
                     "看门狗:idle 档下静默 90 秒仍判 healthy(Codex exec3 实测 90 秒重连窗口不误杀)")
        // 拉起后一条消息都没有,是最典型的卡死 —— 起算点必须是 startedAt,否则这一支永远触发不了。
        report.check(w.lastActivityAt == t0,
                     "看门狗:最后活动时刻的初值是拉起时刻(拉起后一条消息都不吐同样会被判卡死)")
    }

    // MARK: - ③ 工具在途放宽不误杀

    private static func testToolInFlightRelaxesBudget(_ report: inout AgentTestReport) {
        var w = AgentWatchdog(policy: .default, startedAt: t0)
        w.observe(.toolUse(callID: "call_1", tool: "Bash", input: nil), at: t0 + 10)
        let base = t0 + 10

        report.check(w.toolsInFlight == 1 && w.isToolInFlight,
                     "看门狗:tool-use 进入在途集合(toolsInFlight=1)")
        report.check(w.currentTimeoutSeconds == 900,
                     "看门狗:有未闭合工具时生效阈值放宽到 900 秒(idle 档 120 秒不再适用)")
        report.check(isHealthy(w.verdict(at: base + 45)),
                     "看门狗:工具在途静默 45 秒仍判 healthy(Codex 两级传输各 5 次重连实测 40+ 秒,不误杀)")
        report.check(isHealthy(w.verdict(at: base + 300)),
                     "看门狗:工具在途静默 300 秒仍判 healthy(远超 idle 阈值,长跑工具不被误杀)")
        report.check(isHealthy(w.verdict(at: base + 900)),
                     "看门狗:工具在途静默恰好 900 秒仍判 healthy(在途档边界同样是严格大于)")
        report.check(w.verdict(at: base + 901) == .stalled(silentSeconds: 901, toolInFlight: true),
                     "看门狗:工具在途静默 901 秒判 stalled(toolInFlight=true,卡死时有工具在途这条现场信息保住了)")
    }

    // MARK: - ④ 工具闭合后阈值动态收回

    private static func testToolClosureRestoresIdleBudget(_ report: inout AgentTestReport) {
        var w = AgentWatchdog(policy: .default, startedAt: t0)
        w.observe(.toolUse(callID: "call_1", tool: "Bash", input: nil), at: t0 + 10)
        // 闭合前:同样的 121 秒静默是 healthy(在途档 900 秒)。
        report.check(isHealthy(w.verdict(at: t0 + 10 + 121)),
                     "看门狗:工具闭合前静默 121 秒判 healthy(在途档生效)")

        w.observe(.toolResult(callID: "call_1", output: nil, isError: false), at: t0 + 500)
        report.check(w.toolsInFlight == 0 && !w.isToolInFlight,
                     "看门狗:同 callID 的 tool-result 到达后在途集合清空(toolsInFlight=0)")
        report.check(w.currentTimeoutSeconds == 120,
                     "看门狗:工具闭合后阈值退回 idle 档 120 秒(放宽是动态的,不是一旦有过工具就永久放宽)")
        report.check(w.verdict(at: t0 + 500 + 121) == .stalled(silentSeconds: 121, toolInFlight: false),
                     "看门狗:工具闭合后静默 121 秒即判 stalled(闭合前同样的 121 秒还是 healthy)")

        // 嵌套/并发工具:闭合其一不代表可以收回预算。
        var m = AgentWatchdog(policy: .default, startedAt: t0)
        m.observe(.toolUse(callID: "call_a", tool: "Read", input: nil), at: t0 + 1)
        m.observe(.toolUse(callID: "call_b", tool: "Bash", input: nil), at: t0 + 2)
        m.observe(.toolResult(callID: "call_a", output: nil, isError: false), at: t0 + 3)
        report.check(m.toolsInFlight == 1 && m.currentTimeoutSeconds == 900,
                     "看门狗:两个工具在途时闭合其一仍剩 1 个未闭合,阈值保持在途档(不提前收回预算)")
        m.observe(.toolResult(callID: "call_b", output: nil, isError: false), at: t0 + 4)
        report.check(m.toolsInFlight == 0 && m.currentTimeoutSeconds == 120,
                     "看门狗:两个工具全部闭合后阈值才退回 idle 档")
    }

    // MARK: - ⑤ 畸形消息

    private static func testMalformedToolMessages(_ report: inout AgentTestReport) {
        var w = AgentWatchdog(policy: .default, startedAt: t0)
        // callID 为 nil 的 tool-use:不进集合(空 id 是共享键,会让所有畸形调用互相顶掉)。
        w.observe(AgentMessage(kind: .toolUse, tool: "Bash", callID: nil, input: nil), at: t0 + 5)
        report.check(w.toolsInFlight == 0 && w.currentTimeoutSeconds == 120,
                     "看门狗:callID 为 nil 的畸形 tool-use 不进在途集合(空 id 会让所有畸形调用互相顶掉)")
        report.check(w.lastActivityAt == t0 + 5,
                     "看门狗:畸形 tool-use 仍算一次活动并刷新最后活动时刻(不进集合不等于没发生)")
        // 空串 callID 同理。
        w.observe(AgentMessage(kind: .toolUse, tool: "Bash", callID: "", input: nil), at: t0 + 6)
        report.check(w.toolsInFlight == 0,
                     "看门狗:callID 为空串的畸形 tool-use 同样不进在途集合")

        // 没配上的 tool-result:忽略,绝不把计数减到负数(agent 流可能被截断)。
        var g = AgentWatchdog(policy: .default, startedAt: t0)
        g.observe(.toolResult(callID: "ghost", output: nil, isError: false), at: t0 + 1)
        report.check(g.toolsInFlight == 0,
                     "看门狗:没配上的 tool-result 被忽略,在途计数不减到负数(agent 流可能被截断)")
        g.observe(.toolUse(callID: "call_1", tool: "Read", input: nil), at: t0 + 2)
        report.check(g.toolsInFlight == 1 && g.currentTimeoutSeconds == 900,
                     "看门狗:孤儿 tool-result 之后新的 tool-use 照常入集合并放宽阈值(计数没被打成负数)")
        // 同一个 callID 的 tool-result 重复到达同样幂等。
        g.observe(.toolResult(callID: "call_1", output: nil, isError: false), at: t0 + 3)
        g.observe(.toolResult(callID: "call_1", output: nil, isError: false), at: t0 + 4)
        report.check(g.toolsInFlight == 0 && g.currentTimeoutSeconds == 120,
                     "看门狗:同一 callID 的 tool-result 重复到达是幂等的(按 id 收敛而不是加减计数器)")
    }

    // MARK: - ⑥ 任何消息都算活动 + 时钟回拨

    private static func testAnyMessageRefreshesActivity(_ report: inout AgentTestReport) {
        // 不刷新的话 t0+121 就该判 stalled;收到心跳后必须回到 healthy。
        var w = AgentWatchdog(policy: .default, startedAt: t0)
        report.check(!isHealthy(w.verdict(at: t0 + 121)),
                     "看门狗:未收到任何消息时静默 121 秒判 stalled(刷新断言的对照组)")
        w.observe(.error("stream error: Reconnecting... 3/5"), at: t0 + 100)
        report.check(isHealthy(w.verdict(at: t0 + 121)),
                     "看门狗:error 型重连心跳刷新最后活动时刻(还在重试不是卡死,02 spike 建议 4)")

        var k = AgentWatchdog(policy: .default, startedAt: t0)
        k.observe(.thinking("…"), at: t0 + 10)
        k.observe(.status("session-started"), at: t0 + 20)
        k.observe(.text("done"), at: t0 + 30)
        report.check(k.lastActivityAt == t0 + 30,
                     "看门狗:text/thinking/status 三型消息同样刷新最后活动时刻(任何输出都算活着)")

        // 墙钟回拨(NTP 校时):不倒退最后活动时刻、静默秒数钳到 0 —— 不凭空制造一段静默。
        var b = AgentWatchdog(policy: .default, startedAt: t0)
        b.observe(.text("a"), at: t0 + 100)
        b.observe(.text("b"), at: t0 + 40)
        report.check(b.lastActivityAt == t0 + 100,
                     "看门狗:墙钟回拨时最后活动时刻不倒退(取较晚者,回拨不制造静默)")
        report.check(b.silentSeconds(at: t0 + 50) == 0 && isHealthy(b.verdict(at: t0 + 50)),
                     "看门狗:墙钟回拨时静默时长钳到 0 而不是负数(NTP 回拨不误杀)")
    }

    // MARK: - ⑦ 取消:迁移 + 终止调用

    private static func testCancelMovesStateAndTerminates(_ report: inout AgentTestReport) {
        guard let (port, handle) = makeLaunched() else {
            report.check(false, "取消:假件拉起失败(前置条件不成立)")
            return
        }
        var state = AgentTaskState.running
        let drain = try? AgentCancellation.cancel(state: &state, handle: handle, port: port, vendor: .claude)

        report.check(state == .cancelled,
                     "取消:running 任务被取消后状态迁到 cancelled")
        report.check(port.terminateCalls == [handle],
                     "取消:终止意图确实发给了那个句柄(FakeAgentPort.terminateCalls 恰记到这一次)")
        report.check(port.isAlive(handle) == false,
                     "取消:发出终止意图后假件里的进程不再存活")
        report.check(drain == .drainToEOF,
                     "取消:Claude 侧取消返回 drainToEOF(读到底才拿得到那条 aborted_streaming 终态)")

        // Codex 侧同一路径,姿态相反。
        guard let (port2, handle2) = makeLaunched() else {
            report.check(false, "取消:假件拉起失败(Codex 分支前置条件不成立)")
            return
        }
        var state2 = AgentTaskState.running
        let drain2 = try? AgentCancellation.cancel(state: &state2, handle: handle2, port: port2, vendor: .codex)
        report.check(state2 == .cancelled && port2.terminateCalls.count == 1 && drain2 == .markAbortedAtSignal,
                     "取消:Codex 侧取消同样迁 cancelled 并发出终止意图,但返回 markAbortedAtSignal(流里不会有终态行)")
    }

    // MARK: - ⑧ 对非 running 取消:抛错 且 绝不终止

    private static func testCancelOnNonRunningThrowsAndNeverTerminates(_ report: inout AgentTestReport) {
        let nonRunning: [AgentTaskState] = [.pending, .completed, .failed, .cancelled, .timeout, .orphaned]
        var allThrew = true
        var allSilent = true
        var allUnchanged = true
        for s in nonRunning {
            guard let (port, handle) = makeLaunched() else {
                report.check(false, "取消:假件拉起失败(非 running 分支前置条件不成立)")
                return
            }
            var state = s
            var threw = false
            do {
                _ = try AgentCancellation.cancel(state: &state, handle: handle, port: port, vendor: .claude)
            } catch {
                threw = true
            }
            if !threw { allThrew = false }
            // **这条是本票最要害的一条**:不能既报错又已经把进程杀了。
            if !port.terminateCalls.isEmpty { allSilent = false }
            if state != s { allUnchanged = false }
        }
        report.check(allThrew,
                     "取消:pending 与五个终态共六个非 running 状态逐个取消全部抛错(只有 running 可取消)")
        report.check(allSilent,
                     "取消:非 running 取消抛错时 terminateCalls 保持为空(绝不既报错又已经把进程杀了)")
        report.check(allUnchanged,
                     "取消:非 running 取消失败后任务状态一字未改")

        // 错误值如实带上当时的状态(调用方要能把「当时它是什么」原样报出来)。
        guard let (port, handle) = makeLaunched() else {
            report.check(false, "取消:假件拉起失败(错误值分支前置条件不成立)")
            return
        }
        var done = AgentTaskState.completed
        var caught: AgentCancellationError?
        do {
            _ = try AgentCancellation.cancel(state: &done, handle: handle, port: port, vendor: .claude)
        } catch let e as AgentCancellationError {
            caught = e
        } catch {
            caught = nil
        }
        report.check(caught == .notRunning(.completed),
                     "取消:抛出的错误如实携带当时的状态(notRunning(completed),调用方可原样报出)")
    }

    // MARK: - ⑨ 看门狗判卡死 → 迁 timeout + 终止(票面第 1 条的完整链路)

    private static func testWatchdogStallDrivesTimeoutTermination(_ report: inout AgentTestReport) {
        guard let (port, handle) = makeLaunched() else {
            report.check(false, "超时终止:假件拉起失败(前置条件不成立)")
            return
        }
        var w = AgentWatchdog(policy: .default, startedAt: t0)
        w.observe(.text("working"), at: t0 + 10)
        var state = AgentTaskState.running

        let verdict = w.verdict(at: t0 + 10 + 121)
        var drain: AgentDrainPolicy?
        if case .stalled = verdict {
            drain = try? AgentCancellation.timeOut(state: &state, handle: handle, port: port, vendor: .codex)
        }
        report.check(verdict == .stalled(silentSeconds: 121, toolInFlight: false) && state == .timeout,
                     "超时终止:看门狗判 stalled 后任务状态迁到 timeout(不是 cancelled —— 平台判的与用户点的要分得清)")
        report.check(port.terminateCalls == [handle] && drain == .markAbortedAtSignal,
                     "超时终止:判卡死后终止意图确实发给了那个句柄,并交回该 vendor 的 drain 姿态")

        // 同款校验:对非 running 判超时一样抛错、一样不许杀进程。
        guard let (port2, handle2) = makeLaunched() else {
            report.check(false, "超时终止:假件拉起失败(非 running 分支前置条件不成立)")
            return
        }
        var settled = AgentTaskState.completed
        var threw = false
        do {
            _ = try AgentCancellation.timeOut(state: &settled, handle: handle2, port: port2, vendor: .claude)
        } catch {
            threw = true
        }
        report.check(threw && port2.terminateCalls.isEmpty && settled == .completed,
                     "超时终止:对非 running 任务判超时同样抛错且 terminateCalls 保持为空")
    }

    // MARK: - ⑩ 两家中断姿态收敛

    private static func testVendorDrainPolicies(_ report: inout AgentTestReport) {
        report.check(AgentInterruptPolicy.drainPolicy(for: .claude) == .drainToEOF,
                     "中断收敛:Claude 侧姿态是 drainToEOF(01 spike:信号后先补 Request interrupted 再落 aborted_streaming 终态,弃管道就丢终态)")
        report.check(AgentInterruptPolicy.drainPolicy(for: .codex) == .markAbortedAtSignal,
                     "中断收敛:Codex 侧姿态是 markAbortedAtSignal(02 spike exec5:被 SIGTERM 杀时流里根本没有终态行,再读也读不出)")
        report.check(AgentInterruptPolicy.drainPolicy(for: .claude) != AgentInterruptPolicy.drainPolicy(for: .codex),
                     "中断收敛:两家 drain 姿态互不相等(不对称是实证结论,不是可以抹平的实现细节)")
        report.check(AgentVendor.allCases.map(\.rawValue) == ["claude", "codex"],
                     "中断收敛:AgentVendor 穷尽两家且 rawValue 为小写串(可直接落进 meta.json)")
    }

    // MARK: - ⑪ 终态收敛五步顺序(复用 04 的 resolve,逐条钉死)

    private static func testTerminalResolutionOrder(_ report: inout AgentTestReport) {
        let succeeded = AgentTerminalStatus(outcome: .succeeded, reason: "completed")
        let aborted = AgentTerminalStatus(outcome: .aborted, reason: "aborted_streaming")
        let failed = AgentTerminalStatus(outcome: .failed, reason: "error_during_execution")

        // 第 1 步:terminal 优先于取消记账 —— 竞态里 agent 恰好在信号落地前正常完成,报 completed 才诚实。
        report.check(AgentTaskState.resolve(terminal: succeeded, exitCode: -15, cancelRequested: true) == .completed,
                     "终态收敛:terminal 优先于取消记账 —— 信号落地前正好正常完成时报 completed(不丢一份有效结果)")
        report.check(AgentTaskState.resolve(terminal: failed, exitCode: 0, cancelRequested: false) == .failed,
                     "终态收敛:terminal 说 failed 时退出码 0 也不翻案(agent 自己说了话就以它为准)")
        report.check(AgentTaskState.resolve(terminal: aborted, exitCode: 0, cancelRequested: false) == .cancelled,
                     "终态收敛:terminal 说 aborted 映射为 job 的 cancelled")
        // 第 2 步:Codex 中断现场 —— 无终态行 + 负退出码 + 有取消记账。
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: -15, cancelRequested: true) == .cancelled,
                     "终态收敛:Codex 中断现场(terminal 为 nil + 退出码 -15 + 有取消记账)判 cancelled")
        // 第 3 步:没有取消记账时,负退出码本身即「被信号杀」。
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: -9, cancelRequested: false) == .cancelled,
                     "终态收敛:terminal 为 nil + 负退出码且无取消记账仍判 cancelled(负值即被信号杀,04 已定的语义)")
        // 第 4 步:0 / 正退出码。
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: 0, cancelRequested: false) == .completed,
                     "终态收敛:terminal 为 nil + 退出码 0 判 completed")
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: 1, cancelRequested: false) == .failed,
                     "终态收敛:terminal 为 nil + 正退出码 1 判 failed")
        // 第 5 步:什么都拿不到 → fail-closed 兜 failed(绝不留在 running)。
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: nil, cancelRequested: false) == .failed,
                     "终态收敛:terminal 与退出码都拿不到时兜 failed(fail-closed,绝不把任务挂在 running)")
    }

    // MARK: - ⑫ timeout 合流点(薄壳,不产生第二套判定)

    private static func testTimeoutMergePoint(_ report: inout AgentTestReport) {
        let succeeded = AgentTerminalStatus(outcome: .succeeded, reason: "completed")
        let aborted = AgentTerminalStatus(outcome: .aborted, reason: "aborted_streaming")

        report.check(AgentInterruptPolicy.resolveIncludingTimeout(
                        terminal: nil, exitCode: -15, cancelRequested: true, timedOut: true) == .timeout,
                     "超时合流:timedOut 与 cancelRequested 同时为真判 timeout(顺序不可颠倒 —— 平台判的卡死不能记成用户取消)")
        report.check(AgentInterruptPolicy.resolveIncludingTimeout(
                        terminal: aborted, exitCode: -15, cancelRequested: false, timedOut: true) == .timeout,
                     "超时合流:Claude 读到底拿回的 aborted 只是我们那一刀的回声,timedOut 时仍判 timeout 而不是 cancelled")
        report.check(AgentInterruptPolicy.resolveIncludingTimeout(
                        terminal: succeeded, exitCode: 0, cancelRequested: false, timedOut: true) == .completed,
                     "超时合流:竞态里 agent 已交出成功终态时报 completed 而不是 timeout(不丢有效产出,与 04 的 terminal 优先同款理由)")
        report.check(AgentInterruptPolicy.resolveIncludingTimeout(
                        terminal: nil, exitCode: nil, cancelRequested: false, timedOut: true) == .timeout,
                     "超时合流:只有 timedOut 为真、其余判据全缺时判 timeout")

        // CR 补:把**豁免集恰为 {succeeded}** 钉死。原先 failed/aborted 那两支只经「是不是终态」的宽断言,
        //   将来有人把豁免集扩成 {succeeded, failed},现有断言一条都不会红 —— 那会让「超时被系统性记成失败」悄悄发生。
        //   豁免判据是「**该终态可不可能是我们自己那一刀的回声**」:succeeded 不可能被一刀捏造,是唯一安全豁免;
        //   failed 在别的 CLI 版本里能否作为杀信号的回声出现,两个中断样本无法排除 —— 故不豁免(稳健侧)。
        let exempted = AgentTerminalOutcome.allCases.filter { outcome in
            AgentInterruptPolicy.resolveIncludingTimeout(
                terminal: AgentTerminalStatus(outcome: outcome, reason: nil),
                exitCode: 0, cancelRequested: false, timedOut: true) != .timeout
        }
        report.check(exempted == [.succeeded],
                     "超时合流:timedOut 的豁免集恰为 {succeeded} —— failed / aborted 一律仍判 timeout(防豁免集被悄悄放大)")

        // timedOut 为假时必须与 04 的 resolve 逐值相同 —— 薄壳绝不产生第二套判定。
        let terminals: [AgentTerminalStatus?] = [
            nil,
            AgentTerminalStatus(outcome: .succeeded, reason: nil),
            AgentTerminalStatus(outcome: .failed, reason: nil),
            AgentTerminalStatus(outcome: .aborted, reason: nil),
        ]
        let codes: [Int32?] = [nil, -15, 0, 1]
        var identical = true
        var allTerminal = true
        for t in terminals {
            for c in codes {
                for cancelled in [false, true] {
                    let base = AgentTaskState.resolve(terminal: t, exitCode: c, cancelRequested: cancelled)
                    let shell = AgentInterruptPolicy.resolveIncludingTimeout(
                        terminal: t, exitCode: c, cancelRequested: cancelled, timedOut: false)
                    if base != shell { identical = false }
                    let timed = AgentInterruptPolicy.resolveIncludingTimeout(
                        terminal: t, exitCode: c, cancelRequested: cancelled, timedOut: true)
                    if !shell.isTerminal || !timed.isTerminal { allTerminal = false }
                }
            }
        }
        report.check(identical,
                     "超时合流:timedOut 为假时 32 组输入与 AgentTaskState.resolve 逐值相同(薄壳不产生第二套判定)")
        report.check(allTerminal,
                     "超时合流:全部输入组合(含 timedOut 为真)都收敛到终态,绝无把任务挂在 running 的路径")
    }
}
