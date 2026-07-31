// AAAgentTestKit —— CodexAdapter 归一化的黄金样本测试(03 票:喂 02 spike 落盘的**真实** NDJSON)。
// 依赖边:AAAgentTestKit → AAAgentCore、AAContracts(+ 系统 Foundation)。
//
// 为什么从磁盘真读样本、而不是把样本贴成 Swift 字符串常量(口径同 ClaudeAdapterTests):
//   `.scratch/agent-delegation/research/spike-codex-exec/samples/*.stdout.jsonl` 是 02 spike 真调 Codex 落盘的
//   **单一真相源**(已入库)。复制成常量会立刻产生第二份真相:样本更新后常量不动,测试就开始守着过期的形状。
//   路径经环境变量 `AA_SPIKE_DIR` 注入(由 check.sh 传 $ROOT/.scratch/agent-delegation/research)。
//   **fail-closed**:环境变量缺失 / 目录不存在 / 文件读不出 → 一律记 FAIL,绝不静默跳过。
//
// 覆盖的样本与它们各自钉死的事实:
//   exec1-baseline-readonly-default      —— 消息序列逐型钉死 + thread_id → sessionID + 终态 succeeded(happy path);
//   exec2-default-write-attempt          —— tool-use↔tool-result 的 callID(item_1)配对不丢;
//                                           且**工具失败(exit_code=1)≠ 回合失败**(终态仍 succeeded);
//   exec3-readonly-explicit-write        —— 硬超时被 SIGTERM:多条 Reconnecting 噪音**但 terminal 恒为 nil**;
//   exec3b-…-retry                       —— 静默空气墙:被拦的写连 item 都不出现,V1 **不合成**拒绝消息;
//   exec4-workspace-write-cfg-boundary-nopath —— 越界写同样静默消失,只留 cwd 内那一对 item(不臆造第二对);
//   exec5-interrupt-sigterm-midrun       —— 真中断:流只到 turn.started,**terminal 恒为 nil**(不对称的回归护栏);
//   exec6-failure-invalid-model          —— turn.failed 的双层编码错因解出内层人话(且外层字面不残留);
//   exec7-no-auth-isolation-check        —— 同一字段是纯文本时双层解码**优雅退化**为原串(不崩、不丢);
//   外加不依赖样本的构造行覆盖:未知顶层事件 / 未知 item 类型 / 缺 item 载荷 / 垃圾行 / 空行 / 超长行,
//   以及顶层 error 单行的隔离行为(exec3 已用真样本逐行覆盖过「绝不产终态」,构造行只是把**单行**行为单独钉住)。
//   还有**八个样本确实都触发不到**的三支,只能靠构造行:turn.failed 缺 error.message / 双层解码内层为空
//   / stderr 噪音行混进 stdout(见各自断言处的注释)。
//
// 说明:本套件由 check.sh 动态生成的 runner 执行,打印 report.lines;各描述串是 check.sh 阶段 B
//   assert_contains 的定长子串目标,**不得随意改字**(改则同步改 check.sh 断言组 1e)。

import Foundation
import AAContracts
import AAAgentCore

/// Codex exec --json 归一化的黄金样本测试。
public enum CodexAdapterTests {
    public static func run() -> AgentTestReport {
        var report = AgentTestReport()
        // 兜底覆盖不依赖样本,先跑:即使样本目录缺失(下面会记 FAIL),这部分仍有覆盖。
        testFallbacks(&report)
        guard let dir = spikeDirectory(&report) else { return report }
        testBaseline(&report, dir)
        testWriteAttempt(&report, dir)
        testReconnectTimeout(&report, dir)
        testSilentDenial(&report, dir)
        testWorkspaceBoundary(&report, dir)
        testInterrupted(&report, dir)
        testInvalidModel(&report, dir)
        testNoAuth(&report, dir)
        return report
    }

    // MARK: - ① 兜底:未知事件 / 畸形 item / 垃圾行 / 空行(纯函数,无需样本)

