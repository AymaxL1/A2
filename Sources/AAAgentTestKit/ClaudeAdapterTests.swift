// AAAgentTestKit —— ClaudeAdapter 归一化的黄金样本测试(02 票:喂 01 spike 落盘的**真实** NDJSON)。
// 依赖边:AAAgentTestKit → AAAgentCore、AAContracts(+ 系统 Foundation)。
//
// 为什么从磁盘真读样本、而不是把样本贴成 Swift 字符串常量:
//   `.scratch/agent-delegation/research/spike-claude-headless/*.stdout.ndjson` 是 01 spike 真调 Claude 落盘的
//   **单一真相源**(已入库)。复制成常量会立刻产生第二份真相:样本更新后常量不动,测试就开始守着过期的形状。
//   故这里读真文件,路径经环境变量 `AA_SPIKE_DIR` 注入(由 check.sh 传 $ROOT/.scratch/agent-delegation/research)。
//   **fail-closed**:环境变量缺失 / 目录不存在 / 文件读不出 → 一律记 FAIL,绝不静默跳过
//   (否则样本挪走后测试会「全绿地什么都没测」——比红更危险)。
//
// 覆盖的样本与它们各自钉死的事实:
//   01-baseline-readonly  —— 消息序列 + session-started + 终态 succeeded(happy path 基线);
//   02-tool-use-bypass    —— tool-use↔tool-result 的 callID 配对不丢(修 multica 丢 CallID 的有损点);
//   03-no-bypass-…        —— 被拒信号可识别,**且终态仍是 succeeded**(被拒 ≠ 终态失败);
//   04-sigterm-interrupt  —— 终态 aborted(判定顺序:aborted 必须在 failed 之前,该样本 is_error 也是 true);
//   05-invalid-model      —— 终态 failed,**而原生 subtype 字面仍是 "success"**(「不能只看 subtype」的回归护栏);
//   07-cwd-escape         —— 越界写在归一化层面与正常写无差别(cwd 不是安全边界);
//   外加不依赖样本的构造行覆盖:control_request / 非 JSON 垃圾行 / 空行 / 超长行 / 未知子块,
//   以及**八组样本都覆盖不到**的一支——非中断的 `error_during_execution` 必须判 failed(CR 结论的回归护栏)。
//
// 说明:本套件由 check.sh 动态生成的 runner 执行,打印 report.lines;各描述串是 check.sh 阶段 B
//   assert_contains 的定长子串目标,**不得随意改字**(改则同步改 check.sh 断言组 1d)。

import Foundation
import AAContracts
import AAAgentCore

/// Claude stream-json 归一化的黄金样本测试。
public enum ClaudeAdapterTests {
    public static func run() -> AgentTestReport {
        var report = AgentTestReport()
        // 兜底三连不依赖样本,先跑:即使样本目录缺失(下面会记 FAIL),这部分仍有覆盖。
        testFallbacks(&report)
        guard let dir = spikeDirectory(&report) else { return report }
        testBaseline(&report, dir)
        testToolUse(&report, dir)
        testCwdEscape(&report, dir)
        testInterrupted(&report, dir)
        testInvalidModel(&report, dir)
        testPermissionDenied(&report, dir)
        return report
    }

    // MARK: - ① 兜底:未知双向消息 / 垃圾行 / 空行(纯函数,无需样本)

