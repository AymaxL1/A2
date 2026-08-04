// 17 票:从 `AAAgentTestKit.CodexAdapterTests` 迁到 swift-testing
//   (迁移口径见 Tests/AAHostTestKitTests/RegistryConformanceTests.swift 头注)。
//
// CodexAdapter 归一化的黄金样本测试(agent-delegation 03 票:喂 02 spike 落盘的**真实** NDJSON)。
// 样本路径经 `AA_SPIKE_DIR` 注入(17 票起由 `Scripts/check/swift-test.sh` export),fail-closed 口径一字未改。

import Foundation
import Testing
import AAContracts
import AAAgentCore

@Suite("agent 03 Codex 黄金样本归一化 —— CODEXADAPTER_TESTS passed=(逐条 @Test)")
struct CodexAdapterTests {

    // MARK: - 样本装载(fail-closed)

    /// spike 样本目录:`AA_SPIKE_DIR`(swift-test.sh 注入)+ `/spike-codex-exec/samples`。
    private static func spikeDirectory(sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let root = ProcessInfo.processInfo.environment["AA_SPIKE_DIR"]
        let injected = (root?.isEmpty == false)
        let unwrapped = try #require(injected ? root : nil,
                                     "Codex adapter:样本目录环境变量 AA_SPIKE_DIR 已注入(缺失即 fail-closed)",
                                     sourceLocation: sourceLocation)
        return unwrapped + "/spike-codex-exec/samples"
    }

    /// 读一个样本的全部行(含空行:归一化必须能吃下 NDJSON 尾部空行)。读不出 → FAIL 并抛出。
    private static func loadSample(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let dir = try spikeDirectory(sourceLocation: sourceLocation)
        let path = dir + "/" + name + ".stdout.jsonl"
        let data = try #require(FileManager.default.contents(atPath: path),
                                "Codex adapter:黄金样本可读 —— \(name)(读不出即 fail-closed)",
                                sourceLocation: sourceLocation)
        let text = try #require(String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 },
                                "Codex adapter:黄金样本可读 —— \(name)(读不出即 fail-closed)",
                                sourceLocation: sourceLocation)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test("Codex adapter:spike 黄金样本目录存在(不存在即 fail-closed,绝不静默跳过)")
    func spikeDirectoryExists() throws {
        let dir = try Self.spikeDirectory()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue,
                "Codex adapter:spike 黄金样本目录存在(不存在即 fail-closed,绝不静默跳过)")
    }

    // MARK: - ① 兜底:未知事件 / 畸形 item(纯函数,无需样本)

    @Test("Codex adapter:未知顶层事件 / 未知 item 类型 / 缺 item 载荷 / 缺 type 键都走兜底且不崩")
    func fallbackUnknownShapes() {
        // 未知顶层事件(上游新增事件类型):记录不崩、不产终态。
        let unknown = CodexAdapter.normalize(line: #"{"type":"brand_new_event","payload":42}"#)
        #expect(unknown.messages.count == 1
                && unknown.messages[0].kind == .status
                && unknown.messages[0].status == "unknown:brand_new_event"
                && unknown.terminal == nil,
                "Codex adapter:未知顶层事件归一为 status=unknown:brand_new_event(新增事件类型不打崩、不产终态)")
        #expect(unknown.messages.first?.text?.contains("payload") == true,
                "Codex adapter:未知顶层事件保留原始行文本(可诊断)")

        // 未知 item 类型:保真上浮且**保住 callID**。
        let oddItem = CodexAdapter.normalize(
            line: #"{"type":"item.started","item":{"id":"item_9","type":"file_change"}}"#)
        #expect(oddItem.messages.first?.status == "unknown-item:file_change"
                && oddItem.messages.first?.callID == "item_9",
                "Codex adapter:未知 item 类型归一为 status=unknown-item:file_change 且保留 callID=item_9")

        // 缺 item 载荷的畸形事件:走同一条兜底路,不崩。
        let noItem = CodexAdapter.normalize(line: #"{"type":"item.completed"}"#)
        #expect(noItem.messages.first?.status == "unknown-item:(missing)",
                "Codex adapter:item 事件缺 item 载荷时归一为 status=unknown-item:(missing)(畸形行不崩)")

        // 缺 type 键:走哨兵串兜底(不特判、不崩)。
        #expect(CodexAdapter.normalize(line: #"{"foo":1}"#).messages.first?.status == "unknown:(missing)",
                "Codex adapter:缺 type 键的 JSON 行归一为 status=unknown:(missing)")
    }

    @Test("Codex adapter:顶层 error 归一为 error 型消息且绝不产终态(瞬态重连噪音不是失败)")
    func fallbackTransientErrorIsNotTerminal() {
        // **本票最关键的一条回归护栏**:顶层 error 行是瞬态重连噪音,单独出现时绝不产终态。
        let transient = CodexAdapter.normalize(
            line: #"{"type":"error","message":"Reconnecting... 2/5 (request timed out)"}"#)
        #expect(transient.messages.count == 1
                && transient.messages[0].kind == .error
                && transient.messages[0].text?.contains("Reconnecting") == true
                && transient.terminal == nil,
                "Codex adapter:顶层 error 归一为 error 型消息且绝不产终态(瞬态重连噪音不是失败)")

        // 票面「stderr 的 ERROR 字样不作失败判据」的可测落点(CR 建议)。
        let stderrNoise = CodexAdapter.normalize(
            line: "ERROR codex_api::endpoint::responses_websocket: failed to connect")
        #expect(stderrNoise.terminal == nil
                && stderrNoise.messages.first?.status == "unparsed",
                "Codex adapter:stderr 的 ERROR 噪音行只走 unparsed 降级、绝不产终态(ERROR 字样不是失败判据)")
    }

    @Test("Codex adapter:垃圾行 / 空行 / 超长行的降级行为(不崩不抛、截断到 512、不产终态)")
    func fallbackMalformedLines() {
        let junk = CodexAdapter.normalize(line: "not json at all {{{ >>>")
        #expect(junk.messages.count == 1
                && junk.messages[0].kind == .status
                && junk.messages[0].status == "unparsed"
                && junk.messages[0].text == "not json at all {{{ >>>"
                && junk.terminal == nil,
                "Codex adapter:非 JSON 垃圾行归一为 status=unparsed 且保留原始行、不产终态(不崩不抛)")
        #expect(CodexAdapter.normalize(line: "").messages.isEmpty,
                "Codex adapter:空行产出 0 条消息(不报错)")
        #expect(CodexAdapter.normalize(line: "  \t ").messages.isEmpty,
                "Codex adapter:全空白行产出 0 条消息(不报错)")
        let long = CodexAdapter.normalize(line: String(repeating: "x", count: 900))
        #expect(long.messages.first?.text?.count == 512,
                "Codex adapter:超长不可解析行截断到 512 字符(与 Claude 侧同口径)")
    }

    @Test("Codex adapter:turn.failed 缺 error.message / 双层解码内层为空 两支降级(八个样本都触发不到)")
    func fallbackTurnFailedDegradations() {
        //   ① turn.failed 缺 error.message —— 理由如实留 nil,但消息流仍留一条带原始行的 error(可诊断优先)。
        let failedNoMessage = CodexAdapter.normalize(line: #"{"type":"turn.failed"}"#)
        #expect(failedNoMessage.terminal?.outcome == .failed
                && failedNoMessage.terminal?.reason == nil
                && failedNoMessage.messages.first?.kind == .error,
                "Codex adapter:turn.failed 缺 error.message 时终态仍 failed、reason 如实留 nil(不臆造理由)")
        //   ② 双层解码解得开、但内层 error.message 为空 —— 原样退回外层串。
        let emptyInner = CodexAdapter.normalize(
            line: #"{"type":"turn.failed","error":{"message":"{\"error\":{\"message\":\"\"}}"}}"#)
        #expect(emptyInner.terminal?.reason?.isEmpty == false,
                "Codex adapter:双层解码内层为空时退回外层原串(解得开也不交回空理由)")
    }

    // MARK: - ② baseline 只读样本(exec1)

    @Test("Codex adapter:baseline 样本(exec1)消息序列、thread_id → sessionID、终态 succeeded")
    func baseline() throws {
        let lines = try Self.loadSample("exec1-baseline-readonly-default")
        let out = CodexAdapter.normalize(lines: lines)

        #expect(out.messages.map { $0.kind } == [.status, .status, .toolUse, .toolResult, .text, .status],
                "Codex adapter:baseline 样本(exec1)消息序列=[status,status,tool-use,tool-result,text,status]")
        #expect(out.messages.first?.status == AgentStatusCode.sessionStarted.rawValue
                && lines.first?.contains("thread.started") == true,
                "Codex adapter:baseline 样本(exec1)首行 thread.started 归一为 session-started 状态消息")
        #expect(out.sessionID == "019faa09-dcf2-75d2-b83c-28e95e20e800",
                "Codex adapter:baseline 样本(exec1)sessionID 逐字取自首行 thread_id(不必等文件落盘)")
        #expect(out.messages.contains { $0.status == AgentStatusCode.turnStarted.rawValue }
                && out.messages.last?.status == AgentStatusCode.turnCompleted.rawValue,
                "Codex adapter:baseline 样本(exec1)turn.started/turn.completed 归一为 turn-started/turn-completed")
        #expect(out.terminal?.outcome == .succeeded && out.terminal?.reason == "turn.completed",
                "Codex adapter:baseline 样本(exec1)终态=succeeded(reason=turn.completed)")
        #expect(out.terminal?.finalText == nil,
                "Codex adapter:baseline 样本(exec1)终态 finalText 恒为 nil(Codex 原生无终局答复字段,04 退回取最后一条 text)")

        guard let use = out.messages.first(where: { $0.kind == .toolUse }),
              let result = out.messages.first(where: { $0.kind == .toolResult }) else {
            Issue.record("Codex adapter:baseline 样本(exec1)应同时产出 tool-use 与 tool-result 消息")
            return
        }
        #expect(use.tool == "command_execution" && use.callID == "item_0",
                "Codex adapter:baseline 样本(exec1)command_execution 归一为 tool-use(工具名照搬 item.type,callID=item_0)")
        #expect(use.input?.objectValue?["command"]?.stringValue?.contains("ls -la") == true,
                "Codex adapter:baseline 样本(exec1)tool-use 入参承载原生 command 串")
        #expect(result.output?.objectValue?["aggregated_output"] != nil
                && result.output?.objectValue?["exit_code"] != nil,
                "Codex adapter:baseline 样本(exec1)tool-result 产物承载 aggregated_output 与 exit_code")
        #expect(result.isError == false,
                "Codex adapter:baseline 样本(exec1)exit_code=0 且 status=completed 时 isError=false")
        #expect(out.messages.first(where: { $0.kind == .text })?.text == "0",
                "Codex adapter:baseline 样本(exec1)agent_message 归一为 text 型消息(内容逐字保真)")
    }

    // MARK: - ③ 写尝试样本(exec2):callID 配对 + 工具失败 ≠ 回合失败

    @Test("Codex adapter:写尝试样本(exec2)callID 配对不丢,且工具失败不等于回合失败")
    func writeAttempt() throws {
        let lines = try Self.loadSample("exec2-default-write-attempt")
        let out = CodexAdapter.normalize(lines: lines)

        guard let use = out.messages.first(where: { $0.kind == .toolUse }),
              let result = out.messages.first(where: { $0.kind == .toolResult }) else {
            Issue.record("Codex adapter:写尝试样本(exec2)应同时产出 tool-use 与 tool-result 消息")
            return
        }
        #expect(use.callID == "item_1" && use.callID == result.callID,
                "Codex adapter:写尝试样本(exec2)item.started 与 item.completed 同一个 item_1 归一为相等 callID(全链配对不丢)")
        #expect(result.isError == true
                && result.output?.objectValue?["exit_code"] == JSONValue.number(1),
                "Codex adapter:写尝试样本(exec2)status=failed 且 exit_code=1 时 isError=true")
        #expect(out.terminal?.outcome == .succeeded,
                "Codex adapter:写尝试样本(exec2)工具失败但终态仍是 succeeded(工具失败不等于回合失败)")
        #expect(out.messages.filter { $0.kind == .text }.count == 2,
                "Codex adapter:写尝试样本(exec2)两条 agent_message 各归一为一条 text 消息")
        #expect(!out.messages.contains { $0.status == AgentStatusCode.permissionDenied.rawValue },
                "Codex adapter:写尝试样本(exec2)不产 permission-denied 消息(Codex 侧无可识别的拒绝信号)")
    }

    // MARK: - ④ 硬超时样本(exec3):Reconnecting 噪音不产终态

    @Test("Codex adapter:硬超时样本(exec3)terminal 恒为 nil,4 条 Reconnecting 各归一为 error 消息")
    func reconnectTimeout() throws {
        let lines = try Self.loadSample("exec3-readonly-explicit-write")
        let out = CodexAdapter.normalize(lines: lines)

        #expect(out.terminal == nil,
                "Codex adapter:硬超时样本(exec3)terminal 恒为 nil(流里没有终态行就绝不臆造,终态由上层据退出码补)")
        let errors = out.messages.filter { $0.kind == .error }
        #expect(errors.count == 4 && errors.allSatisfy { $0.text?.contains("Reconnecting") == true },
                "Codex adapter:硬超时样本(exec3)4 条 Reconnecting 各归一为一条 error 消息")
        #expect(lines.allSatisfy { CodexAdapter.normalize(line: $0).terminal == nil },
                "Codex adapter:硬超时样本(exec3)逐行归一化没有任何一行产出终态(error 行绝不是失败判据)")
        #expect(out.sessionID?.isEmpty == false,
                "Codex adapter:硬超时样本(exec3)即使无终态也已提取出 sessionID(续接指针不丢)")
    }

    // MARK: - ⑤ 静默空气墙(exec3b)

    @Test("Codex adapter:静默空气墙样本(exec3b)被拦的写连 item 都不出现,V1 不合成拒绝消息")
    func silentDenial() throws {
        let lines = try Self.loadSample("exec3b-readonly-explicit-write-retry")
        let out = CodexAdapter.normalize(lines: lines)

        #expect(!out.messages.contains { $0.kind == .toolUse || $0.kind == .toolResult },
                "Codex adapter:静默空气墙样本(exec3b)被拦的写在流里连 item 都不出现,故零条 tool-use/tool-result")
        #expect(!out.messages.contains { $0.status == AgentStatusCode.permissionDenied.rawValue },
                "Codex adapter:静默空气墙样本(exec3b)V1 绝不合成 permission-denied 消息(Codex 侧拒绝不可识别,不臆造)")
        #expect(out.terminal?.outcome == .succeeded,
                "Codex adapter:静默空气墙样本(exec3b)终态=succeeded(被拦不等于回合失败)")
        #expect(out.messages.filter { $0.kind == .text }.count == 2,
                "Codex adapter:静默空气墙样本(exec3b)只剩两条 agent_message 文本(拒绝只能靠事后 diff 文件树反推)")
    }

    // MARK: - ⑥ 沙箱边界样本(exec4)

    @Test("Codex adapter:沙箱边界样本(exec4)只有 cwd 内那次留下一对 item,越界那次零痕迹")
    func workspaceBoundary() throws {
        let lines = try Self.loadSample("exec4-workspace-write-cfg-boundary-nopath")
        let out = CodexAdapter.normalize(lines: lines)

        let uses = out.messages.filter { $0.kind == .toolUse }
        let results = out.messages.filter { $0.kind == .toolResult }
        #expect(uses.count == 1 && results.count == 1 && uses.first?.callID == results.first?.callID,
                "Codex adapter:沙箱边界样本(exec4)两次强制调用只有 cwd 内那次留下一对 item,越界那次归一化后同样零痕迹")
        #expect(results.first?.isError == false,
                "Codex adapter:沙箱边界样本(exec4)cwd 内写 exit_code=0 归一为 isError=false")
        #expect(out.terminal?.outcome == .succeeded,
                "Codex adapter:沙箱边界样本(exec4)终态=succeeded")
    }

    // MARK: - ⑦ 中断样本(exec5):流只到 turn.started,terminal 恒为 nil

    @Test("Codex adapter:中断样本(exec5)terminal 恒为 nil(与 Claude 侧不对称)")
    func interrupted() throws {
        let lines = try Self.loadSample("exec5-interrupt-sigterm-midrun")
        let out = CodexAdapter.normalize(lines: lines)

        #expect(out.terminal == nil,
                "Codex adapter:中断样本(exec5)terminal 恒为 nil(Codex 被信号杀不补终态行,与 Claude 侧不对称)")
        #expect(out.messages.map { $0.kind } == [.status, .status]
                && out.messages.map { $0.status } == [AgentStatusCode.sessionStarted.rawValue,
                                                      AgentStatusCode.turnStarted.rawValue],
                "Codex adapter:中断样本(exec5)消息只有 session-started 与 turn-started 两条(流被原样截断)")
        #expect(out.sessionID?.isEmpty == false,
                "Codex adapter:中断样本(exec5)仍提取出 sessionID(被中断的任务也留得下续接指针)")
        #expect(!out.messages.contains { $0.status == AgentStatusCode.interrupted.rawValue },
                "Codex adapter:中断样本(exec5)不注入 interrupted 消息(事件流看不出是被杀还是自己崩,交由上层据退出码判)")
    }

    // MARK: - ⑧ invalid-model 样本(exec6):turn.failed 的双层编码错因

    @Test("Codex adapter:invalid-model 样本(exec6)双层解码后 reason 是内层那句人话")
    func invalidModel() throws {
        let lines = try Self.loadSample("exec6-failure-invalid-model")
        let out = CodexAdapter.normalize(lines: lines)

        #expect(out.terminal?.outcome == .failed,
                "Codex adapter:invalid-model 样本(exec6)终态=failed(唯一判据是 turn.failed 行)")
        guard let reason = out.terminal?.reason else {
            Issue.record("Codex adapter:invalid-model 样本(exec6)终态应带 reason")
            return
        }
        #expect(reason.contains("not supported when using Codex with a ChatGPT account"),
                "Codex adapter:invalid-model 样本(exec6)双层解码后 reason 是内层那句人话")
        #expect(!reason.contains("invalid_request_error") && !reason.contains("{"),
                "Codex adapter:invalid-model 样本(exec6)reason 不残留外层 JSON 字面(双层解码真解到了内层)")
        #expect(out.messages.contains { $0.kind == .error && $0.text == reason },
                "Codex adapter:invalid-model 样本(exec6)终态理由同时留一条 error 消息(按序渲染时看得见死因)")
        #expect(out.messages.contains { $0.kind == .error && $0.text?.contains("invalid_request_error") == true },
                "Codex adapter:invalid-model 样本(exec6)顶层 error 行原样保真不解码(诊断面要如实,判定面才收敛)")
        #expect(out.messages.contains { $0.kind == .error && $0.text?.contains("Model metadata for") == true },
                "Codex adapter:invalid-model 样本(exec6)item 级 error 警告归一为 error 型消息")
        #expect(!out.messages.contains { $0.status == AgentStatusCode.turnCompleted.rawValue },
                "Codex adapter:invalid-model 样本(exec6)全流无 turn.completed(失败回合不产成功状态消息)")
    }

    // MARK: - ⑨ 无鉴权样本(exec7):双层解码优雅退化

    @Test("Codex adapter:无鉴权样本(exec7)error.message 非 JSON 时 reason 逐字退化为原串")
    func noAuth() throws {
        let lines = try Self.loadSample("exec7-no-auth-isolation-check")
        let out = CodexAdapter.normalize(lines: lines)

        #expect(out.terminal?.outcome == .failed,
                "Codex adapter:无鉴权样本(exec7)终态=failed")
        guard let reason = out.terminal?.reason else {
            Issue.record("Codex adapter:无鉴权样本(exec7)终态应带 reason")
            return
        }
        #expect(reason.hasPrefix("unexpected status 401 Unauthorized")
                && reason.contains("request id:"),
                "Codex adapter:无鉴权样本(exec7)error.message 非 JSON 时 reason 逐字退化为原串(解不出不丢信息、不崩)")
        #expect(out.messages.filter { $0.kind == .error }.count == 12,
                "Codex adapter:无鉴权样本(exec7)11 条流内 error 加终态那条共 12 条 error 消息(重连噪音一条不吞)")
        #expect(out.messages.filter { $0.kind == .error }.filter { $0.text?.contains("Reconnecting") == true }.count == 9,
                "Codex adapter:无鉴权样本(exec7)两级传输各 5 次重连中的 9 条 Reconnecting 全部归一为 error 消息")
        #expect(out.messages.filter { $0.kind == .status }.count == 2,
                "Codex adapter:无鉴权样本(exec7)只有 session-started 与 turn-started 两条 status(失败回合无 turn-completed)")
    }
}
