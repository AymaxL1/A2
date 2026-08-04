// 17 票:从 `AAAgentTestKit.AAAgentCoreConformanceTests` 迁到 swift-testing
//   (迁移口径见 Tests/AAHostTestKitTests/RegistryConformanceTests.swift 头注)。
//
// AAAgentCore 骨架的纯逻辑一致性冒烟测试(agent-delegation 01 票:证明地基活着)。
// 依赖边:AAAgentTestKitTests → AAAgentTestKit(FakeAgentPort 等假件)、AAAgentCore、AAContracts。

import Foundation
import Testing
import AAContracts
import AAAgentCore
import AAAgentTestKit

@Suite("agent 01 核心消息与 FakeAgentPort —— AGENTCORE_TESTS passed=(逐条 @Test)")
struct AAAgentCoreConformanceTests {

    private static let spec = AgentLaunchSpec(
        executablePath: "/usr/local/bin/claude",
        arguments: ["-p", "--output-format", "stream-json"],
        environment: ["CODEX_HOME": "/tmp/task-x/codex"],
        workingDirectory: "/tmp/task-x/work",
        stdin: .writeThenKeepOpen(#"{"prompt":"hi"}"#)
    )

    // ============ ① FakeAgentPort 主 seam ============

    @Test("假 AgentPort:launch 如实记录启动规格(可执行路径 / 参数 / 工作目录 / stdin 处置)且拉起后探活为真")
    func fakeAgentPortLaunchRecordsSpec() throws {
        let port = FakeAgentPort()
        port.programEvents(["{}"])
        let h = try #require(try? port.launch(Self.spec), "假 AgentPort:launch 应成功返回句柄")

        #expect(port.launchCalls.count == 1, "假 AgentPort:launch 记录一次调用")
        #expect(port.launchCalls.first?.executablePath == "/usr/local/bin/claude",
                "假 AgentPort:launch 记录可执行路径")
        #expect(port.launchCalls.first?.arguments == ["-p", "--output-format", "stream-json"],
                "假 AgentPort:launch 记录参数")
        #expect(port.launchCalls.first?.workingDirectory == "/tmp/task-x/work",
                "假 AgentPort:launch 记录工作目录")
        #expect(port.launchCalls.first?.stdin == .writeThenKeepOpen(#"{"prompt":"hi"}"#),
                "假 AgentPort:launch 记录 stdin 处置(writeThenKeepOpen)")
        #expect(port.isAlive(h), "假 AgentPort:拉起后探活为真")
    }

    @Test("假 AgentPort:nextEvent 依次弹出预置脚本,弹完返回 nil;terminate 后探活为假且被记录")
    func fakeAgentPortReplayAndTerminate() throws {
        let port = FakeAgentPort()
        let script = [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"assistant","text":"hello"}"#,
            #"{"type":"result","subtype":"success"}"#
        ]
        port.programEvents(script)
        let h = try #require(try? port.launch(Self.spec), "假 AgentPort:launch 应成功返回句柄(回放用例前置)")

        #expect(port.nextEvent(h) == script[0], "假 AgentPort:nextEvent 依次弹出预置脚本第 1 行")
        #expect(port.nextEvent(h) == script[1], "假 AgentPort:nextEvent 依次弹出预置脚本第 2 行")
        #expect(port.nextEvent(h) == script[2], "假 AgentPort:nextEvent 依次弹出预置脚本第 3 行")
        #expect(port.nextEvent(h) == nil, "假 AgentPort:脚本弹完后 nextEvent 返回 nil")

        port.terminate(h)
        #expect(!port.isAlive(h), "假 AgentPort:终止后探活为假")
        #expect(port.terminateCalls.count == 1 && port.terminateCalls.first == h,
                "假 AgentPort:终止调用被记录(取消/反孤儿可核验)")
    }

    @Test("假 AgentPort:进程中途死亡后 nextEvent 返回 nil(脚本未弹完亦然)、探活为假")
    func fakeAgentPortMidRunDeath() throws {
        let port = FakeAgentPort()
        port.programEvents(["still-buffered-1", "still-buffered-2"])
        let h2 = try #require(try? port.launch(Self.spec), "假 AgentPort:第二次 launch 应成功")
        port.simulateDeath(h2)
        #expect(port.nextEvent(h2) == nil, "假 AgentPort:进程中途死亡后 nextEvent 返回 nil(脚本未弹完亦然)")
        #expect(!port.isAlive(h2), "假 AgentPort:进程中途死亡后探活为假")
    }

    @Test("假 AgentPort:programNextLaunchToFail 后 launch 抛错")
    func fakeAgentPortProgrammedLaunchFailure() {
        let port = FakeAgentPort()
        port.programNextLaunchToFail()
        var threw = false
        do { _ = try port.launch(Self.spec) } catch { threw = true }
        #expect(threw, "假 AgentPort:programNextLaunchToFail 后 launch 抛错")
    }

    // ============ ② AgentMessage 6 型模型 ============

    @Test("AgentMessage:6 型便利构造器各自 kind 与关键字段正确")
    func agentMessageConstructors() {
        let t  = AgentMessage.text("hello")
        let th = AgentMessage.thinking("pondering")
        let tu = AgentMessage.toolUse(callID: "call_1", tool: "bash", input: .object(["cmd": .string("ls")]))
        let tr = AgentMessage.toolResult(callID: "call_1", output: .string("file.txt"), isError: false)
        let st = AgentMessage.status("running")
        let er = AgentMessage.error("boom")

        #expect(t.kind == .text && t.text == "hello", "AgentMessage.text:kind=text 且 text 内容正确")
        #expect(th.kind == .thinking && th.text == "pondering", "AgentMessage.thinking:kind=thinking 且 text 内容正确")
        #expect(tu.kind == .toolUse && tu.tool == "bash" && tu.callID == "call_1" && tu.input != nil,
                "AgentMessage.toolUse:kind/tool/callID/input 正确")
        #expect(tr.kind == .toolResult && tr.callID == "call_1" && tr.isError == false && tr.output != nil,
                "AgentMessage.toolResult:kind/callID/output/isError 正确")
        #expect(st.kind == .status && st.status == "running", "AgentMessage.status:kind=status 且 status 串正确")
        #expect(er.kind == .error && er.text == "boom", "AgentMessage.error:kind=error 且 text 内容正确")
    }

    @Test("AgentMessage:tool-use / tool-result 的 callID 经 Codable round-trip 保留(修 multica 丢 CallID 的有损点)")
    func agentMessageCallIDRoundTrip() {
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        let tu = AgentMessage.toolUse(callID: "call_1", tool: "bash", input: .object(["cmd": .string("ls")]))
        let tr = AgentMessage.toolResult(callID: "call_1", output: .string("file.txt"), isError: false)

        if let d = try? enc.encode(tu), let back = try? dec.decode(AgentMessage.self, from: d) {
            #expect(back.callID == "call_1", "AgentMessage:toolUse 的 callID 经 Codable round-trip 保留")
        } else {
            Issue.record("AgentMessage:toolUse 应可编解码")
        }
        if let d = try? enc.encode(tr), let back = try? dec.decode(AgentMessage.self, from: d) {
            #expect(back.callID == "call_1", "AgentMessage:toolResult 的 callID 经 Codable round-trip 保留")
        } else {
            Issue.record("AgentMessage:toolResult 应可编解码")
        }
    }

    @Test("AgentMessage:只含 kind 的 text 消息编码后省略全部 nil 键(手写 encodeIfPresent)")
    func agentMessageOmitsNilKeys() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(AgentMessage.text("hi")), let json = String(data: d, encoding: .utf8) {
            #expect(json.contains("kind") && json.contains("text"),
                    "AgentMessage:text 消息编码后含必填键 kind 与非 nil 键 text")
            #expect(!json.contains("tool"), "AgentMessage:text 消息编码后 JSON 不含 nil 键 tool(encodeIfPresent)")
            #expect(!json.contains("callID"), "AgentMessage:text 消息编码后 JSON 不含 nil 键 callID(encodeIfPresent)")
            #expect(!json.contains("isError"), "AgentMessage:text 消息编码后 JSON 不含 nil 键 isError(encodeIfPresent)")
        } else {
            Issue.record("AgentMessage:text 消息应可编码为 UTF-8 JSON")
        }
    }

    @Test("AgentMessage:6 型样本经 JSONEncoder/Decoder round-trip 全等")
    func agentMessageRoundTripsAllKinds() {
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        let samples: [AgentMessage] = [
            .text("hello"),
            .thinking("pondering"),
            .toolUse(callID: "call_1", tool: "bash", input: .object(["cmd": .string("ls")])),
            .toolResult(callID: "call_1", output: .string("file.txt"), isError: false),
            .status("running"),
            .error("boom")
        ]
        var allEqual = true
        for m in samples {
            guard let d = try? enc.encode(m),
                  let back = try? dec.decode(AgentMessage.self, from: d),
                  back == m else { allEqual = false; break }
        }
        #expect(allEqual, "AgentMessage:6 型样本经 JSONEncoder/Decoder round-trip 全等")
    }
}
