// 17 票:从 `AAAgentTestKit.ClaudeAdapterTests` 迁到 swift-testing
//   (迁移口径见 Tests/AAHostTestKitTests/RegistryConformanceTests.swift 头注)。
//
// ClaudeAdapter 归一化的黄金样本测试(agent-delegation 02 票:喂 01 spike 落盘的**真实** NDJSON)。
//
// 为什么从磁盘真读样本、而不是把样本贴成 Swift 字符串常量:
//   `.scratch/agent-delegation/research/spike-claude-headless/*.stdout.ndjson` 是 01 spike 真调 Claude 落盘的
//   **单一真相源**(已入库)。复制成常量会立刻产生第二份真相:样本更新后常量不动,测试就开始守着过期的形状。
//   故这里读真文件,路径经环境变量 `AA_SPIKE_DIR` 注入 —— 17 票之前由 `Scripts/check/unit-and-domain.sh`
//   在调 registry-tests 时注入,**迁移后改由 `Scripts/check/swift-test.sh` 以命令前缀注入**
//   (刻意不 `export` —— 只给 `swift test` 这一条命令,不污染后续 E2E 断言组的环境)。
//   **fail-closed 一字未改**:环境变量缺失 / 目录不存在 / 文件读不出 → 一律 FAIL,绝不静默跳过
//   (否则样本挪走后测试会「全绿地什么都没测」——比红更危险)。

import Foundation
import Testing
import AAContracts
import AAAgentCore

@Suite("agent 02 Claude 黄金样本归一化 —— CLAUDEADAPTER_TESTS passed=(逐条 @Test)")
struct ClaudeAdapterTests {

    // MARK: - 样本装载(fail-closed)