    private static func testFallbacks(_ report: inout AgentTestReport) {
        // 未知顶层事件(V1 不应答 control_request,只记录不崩)。
        let control = ClaudeAdapter.normalize(line: #"{"type":"control_request","request_id":"x"}"#)
        report.check(control.messages.count == 1
                        && control.messages[0].kind == .status
                        && control.messages[0].status == "unknown:control_request"
                        && control.terminal == nil,
                     "Claude adapter:control_request 归一为 status=unknown:control_request(未知双向消息不崩、不产终态)")
        report.check(control.messages.first?.text?.contains("request_id") == true,
                     "Claude adapter:未知顶层事件保留原始行文本(可诊断)")

        // 非 JSON 垃圾行:降级成 unparsed,绝不抛/崩。
        let junk = ClaudeAdapter.normalize(line: "not json at all {{{ >>>")
        report.check(junk.messages.count == 1
                        && junk.messages[0].kind == .status
                        && junk.messages[0].status == "unparsed"
                        && junk.messages[0].text == "not json at all {{{ >>>",
                     "Claude adapter:非 JSON 垃圾行归一为 status=unparsed 且保留原始行(不崩不抛)")

        // 空行 / 全空白行:0 条消息,不是错误。
        report.check(ClaudeAdapter.normalize(line: "").messages.isEmpty,
                     "Claude adapter:空行产出 0 条消息(不报错)")
        report.check(ClaudeAdapter.normalize(line: "   \t ").messages.isEmpty,
                     "Claude adapter:全空白行产出 0 条消息(不报错)")

        // 超长不可解析行:截断到 512,日志不被撑爆。
        let long = ClaudeAdapter.normalize(line: String(repeating: "x", count: 900))
        report.check(long.messages.first?.text?.count == 512,
                     "Claude adapter:超长不可解析行截断到 512 字符(保诊断又不撑爆日志)")

        // 回归护栏(CR 结论):`subtype:"error_during_execution"` 但**不是** aborted_streaming 的执行期错误
        // —— 必须判 .failed。曾经的实现把该 subtype 也当 aborted 的充分条件,会把真失败伪装成「被取消」
        //    并凭空注入一条 interrupted 消息,上层连告警都不会发。八组样本里该分支零独立覆盖,故用构造行钉死。
        let executionError = ClaudeAdapter.normalize(
            line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"execution_error"}"#)
        report.check(executionError.terminal?.outcome == .failed,
                     "Claude adapter:非中断的 error_during_execution 判 failed(真失败绝不伪装成被取消)")
        report.check(!executionError.messages.contains { $0.status == AgentStatusCode.interrupted.rawValue },
                     "Claude adapter:非中断的 error_during_execution 不注入 interrupted 消息(不无中生有)")

        // 未知子块类型:不崩,保真上浮。
        let oddBlock = ClaudeAdapter.normalize(
            line: #"{"type":"assistant","message":{"content":[{"type":"brand_new_block"}]}}"#)
        report.check(oddBlock.messages.first?.status == "unknown-block:brand_new_block",
                     "Claude adapter:未知子块类型归一为 status=unknown-block:<type>(新增子块类型不打崩)")
    }

    // MARK: - ② baseline 只读样本:消息序列 + 会话起始 + 终态

    private static func testBaseline(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "01-baseline-readonly") else { return }
        let out = ClaudeAdapter.normalize(lines: lines)

        // 消息序列逐型钉死:system/init → rate_limit_event → assistant text。
        // **只有三条**:result 行的最终答复不产消息(它是最后一条 assistant text 的逐字回显,
        // 产成消息会让报告把结论打印两遍)——它进终态的 finalText,由下面两条断言钉死「挪位但不丢」。
        report.check(out.messages.map { $0.kind } == [.status, .status, .text],
                     "Claude adapter:baseline 只读样本消息序列=[status,status,text](终局答复不重复产消息)")
        report.check(out.terminal?.finalText == out.messages.last(where: { $0.kind == .text })?.text,
                     "Claude adapter:baseline 只读样本终态 finalText 与最后一条 text 消息逐字相同(挪位不丢信息)")
        report.check(out.terminal?.finalText?.isEmpty == false,
                     "Claude adapter:baseline 只读样本终局答复落在终态 finalText(报告兜底的取数处)")
        report.check(out.messages.first?.status == AgentStatusCode.sessionStarted.rawValue,
                     "Claude adapter:baseline 只读样本首条为 session-started 状态消息")
        report.check((out.sessionID?.isEmpty == false),
                     "Claude adapter:baseline 只读样本从 system/init 提取出非空 sessionID")
        report.check(out.messages.contains { $0.status == AgentStatusCode.rateLimit.rawValue && $0.text == "allowed" },
                     "Claude adapter:baseline 只读样本 rate_limit_event 归一为 rate-limit 状态(detail=allowed)")
        report.check(out.terminal?.outcome == .succeeded && out.terminal?.reason == "completed",
                     "Claude adapter:baseline 只读样本终态=succeeded(reason=completed)")
    }

    // MARK: - ③ tool-use 样本:callID 全链配对不丢

    private static func testToolUse(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "02-tool-use-bypass") else { return }
        let out = ClaudeAdapter.normalize(lines: lines)

        guard let use = out.messages.first(where: { $0.kind == .toolUse }),
              let result = out.messages.first(where: { $0.kind == .toolResult }) else {
            report.check(false, "Claude adapter:tool-use 样本应同时产出 tool-use 与 tool-result 消息")
            return
        }
        report.check(use.callID != nil && use.callID == result.callID,
                     "Claude adapter:tool-use 样本 tool-use 与 tool-result 的 callID 相等(全链配对不丢)")
        report.check(use.tool == "Write",
                     "Claude adapter:tool-use 样本工具名归一为 Write")
        report.check(use.input?.objectValue?["file_path"] != nil,
                     "Claude adapter:tool-use 样本入参 input 原样承载(含 file_path)")
        report.check(result.output?.stringValue != nil,
                     "Claude adapter:tool-use 样本 tool_result 的字符串 content 原样承载为 output")
        report.check(result.isError == nil,
                     "Claude adapter:tool-use 样本 tool_result 无 is_error 键时归一为 nil(不补默认 false)")
        report.check(out.terminal?.outcome == .succeeded,
                     "Claude adapter:tool-use 样本终态=succeeded")
    }