    private static func testFallbacks(_ report: inout AgentTestReport) {
        // 未知顶层事件(上游新增事件类型):记录不崩、不产终态。
        let unknown = CodexAdapter.normalize(line: #"{"type":"brand_new_event","payload":42}"#)
        report.check(unknown.messages.count == 1
                        && unknown.messages[0].kind == .status
                        && unknown.messages[0].status == "unknown:brand_new_event"
                        && unknown.terminal == nil,
                     "Codex adapter:未知顶层事件归一为 status=unknown:brand_new_event(新增事件类型不打崩、不产终态)")
        report.check(unknown.messages.first?.text?.contains("payload") == true,
                     "Codex adapter:未知顶层事件保留原始行文本(可诊断)")

        // 未知 item 类型(如 spike 未触发的 file_change / apply_patch 类 item):保真上浮且**保住 callID**。
        let oddItem = CodexAdapter.normalize(
            line: #"{"type":"item.started","item":{"id":"item_9","type":"file_change"}}"#)
        report.check(oddItem.messages.first?.status == "unknown-item:file_change"
                        && oddItem.messages.first?.callID == "item_9",
                     "Codex adapter:未知 item 类型归一为 status=unknown-item:file_change 且保留 callID=item_9")

        // 缺 item 载荷的畸形事件:走同一条兜底路,不崩。
        let noItem = CodexAdapter.normalize(line: #"{"type":"item.completed"}"#)
        report.check(noItem.messages.first?.status == "unknown-item:(missing)",
                     "Codex adapter:item 事件缺 item 载荷时归一为 status=unknown-item:(missing)(畸形行不崩)")

        // **本票最关键的一条回归护栏**:顶层 error 行是瞬态重连噪音,单独出现时绝不产终态。
        let transient = CodexAdapter.normalize(
            line: #"{"type":"error","message":"Reconnecting... 2/5 (request timed out)"}"#)
        report.check(transient.messages.count == 1
                        && transient.messages[0].kind == .error
                        && transient.messages[0].text?.contains("Reconnecting") == true
                        && transient.terminal == nil,
                     "Codex adapter:顶层 error 归一为 error 型消息且绝不产终态(瞬态重连噪音不是失败)")

        // 非 JSON 垃圾行:降级成 unparsed,绝不抛/崩,**且绝不产终态**。
        let junk = CodexAdapter.normalize(line: "not json at all {{{ >>>")
        report.check(junk.messages.count == 1
                        && junk.messages[0].kind == .status
                        && junk.messages[0].status == "unparsed"
                        && junk.messages[0].text == "not json at all {{{ >>>"
                        && junk.terminal == nil,
                     "Codex adapter:非 JSON 垃圾行归一为 status=unparsed 且保留原始行、不产终态(不崩不抛)")

        // 票面「stderr 的 ERROR 字样不作失败判据」的可测落点(CR 建议):
        //   本 adapter 结构上只吃 stdout,理应永远见不到 stderr;但**将来某个 SystemAgentPort 实现若把 2>&1 合流**,
        //   这些 ERROR 噪音就会混进来。02 spike 实证:8/8 次调用连成功的那几次 stderr 也稳定打 ERROR
        //   (alpha 构建的旁路依赖噪音),所以它绝不能被判成失败。构造一条真实形状的 stderr 行钉死:
        //   它只会走 unparsed 降级,**terminal 恒为 nil**,不可能让任何任务被误判为失败。
        let stderrNoise = CodexAdapter.normalize(
            line: "ERROR codex_api::endpoint::responses_websocket: failed to connect")
        report.check(stderrNoise.terminal == nil
                        && stderrNoise.messages.first?.status == "unparsed",
                     "Codex adapter:stderr 的 ERROR 噪音行只走 unparsed 降级、绝不产终态(ERROR 字样不是失败判据)")

        // 八个样本都触发不到的两支降级(CR 建议补,照 ClaudeAdapterTests 为 error_during_execution 造行的先例):
        //   ① turn.failed 缺 error.message —— 理由如实留 nil,但消息流仍留一条带原始行的 error(可诊断优先)。
        let failedNoMessage = CodexAdapter.normalize(line: #"{"type":"turn.failed"}"#)
        report.check(failedNoMessage.terminal?.outcome == .failed
                        && failedNoMessage.terminal?.reason == nil
                        && failedNoMessage.messages.first?.kind == .error,
                     "Codex adapter:turn.failed 缺 error.message 时终态仍 failed、reason 如实留 nil(不臆造理由)")
        //   ② 双层解码解得开、但内层 error.message 为空 —— 原样退回外层串,绝不因为「解开了」就交回空字符串。
        let emptyInner = CodexAdapter.normalize(
            line: #"{"type":"turn.failed","error":{"message":"{\"error\":{\"message\":\"\"}}"}}"#)
        report.check(emptyInner.terminal?.reason?.isEmpty == false,
                     "Codex adapter:双层解码内层为空时退回外层原串(解得开也不交回空理由)")

        // 空行 / 全空白行:0 条消息,不是错误。
        report.check(CodexAdapter.normalize(line: "").messages.isEmpty,
                     "Codex adapter:空行产出 0 条消息(不报错)")
        report.check(CodexAdapter.normalize(line: "  \t ").messages.isEmpty,
                     "Codex adapter:全空白行产出 0 条消息(不报错)")

        // 超长不可解析行:截断到 512,日志不被撑爆(与 Claude 侧同口径)。
        let long = CodexAdapter.normalize(line: String(repeating: "x", count: 900))
        report.check(long.messages.first?.text?.count == 512,
                     "Codex adapter:超长不可解析行截断到 512 字符(与 Claude 侧同口径)")

        // 缺 type 键:走哨兵串兜底(不特判、不崩)。
        report.check(CodexAdapter.normalize(line: #"{"foo":1}"#).messages.first?.status == "unknown:(missing)",
                     "Codex adapter:缺 type 键的 JSON 行归一为 status=unknown:(missing)")
    }

    // MARK: - ② baseline 只读样本(exec1):消息序列 + thread_id → sessionID + 终态

    private static func testBaseline(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "exec1-baseline-readonly-default") else { return }
        let out = CodexAdapter.normalize(lines: lines)

        // 消息序列逐型钉死:thread.started → turn.started → item.started(cmd)→ item.completed(cmd)
        //                → item.completed(agent_message)→ turn.completed。
        report.check(out.messages.map { $0.kind } == [.status, .status, .toolUse, .toolResult, .text, .status],
                     "Codex adapter:baseline 样本(exec1)消息序列=[status,status,tool-use,tool-result,text,status]")
        report.check(out.messages.first?.status == AgentStatusCode.sessionStarted.rawValue
                        && lines.first?.contains("thread.started") == true,
                     "Codex adapter:baseline 样本(exec1)首行 thread.started 归一为 session-started 状态消息")
        report.check(out.sessionID == "019faa09-dcf2-75d2-b83c-28e95e20e800",
                     "Codex adapter:baseline 样本(exec1)sessionID 逐字取自首行 thread_id(不必等文件落盘)")
        report.check(out.messages.contains { $0.status == AgentStatusCode.turnStarted.rawValue }
                        && out.messages.last?.status == AgentStatusCode.turnCompleted.rawValue,
                     "Codex adapter:baseline 样本(exec1)turn.started/turn.completed 归一为 turn-started/turn-completed")
        report.check(out.terminal?.outcome == .succeeded && out.terminal?.reason == "turn.completed",
                     "Codex adapter:baseline 样本(exec1)终态=succeeded(reason=turn.completed)")
        report.check(out.terminal?.finalText == nil,
                     "Codex adapter:baseline 样本(exec1)终态 finalText 恒为 nil(Codex 原生无终局答复字段,04 退回取最后一条 text)")

        guard let use = out.messages.first(where: { $0.kind == .toolUse }),
              let result = out.messages.first(where: { $0.kind == .toolResult }) else {
            report.check(false, "Codex adapter:baseline 样本(exec1)应同时产出 tool-use 与 tool-result 消息")
            return
        }
        report.check(use.tool == "command_execution" && use.callID == "item_0",
                     "Codex adapter:baseline 样本(exec1)command_execution 归一为 tool-use(工具名照搬 item.type,callID=item_0)")
        report.check(use.input?.objectValue?["command"]?.stringValue?.contains("ls -la") == true,
                     "Codex adapter:baseline 样本(exec1)tool-use 入参承载原生 command 串")
        report.check(result.output?.objectValue?["aggregated_output"] != nil
                        && result.output?.objectValue?["exit_code"] != nil,
                     "Codex adapter:baseline 样本(exec1)tool-result 产物承载 aggregated_output 与 exit_code")
        report.check(result.isError == false,
                     "Codex adapter:baseline 样本(exec1)exit_code=0 且 status=completed 时 isError=false")
        report.check(out.messages.first(where: { $0.kind == .text })?.text == "0",
                     "Codex adapter:baseline 样本(exec1)agent_message 归一为 text 型消息(内容逐字保真)")
    }

    // MARK: - ③ 写尝试样本(exec2):callID 配对 + 工具失败 ≠ 回合失败

    private static func testWriteAttempt(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "exec2-default-write-attempt") else { return }
        let out = CodexAdapter.normalize(lines: lines)

        guard let use = out.messages.first(where: { $0.kind == .toolUse }),
              let result = out.messages.first(where: { $0.kind == .toolResult }) else {
            report.check(false, "Codex adapter:写尝试样本(exec2)应同时产出 tool-use 与 tool-result 消息")
            return
        }
        report.check(use.callID == "item_1" && use.callID == result.callID,
                     "Codex adapter:写尝试样本(exec2)item.started 与 item.completed 同一个 item_1 归一为相等 callID(全链配对不丢)")
        report.check(result.isError == true
                        && result.output?.objectValue?["exit_code"] == JSONValue.number(1),
                     "Codex adapter:写尝试样本(exec2)status=failed 且 exit_code=1 时 isError=true")
        report.check(out.terminal?.outcome == .succeeded,
                     "Codex adapter:写尝试样本(exec2)工具失败但终态仍是 succeeded(工具失败不等于回合失败)")
        report.check(out.messages.filter { $0.kind == .text }.count == 2,
                     "Codex adapter:写尝试样本(exec2)两条 agent_message 各归一为一条 text 消息")
        report.check(!out.messages.contains { $0.status == AgentStatusCode.permissionDenied.rawValue },
                     "Codex adapter:写尝试样本(exec2)不产 permission-denied 消息(Codex 侧无可识别的拒绝信号)")
    }

    // MARK: - ④ 硬超时样本(exec3):Reconnecting 噪音不产终态

    private static func testReconnectTimeout(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "exec3-readonly-explicit-write") else { return }
        let out = CodexAdapter.normalize(lines: lines)

        // 本样本(returncode=-15,90s 硬超时 SIGTERM)流里根本没有终态行 —— adapter 必须诚实交回 nil。
        report.check(out.terminal == nil,
                     "Codex adapter:硬超时样本(exec3)terminal 恒为 nil(流里没有终态行就绝不臆造,终态由上层据退出码补)")
        let errors = out.messages.filter { $0.kind == .error }
        report.check(errors.count == 4 && errors.allSatisfy { $0.text?.contains("Reconnecting") == true },
                     "Codex adapter:硬超时样本(exec3)4 条 Reconnecting 各归一为一条 error 消息")
        report.check(lines.allSatisfy { CodexAdapter.normalize(line: $0).terminal == nil },
                     "Codex adapter:硬超时样本(exec3)逐行归一化没有任何一行产出终态(error 行绝不是失败判据)")
        report.check(out.sessionID?.isEmpty == false,
                     "Codex adapter:硬超时样本(exec3)即使无终态也已提取出 sessionID(续接指针不丢)")
    }

    // MARK: - ⑤ 静默空气墙(exec3b):被拦的写连 item 都不出现,V1 不合成拒绝消息

    private static func testSilentDenial(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "exec3b-readonly-explicit-write-retry") else { return }
        let out = CodexAdapter.normalize(lines: lines)

        // 该样本里模型被强制要求「第一个且唯一一个 tool call 必须是那条写命令」,实际流里一个 command_execution 都没有。
        report.check(!out.messages.contains { $0.kind == .toolUse || $0.kind == .toolResult },
                     "Codex adapter:静默空气墙样本(exec3b)被拦的写在流里连 item 都不出现,故零条 tool-use/tool-result")
        report.check(!out.messages.contains { $0.status == AgentStatusCode.permissionDenied.rawValue },
                     "Codex adapter:静默空气墙样本(exec3b)V1 绝不合成 permission-denied 消息(Codex 侧拒绝不可识别,不臆造)")
        report.check(out.terminal?.outcome == .succeeded,
                     "Codex adapter:静默空气墙样本(exec3b)终态=succeeded(被拦不等于回合失败)")
        report.check(out.messages.filter { $0.kind == .text }.count == 2,
                     "Codex adapter:静默空气墙样本(exec3b)只剩两条 agent_message 文本(拒绝只能靠事后 diff 文件树反推)")
    }

    // MARK: - ⑥ 沙箱边界样本(exec4):cwd 内那一对留痕,越界那次静默消失

    private static func testWorkspaceBoundary(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "exec4-workspace-write-cfg-boundary-nopath") else { return }
        let out = CodexAdapter.normalize(lines: lines)

        let uses = out.messages.filter { $0.kind == .toolUse }
        let results = out.messages.filter { $0.kind == .toolResult }
        report.check(uses.count == 1 && results.count == 1 && uses.first?.callID == results.first?.callID,
                     "Codex adapter:沙箱边界样本(exec4)两次强制调用只有 cwd 内那次留下一对 item,越界那次归一化后同样零痕迹")
        report.check(results.first?.isError == false,
                     "Codex adapter:沙箱边界样本(exec4)cwd 内写 exit_code=0 归一为 isError=false")
        report.check(out.terminal?.outcome == .succeeded,
                     "Codex adapter:沙箱边界样本(exec4)终态=succeeded")
    }

    // MARK: - ⑦ 中断样本(exec5):流只到 turn.started,terminal 恒为 nil

    private static func testInterrupted(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "exec5-interrupt-sigterm-midrun") else { return }
        let out = CodexAdapter.normalize(lines: lines)

        // 与 Claude 侧最重要的不对称:Claude 被中断仍会补一条 result 终态行,Codex 被 SIGTERM 直接死,流原样截断。
        report.check(out.terminal == nil,
                     "Codex adapter:中断样本(exec5)terminal 恒为 nil(Codex 被信号杀不补终态行,与 Claude 侧不对称)")
        report.check(out.messages.map { $0.kind } == [.status, .status]
                        && out.messages.map { $0.status } == [AgentStatusCode.sessionStarted.rawValue,
                                                              AgentStatusCode.turnStarted.rawValue],
                     "Codex adapter:中断样本(exec5)消息只有 session-started 与 turn-started 两条(流被原样截断)")
        report.check(out.sessionID?.isEmpty == false,
                     "Codex adapter:中断样本(exec5)仍提取出 sessionID(被中断的任务也留得下续接指针)")
        report.check(!out.messages.contains { $0.status == AgentStatusCode.interrupted.rawValue },
                     "Codex adapter:中断样本(exec5)不注入 interrupted 消息(事件流看不出是被杀还是自己崩,交由上层据退出码判)")
    }

    // MARK: - ⑧ invalid-model 样本(exec6):turn.failed 的双层编码错因

    private static func testInvalidModel(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "exec6-failure-invalid-model") else { return }
        let out = CodexAdapter.normalize(lines: lines)

        report.check(out.terminal?.outcome == .failed,
                     "Codex adapter:invalid-model 样本(exec6)终态=failed(唯一判据是 turn.failed 行)")
        guard let reason = out.terminal?.reason else {
            report.check(false, "Codex adapter:invalid-model 样本(exec6)终态应带 reason")
            return
        }
        report.check(reason.contains("not supported when using Codex with a ChatGPT account"),
                     "Codex adapter:invalid-model 样本(exec6)双层解码后 reason 是内层那句人话")
        report.check(!reason.contains("invalid_request_error") && !reason.contains("{"),
                     "Codex adapter:invalid-model 样本(exec6)reason 不残留外层 JSON 字面(双层解码真解到了内层)")
        report.check(out.messages.contains { $0.kind == .error && $0.text == reason },
                     "Codex adapter:invalid-model 样本(exec6)终态理由同时留一条 error 消息(按序渲染时看得见死因)")
        report.check(out.messages.contains { $0.kind == .error && $0.text?.contains("invalid_request_error") == true },
                     "Codex adapter:invalid-model 样本(exec6)顶层 error 行原样保真不解码(诊断面要如实,判定面才收敛)")
        report.check(out.messages.contains { $0.kind == .error && $0.text?.contains("Model metadata for") == true },
                     "Codex adapter:invalid-model 样本(exec6)item 级 error 警告归一为 error 型消息")
        report.check(!out.messages.contains { $0.status == AgentStatusCode.turnCompleted.rawValue },
                     "Codex adapter:invalid-model 样本(exec6)全流无 turn.completed(失败回合不产成功状态消息)")
    }