    /// spike 样本目录:`AA_SPIKE_DIR`(swift-test.sh 注入)+ `/spike-claude-headless`。
    private static func spikeDirectory(sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let root = ProcessInfo.processInfo.environment["AA_SPIKE_DIR"]
        let injected = (root?.isEmpty == false)
        let unwrapped = try #require(injected ? root : nil,
                                     "Claude adapter:样本目录环境变量 AA_SPIKE_DIR 已注入(缺失即 fail-closed)",
                                     sourceLocation: sourceLocation)
        return unwrapped + "/spike-claude-headless"
    }

    /// 读一个样本的全部行(含空行:归一化必须能吃下 NDJSON 尾部空行)。读不出 → FAIL 并抛出。
    private static func loadSample(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let dir = try spikeDirectory(sourceLocation: sourceLocation)
        let path = dir + "/" + name + ".stdout.ndjson"
        let data = try #require(FileManager.default.contents(atPath: path),
                                "Claude adapter:黄金样本可读 —— \(name)(读不出即 fail-closed)",
                                sourceLocation: sourceLocation)
        let text = try #require(String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 },
                                "Claude adapter:黄金样本可读 —— \(name)(读不出即 fail-closed)",
                                sourceLocation: sourceLocation)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test("Claude adapter:spike 黄金样本目录存在(不存在即 fail-closed,绝不静默跳过)")
    func spikeDirectoryExists() throws {
        let dir = try Self.spikeDirectory()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue,
                "Claude adapter:spike 黄金样本目录存在(不存在即 fail-closed,绝不静默跳过)")
    }

    // MARK: - ① 兜底:未知双向消息 / 垃圾行 / 空行(纯函数,无需样本)

    @Test("Claude adapter:未知双向消息(control_request)与未知子块不打崩、不产终态")
    func fallbackUnknownEvents() {
        // 未知顶层事件(V1 不应答 control_request,只记录不崩)。
        let control = ClaudeAdapter.normalize(line: #"{"type":"control_request","request_id":"x"}"#)
        #expect(control.messages.count == 1
                && control.messages[0].kind == .status
                && control.messages[0].status == "unknown:control_request"
                && control.terminal == nil,
                "Claude adapter:control_request 归一为 status=unknown:control_request(未知双向消息不崩、不产终态)")
        #expect(control.messages.first?.text?.contains("request_id") == true,
                "Claude adapter:未知顶层事件保留原始行文本(可诊断)")

        // 未知子块类型:不崩,保真上浮。
        let oddBlock = ClaudeAdapter.normalize(
            line: #"{"type":"assistant","message":{"content":[{"type":"brand_new_block"}]}}"#)
        #expect(oddBlock.messages.first?.status == "unknown-block:brand_new_block",
                "Claude adapter:未知子块类型归一为 status=unknown-block:<type>(新增子块类型不打崩)")
    }

    @Test("Claude adapter:垃圾行 / 空行 / 超长行的降级行为(不崩不抛、截断到 512)")
    func fallbackMalformedLines() {
        // 非 JSON 垃圾行:降级成 unparsed,绝不抛/崩。
        let junk = ClaudeAdapter.normalize(line: "not json at all {{{ >>>")
        #expect(junk.messages.count == 1
                && junk.messages[0].kind == .status
                && junk.messages[0].status == "unparsed"
                && junk.messages[0].text == "not json at all {{{ >>>",
                "Claude adapter:非 JSON 垃圾行归一为 status=unparsed 且保留原始行(不崩不抛)")

        // 空行 / 全空白行:0 条消息,不是错误。
        #expect(ClaudeAdapter.normalize(line: "").messages.isEmpty,
                "Claude adapter:空行产出 0 条消息(不报错)")
        #expect(ClaudeAdapter.normalize(line: "   \t ").messages.isEmpty,
                "Claude adapter:全空白行产出 0 条消息(不报错)")

        // 超长不可解析行:截断到 512,日志不被撑爆。
        let long = ClaudeAdapter.normalize(line: String(repeating: "x", count: 900))
        #expect(long.messages.first?.text?.count == 512,
                "Claude adapter:超长不可解析行截断到 512 字符(保诊断又不撑爆日志)")
    }

    @Test("Claude adapter:非中断的 error_during_execution 判 failed(真失败绝不伪装成被取消)")
    func fallbackExecutionErrorIsFailure() {
        // 回归护栏(CR 结论):`subtype:"error_during_execution"` 但**不是** aborted_streaming 的执行期错误
        // —— 必须判 .failed。八组样本里该分支零独立覆盖,故用构造行钉死。
        let executionError = ClaudeAdapter.normalize(
            line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"execution_error"}"#)
        #expect(executionError.terminal?.outcome == .failed,
                "Claude adapter:非中断的 error_during_execution 判 failed(真失败绝不伪装成被取消)")
        #expect(!executionError.messages.contains { $0.status == AgentStatusCode.interrupted.rawValue },
                "Claude adapter:非中断的 error_during_execution 不注入 interrupted 消息(不无中生有)")
    }

    // MARK: - ② baseline 只读样本:消息序列 + 会话起始 + 终态

    @Test("Claude adapter:baseline 只读样本(01)消息序列、sessionID、rate-limit 与终态 succeeded")
    func baseline() throws {
        let lines = try Self.loadSample("01-baseline-readonly")
        let out = ClaudeAdapter.normalize(lines: lines)

        #expect(out.messages.map { $0.kind } == [.status, .status, .text],
                "Claude adapter:baseline 只读样本消息序列=[status,status,text](终局答复不重复产消息)")
        #expect(out.terminal?.finalText == out.messages.last(where: { $0.kind == .text })?.text,
                "Claude adapter:baseline 只读样本终态 finalText 与最后一条 text 消息逐字相同(挪位不丢信息)")
        #expect(out.terminal?.finalText?.isEmpty == false,
                "Claude adapter:baseline 只读样本终局答复落在终态 finalText(报告兜底的取数处)")
        #expect(out.messages.first?.status == AgentStatusCode.sessionStarted.rawValue,
                "Claude adapter:baseline 只读样本首条为 session-started 状态消息")
        #expect((out.sessionID?.isEmpty == false),
                "Claude adapter:baseline 只读样本从 system/init 提取出非空 sessionID")
        #expect(out.messages.contains { $0.status == AgentStatusCode.rateLimit.rawValue && $0.text == "allowed" },
                "Claude adapter:baseline 只读样本 rate_limit_event 归一为 rate-limit 状态(detail=allowed)")
        #expect(out.terminal?.outcome == .succeeded && out.terminal?.reason == "completed",
                "Claude adapter:baseline 只读样本终态=succeeded(reason=completed)")
    }

    // MARK: - ③ tool-use 样本:callID 全链配对不丢

    @Test("Claude adapter:tool-use 样本(02)tool-use↔tool-result 的 callID 全链配对不丢")
    func toolUse() throws {
        let lines = try Self.loadSample("02-tool-use-bypass")
        let out = ClaudeAdapter.normalize(lines: lines)

        guard let use = out.messages.first(where: { $0.kind == .toolUse }),
              let result = out.messages.first(where: { $0.kind == .toolResult }) else {
            Issue.record("Claude adapter:tool-use 样本应同时产出 tool-use 与 tool-result 消息")
            return
        }
        #expect(use.callID != nil && use.callID == result.callID,
                "Claude adapter:tool-use 样本 tool-use 与 tool-result 的 callID 相等(全链配对不丢)")
        #expect(use.tool == "Write",
                "Claude adapter:tool-use 样本工具名归一为 Write")
        #expect(use.input?.objectValue?["file_path"] != nil,
                "Claude adapter:tool-use 样本入参 input 原样承载(含 file_path)")
        #expect(result.output?.stringValue != nil,
                "Claude adapter:tool-use 样本 tool_result 的字符串 content 原样承载为 output")
        #expect(result.isError == nil,
                "Claude adapter:tool-use 样本 tool_result 无 is_error 键时归一为 nil(不补默认 false)")
        #expect(out.terminal?.outcome == .succeeded,
                "Claude adapter:tool-use 样本终态=succeeded")
    }

    // MARK: - ④ 越界写样本(07):归一化层面与正常写无差别

    @Test("Claude adapter:越界写样本(07)在归一化层面与正常写无差别(cwd 不是安全边界)")
    func cwdEscape() throws {
        let lines = try Self.loadSample("07-cwd-escape")
        let out = ClaudeAdapter.normalize(lines: lines)

        #expect(out.terminal?.outcome == .succeeded,
                "Claude adapter:越界写样本(07)终态=succeeded(cwd 不是安全边界,归一化层面无差别)")
        let uses = out.messages.filter { $0.kind == .toolUse }
        let results = out.messages.filter { $0.kind == .toolResult }
        #expect(uses.count == 2 && results.count == 2,
                "Claude adapter:越界写样本(07)两次 Write 各归一为 tool-use + tool-result")
        let useIDs = Set(uses.compactMap { $0.callID })
        let resultIDs = Set(results.compactMap { $0.callID })
        #expect(useIDs.count == 2 && useIDs == resultIDs,
                "Claude adapter:越界写样本(07)两对调用的 callID 集合一一对上(多次调用不串档)")
        #expect(out.messages.contains { $0.kind == .thinking },
                "Claude adapter:越界写样本(07)thinking 子块归一为 thinking 型消息")
        #expect(out.messages.contains { $0.status == "system:thinking_tokens" },
                "Claude adapter:越界写样本(07)未枚举的 system 子类型保真为 status=system:thinking_tokens")
    }

    // MARK: - ⑤ 中断样本(04):aborted 判定必须排在 failed 之前

    @Test("Claude adapter:中断样本(04)终态=aborted(判定顺序 aborted 在 failed 前)")
    func interrupted() throws {
        let lines = try Self.loadSample("04-sigterm-interrupt")
        let out = ClaudeAdapter.normalize(lines: lines)

        #expect(out.terminal?.outcome == .aborted,
                "Claude adapter:中断样本(04)终态=aborted(该样本 is_error 也为 true,判定顺序 aborted 在 failed 前)")
        #expect(out.terminal?.finalText == nil,
                "Claude adapter:中断样本(04)无终局答复(result 为 null → finalText 为 nil,不造空结论)")
        #expect(out.terminal?.reason == "aborted_streaming",
                "Claude adapter:中断样本(04)终态 reason 保真为 aborted_streaming")
        #expect(out.messages.contains { $0.status == AgentStatusCode.interrupted.rawValue },
                "Claude adapter:中断样本(04)额外产出 interrupted 状态消息(中断在消息流里也可见)")
        #expect(out.messages.contains { $0.kind == .status
                                        && $0.status == "user:text"
                                        && $0.text == "[Request interrupted by user]" },
                "Claude adapter:中断样本(04)user 文本归一为 status=user:text(保留原文)")
        #expect(!out.messages.contains { $0.kind == .text },
                "Claude adapter:中断样本(04)中断提示绝不归一为 agent 的 text 输出(不混淆发言方)")
    }

    // MARK: - ⑥ invalid-model 样本(05):不能只看 subtype

    @Test("Claude adapter:invalid-model 样本(05)终态=failed,而原生 subtype 字面仍是 success")
    func invalidModel() throws {
        let lines = try Self.loadSample("05-invalid-model")
        let out = ClaudeAdapter.normalize(lines: lines)

        #expect(out.terminal?.outcome == .failed,
                "Claude adapter:invalid-model 样本(05)终态=failed(is_error/api_error_status/terminal_reason 联合判定)")
        #expect(out.terminal?.reason == "api_error",
                "Claude adapter:invalid-model 样本(05)终态 reason 保真为 api_error")
        #expect(out.terminal?.finalText?.contains("model") == true,
                "Claude adapter:invalid-model 样本(05)失败终态也带 finalText(失败原因文本不丢)")
        // 回归护栏:直接在**原始行字面**上断言 subtype 仍是 "success" —— 一旦有人把终态判定退化成看 subtype,这条即红。
        let resultLine = lines.first { $0.contains("\"type\":\"result\"") }
        #expect(resultLine?.contains("\"subtype\":\"success\"") == true,
                "Claude adapter:invalid-model 样本(05)原生 subtype 字面仍是 success —— 终态判定绝不能只看 subtype")
    }

    // MARK: - ⑦ 被拒样本(03):被拒信号可识别,且终态仍是 succeeded

    @Test("Claude adapter:被拒样本(03)产出 permission-denied 状态消息(kind=status,保留工具名 Write)")
    func permissionDenied() throws {
        let lines = try Self.loadSample("03-no-bypass-control-request")
        let out = ClaudeAdapter.normalize(lines: lines)

        guard let denied = out.messages.first(where: { $0.status == AgentStatusCode.permissionDenied.rawValue }) else {
            Issue.record("Claude adapter:被拒样本(03)应产出 permission-denied 状态消息")
            return
        }
        #expect(denied.kind == .status && denied.tool == "Write",
                "Claude adapter:被拒样本(03)产出 permission-denied 状态消息(kind=status,保留工具名 Write)")
        #expect(denied.input?.objectValue?["file_path"] != nil,
                "Claude adapter:被拒样本(03)permission-denied 保留被拒入参 tool_input(全链可追溯)")

        let erroredResult = out.messages.first { $0.kind == .toolResult && $0.isError == true }
        #expect(erroredResult?.callID != nil && erroredResult?.callID == denied.callID,
                "Claude adapter:被拒样本(03)permission-denied 的 callID 与 is_error=true 的 tool_result 对得上")
        #expect(out.terminal?.outcome == .succeeded,
                "Claude adapter:被拒样本(03)终态=succeeded(被拒 ≠ 终态失败,不能靠终态判断有没有被拒)")
        #expect(out.messages.filter { $0.status == "system:api_retry" }.count == 5,
                "Claude adapter:被拒样本(03)5 条 api_retry 归一为 status=system:api_retry(原生保真兜底)")
    }
}