    // MARK: - ④ 越界写样本(07):归一化层面与正常写无差别

    private static func testCwdEscape(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "07-cwd-escape") else { return }
        let out = ClaudeAdapter.normalize(lines: lines)

        report.check(out.terminal?.outcome == .succeeded,
                     "Claude adapter:越界写样本(07)终态=succeeded(cwd 不是安全边界,归一化层面无差别)")
        let uses = out.messages.filter { $0.kind == .toolUse }
        let results = out.messages.filter { $0.kind == .toolResult }
        report.check(uses.count == 2 && results.count == 2,
                     "Claude adapter:越界写样本(07)两次 Write 各归一为 tool-use + tool-result")
        let useIDs = Set(uses.compactMap { $0.callID })
        let resultIDs = Set(results.compactMap { $0.callID })
        report.check(useIDs.count == 2 && useIDs == resultIDs,
                     "Claude adapter:越界写样本(07)两对调用的 callID 集合一一对上(多次调用不串档)")
        report.check(out.messages.contains { $0.kind == .thinking },
                     "Claude adapter:越界写样本(07)thinking 子块归一为 thinking 型消息")
        report.check(out.messages.contains { $0.status == "system:thinking_tokens" },
                     "Claude adapter:越界写样本(07)未枚举的 system 子类型保真为 status=system:thinking_tokens")
    }

    // MARK: - ⑤ 中断样本(04):aborted 判定必须排在 failed 之前

    private static func testInterrupted(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "04-sigterm-interrupt") else { return }
        let out = ClaudeAdapter.normalize(lines: lines)

        report.check(out.terminal?.outcome == .aborted,
                     "Claude adapter:中断样本(04)终态=aborted(该样本 is_error 也为 true,判定顺序 aborted 在 failed 前)")
        report.check(out.terminal?.finalText == nil,
                     "Claude adapter:中断样本(04)无终局答复(result 为 null → finalText 为 nil,不造空结论)")
        report.check(out.terminal?.reason == "aborted_streaming",
                     "Claude adapter:中断样本(04)终态 reason 保真为 aborted_streaming")
        report.check(out.messages.contains { $0.status == AgentStatusCode.interrupted.rawValue },
                     "Claude adapter:中断样本(04)额外产出 interrupted 状态消息(中断在消息流里也可见)")
        report.check(out.messages.contains { $0.kind == .status
                                                && $0.status == "user:text"
                                                && $0.text == "[Request interrupted by user]" },
                     "Claude adapter:中断样本(04)user 文本归一为 status=user:text(保留原文)")
        report.check(!out.messages.contains { $0.kind == .text },
                     "Claude adapter:中断样本(04)中断提示绝不归一为 agent 的 text 输出(不混淆发言方)")
    }

    // MARK: - ⑥ invalid-model 样本(05):不能只看 subtype

    private static func testInvalidModel(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "05-invalid-model") else { return }
        let out = ClaudeAdapter.normalize(lines: lines)

        report.check(out.terminal?.outcome == .failed,
                     "Claude adapter:invalid-model 样本(05)终态=failed(is_error/api_error_status/terminal_reason 联合判定)")
        report.check(out.terminal?.reason == "api_error",
                     "Claude adapter:invalid-model 样本(05)终态 reason 保真为 api_error")
        report.check(out.terminal?.finalText?.contains("model") == true,
                     "Claude adapter:invalid-model 样本(05)失败终态也带 finalText(失败原因文本不丢)")
        // 回归护栏:直接在**原始行字面**上断言 subtype 仍是 "success" —— 一旦有人把终态判定退化成看 subtype,这条即红。
        let resultLine = lines.first { $0.contains("\"type\":\"result\"") }
        report.check(resultLine?.contains("\"subtype\":\"success\"") == true,
                     "Claude adapter:invalid-model 样本(05)原生 subtype 字面仍是 success —— 终态判定绝不能只看 subtype")
    }

    // MARK: - ⑦ 被拒样本(03):被拒信号可识别,且终态仍是 succeeded

    private static func testPermissionDenied(_ report: inout AgentTestReport, _ dir: String) {
        guard let lines = loadSample(&report, dir, "03-no-bypass-control-request") else { return }
        let out = ClaudeAdapter.normalize(lines: lines)

        guard let denied = out.messages.first(where: { $0.status == AgentStatusCode.permissionDenied.rawValue }) else {
            report.check(false, "Claude adapter:被拒样本(03)应产出 permission-denied 状态消息")
            return
        }
        report.check(denied.kind == .status && denied.tool == "Write",
                     "Claude adapter:被拒样本(03)产出 permission-denied 状态消息(kind=status,保留工具名 Write)")
        report.check(denied.input?.objectValue?["file_path"] != nil,
                     "Claude adapter:被拒样本(03)permission-denied 保留被拒入参 tool_input(全链可追溯)")

        let erroredResult = out.messages.first { $0.kind == .toolResult && $0.isError == true }
        report.check(erroredResult?.callID != nil && erroredResult?.callID == denied.callID,
                     "Claude adapter:被拒样本(03)permission-denied 的 callID 与 is_error=true 的 tool_result 对得上")
        report.check(out.terminal?.outcome == .succeeded,
                     "Claude adapter:被拒样本(03)终态=succeeded(被拒 ≠ 终态失败,不能靠终态判断有没有被拒)")
        report.check(out.messages.filter { $0.status == "system:api_retry" }.count == 5,
                     "Claude adapter:被拒样本(03)5 条 api_retry 归一为 status=system:api_retry(原生保真兜底)")
    }

    // MARK: - 样本装载(fail-closed)

    /// 解析样本目录:`AA_SPIKE_DIR`(check.sh 注入)+ `/spike-claude-headless`。缺失 / 不存在 → 记 FAIL 并返回 nil。
    private static func spikeDirectory(_ report: inout AgentTestReport) -> String? {
        // 单次求值 + 单次 check:不写字面恒真的 `check(true, …)`(那种写法一旦上面的 guard 被重构掉就静默常绿)。
        let root = ProcessInfo.processInfo.environment["AA_SPIKE_DIR"]
        let injected = (root?.isEmpty == false)
        report.check(injected, "Claude adapter:样本目录环境变量 AA_SPIKE_DIR 已注入(缺失即 fail-closed)")
        guard injected, let root = root else { return nil }
        let dir = root + "/spike-claude-headless"
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
        report.check(exists && isDirectory.boolValue,
                     "Claude adapter:spike 黄金样本目录存在(不存在即 fail-closed,绝不静默跳过)")
        return (exists && isDirectory.boolValue) ? dir : nil
    }

    /// 读一个样本的全部行(含空行:归一化必须能吃下 NDJSON 尾部空行)。读不出 → 记 FAIL 并返回 nil。
    private static func loadSample(_ report: inout AgentTestReport, _ dir: String, _ name: String) -> [String]? {
        let path = dir + "/" + name + ".stdout.ndjson"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            report.check(false, "Claude adapter:黄金样本可读 —— \(name)(读不出即 fail-closed)")
            return nil
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