    // MARK: - ⑨ 无鉴权样本(exec7):同一字段是纯文本时双层解码优雅退化

    private static func testNoAuth(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "exec7-no-auth-isolation-check") else { return }
        let out = CodexAdapter.normalize(lines: lines)

        report.check(out.terminal?.outcome == .failed,
                     "Codex adapter:无鉴权样本(exec7)终态=failed")
        guard let reason = out.terminal?.reason else {
            report.check(false, "Codex adapter:无鉴权样本(exec7)终态应带 reason")
            return
        }
        report.check(reason.hasPrefix("unexpected status 401 Unauthorized")
                        && reason.contains("request id:"),
                     "Codex adapter:无鉴权样本(exec7)error.message 非 JSON 时 reason 逐字退化为原串(解不出不丢信息、不崩)")
        report.check(out.messages.filter { $0.kind == .error }.count == 12,
                     "Codex adapter:无鉴权样本(exec7)11 条流内 error 加终态那条共 12 条 error 消息(重连噪音一条不吞)")
        report.check(out.messages.filter { $0.kind == .error }.filter { $0.text?.contains("Reconnecting") == true }.count == 9,
                     "Codex adapter:无鉴权样本(exec7)两级传输各 5 次重连中的 9 条 Reconnecting 全部归一为 error 消息")
        report.check(out.messages.filter { $0.kind == .status }.count == 2,
                     "Codex adapter:无鉴权样本(exec7)只有 session-started 与 turn-started 两条 status(失败回合无 turn-completed)")
    }

    // MARK: - 样本装载(fail-closed)

    /// 解析样本目录:`AA_SPIKE_DIR`(check.sh 注入)+ `/spike-codex-exec/samples`。缺失 / 不存在 → 记 FAIL 并返回 nil。
    private static func spikeDirectory(_ report: inout AgentTestReport) -> String? {
        // 单次求值 + 单次 check:不写字面恒真的 `check(true, …)`(那种写法一旦上面的 guard 被重构掉就静默常绿)。
        let root = ProcessInfo.processInfo.environment["AA_SPIKE_DIR"]
        let injected = (root?.isEmpty == false)
        report.check(injected, "Codex adapter:样本目录环境变量 AA_SPIKE_DIR 已注入(缺失即 fail-closed)")
        guard injected, let root = root else { return nil }
        let dir = root + "/spike-codex-exec/samples"
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
        report.check(exists && isDirectory.boolValue,
                     "Codex adapter:spike 黄金样本目录存在(不存在即 fail-closed,绝不静默跳过)")
        return (exists && isDirectory.boolValue) ? dir : nil
    }

    /// 读一个样本的全部行(含空行:归一化必须能吃下 NDJSON 尾部空行)。读不出 → 记 FAIL 并返回 nil。
    private static func loadSample(_ report: inout AgentTestReport, _ dir: String, _ name: String) -> [String]? {
        let path = dir + "/" + name + ".stdout.jsonl"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            report.check(false, "Codex adapter:黄金样本可读 —— \(name)(读不出即 fail-closed)")
            return nil
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
