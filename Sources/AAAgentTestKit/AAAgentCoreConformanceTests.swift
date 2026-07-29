// AAAgentTestKit —— AAAgentCore 骨架的纯逻辑一致性冒烟测试(01 票:证明地基活着)。
// 依赖边:AAAgentTestKit → AAAgentCore、AAContracts(+ 系统 Foundation)。
//
// 两组断言(照 AAHostTestKit.ProxyConformanceTests 的 enum + run() 分派形态):
//   ① FakeAgentPort 主 seam:launch 记录规格 / 探活 / nextEvent 依次回放脚本 / 脚本弹完与中途死亡→nil /
//      terminate 记录并置死 / 编程 launch 失败。
//   ② AgentMessage 6 型模型:便利构造器造各型并断言关键字段;CallID 经 Codable round-trip 全链保留;
//      只含 kind 的消息编码后 nil 键省略(encodeIfPresent);6 型样本 JSON round-trip 全等。
//
// 说明:本套件由 check.sh 动态生成的 runner 执行,打印 report.lines;各 PASS 描述串是 check.sh 阶段 B
//   assert_contains 的定长子串目标,**不得随意改字**(改则同步改 check.sh 断言组 1c)。

import Foundation
import AAContracts
import AAAgentCore

/// AAAgentCore 骨架纯逻辑一致性测试。
public enum AAAgentCoreConformanceTests {
    public static func run() -> AgentTestReport {
        var report = AgentTestReport()
        testFakeAgentPort(&report)
        testAgentMessageModel(&report)
        return report
    }

    // ① FakeAgentPort 主 seam:一次 agent 进程执行的全副作用面在假件上可编程、可断言。
    private static func testFakeAgentPort(_ report: inout AgentTestReport) {
        let port = FakeAgentPort()

        // 预置事件脚本(下一次 launch 后依次弹出)+ 构造启动规格。
        let script = [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"assistant","text":"hello"}"#,
            #"{"type":"result","subtype":"success"}"#
        ]
        port.programEvents(script)
        let spec = AgentLaunchSpec(
            executablePath: "/usr/local/bin/claude",
            arguments: ["-p", "--output-format", "stream-json"],
            environment: ["CODEX_HOME": "/tmp/task-x/codex"],
            workingDirectory: "/tmp/task-x/work",
            stdin: .writeThenKeepOpen(#"{"prompt":"hi"}"#)
        )

        guard let h = try? port.launch(spec) else {
            report.check(false, "假 AgentPort:launch 应成功返回句柄"); return
        }

        // launch 记录规格(executablePath / arguments / workingDirectory / stdin 各断言一次)。
        report.check(port.launchCalls.count == 1, "假 AgentPort:launch 记录一次调用")
        report.check(port.launchCalls.first?.executablePath == "/usr/local/bin/claude",
                     "假 AgentPort:launch 记录可执行路径")
        report.check(port.launchCalls.first?.arguments == ["-p", "--output-format", "stream-json"],
                     "假 AgentPort:launch 记录参数")
        report.check(port.launchCalls.first?.workingDirectory == "/tmp/task-x/work",
                     "假 AgentPort:launch 记录工作目录")
        report.check(port.launchCalls.first?.stdin == .writeThenKeepOpen(#"{"prompt":"hi"}"#),
                     "假 AgentPort:launch 记录 stdin 处置(writeThenKeepOpen)")

        // 探活为真。
        report.check(port.isAlive(h), "假 AgentPort:拉起后探活为真")

        // nextEvent 依次弹出预置脚本三行并断言顺序。
        report.check(port.nextEvent(h) == script[0], "假 AgentPort:nextEvent 依次弹出预置脚本第 1 行")
        report.check(port.nextEvent(h) == script[1], "假 AgentPort:nextEvent 依次弹出预置脚本第 2 行")
        report.check(port.nextEvent(h) == script[2], "假 AgentPort:nextEvent 依次弹出预置脚本第 3 行")
        // 脚本弹完 → nil。
        report.check(port.nextEvent(h) == nil, "假 AgentPort:脚本弹完后 nextEvent 返回 nil")

        // terminate 后探活为假且终止调用被记录。
        port.terminate(h)
        report.check(!port.isAlive(h), "假 AgentPort:终止后探活为假")
        report.check(port.terminateCalls.count == 1 && port.terminateCalls.first == h,
                     "假 AgentPort:终止调用被记录(取消/反孤儿可核验)")

        // 进程中途死亡(不经 terminate):即便脚本未弹完,nextEvent 也返回 nil、探活为假。
        port.programEvents(["still-buffered-1", "still-buffered-2"])
        guard let h2 = try? port.launch(spec) else {
            report.check(false, "假 AgentPort:第二次 launch 应成功"); return
        }
        port.simulateDeath(h2)
        report.check(port.nextEvent(h2) == nil, "假 AgentPort:进程中途死亡后 nextEvent 返回 nil(脚本未弹完亦然)")
        report.check(!port.isAlive(h2), "假 AgentPort:进程中途死亡后探活为假")

        // 编程 launch 失败:下一次 launch 抛错。
        port.programNextLaunchToFail()
        var threw = false
        do { _ = try port.launch(spec) } catch { threw = true }
        report.check(threw, "假 AgentPort:programNextLaunchToFail 后 launch 抛错")
    }

    // ② AgentMessage 6 型模型:便利构造器 / 关键字段 / CallID round-trip / nil 键省略 / 6 型 round-trip 全等。
    private static func testAgentMessageModel(_ report: inout AgentTestReport) {
        let enc = JSONEncoder()
        let dec = JSONDecoder()

        // 6 型各用便利构造器造一条并断言 kind / 关键字段。
        let t  = AgentMessage.text("hello")
        let th = AgentMessage.thinking("pondering")
        let tu = AgentMessage.toolUse(callID: "call_1", tool: "bash", input: .object(["cmd": .string("ls")]))
        let tr = AgentMessage.toolResult(callID: "call_1", output: .string("file.txt"), isError: false)
        let st = AgentMessage.status("running")
        let er = AgentMessage.error("boom")

        report.check(t.kind == .text && t.text == "hello", "AgentMessage.text:kind=text 且 text 内容正确")
        report.check(th.kind == .thinking && th.text == "pondering", "AgentMessage.thinking:kind=thinking 且 text 内容正确")
        report.check(tu.kind == .toolUse && tu.tool == "bash" && tu.callID == "call_1" && tu.input != nil,
                     "AgentMessage.toolUse:kind/tool/callID/input 正确")
        report.check(tr.kind == .toolResult && tr.callID == "call_1" && tr.isError == false && tr.output != nil,
                     "AgentMessage.toolResult:kind/callID/output/isError 正确")
        report.check(st.kind == .status && st.status == "running", "AgentMessage.status:kind=status 且 status 串正确")
        report.check(er.kind == .error && er.text == "boom", "AgentMessage.error:kind=error 且 text 内容正确")

        // CallID 经 Codable round-trip 全链保留(修 multica 丢 CallID 的有损点)。
        if let d = try? enc.encode(tu), let back = try? dec.decode(AgentMessage.self, from: d) {
            report.check(back.callID == "call_1", "AgentMessage:toolUse 的 callID 经 Codable round-trip 保留")
        } else {
            report.check(false, "AgentMessage:toolUse 应可编解码")
        }
        if let d = try? enc.encode(tr), let back = try? dec.decode(AgentMessage.self, from: d) {
            report.check(back.callID == "call_1", "AgentMessage:toolResult 的 callID 经 Codable round-trip 保留")
        } else {
            report.check(false, "AgentMessage:toolResult 应可编解码")
        }

        // 只含 kind 的 text 消息:编码后 JSON 省略全部 nil 键(验证手写 encodeIfPresent)。
        if let d = try? enc.encode(AgentMessage.text("hi")), let json = String(data: d, encoding: .utf8) {
            report.check(json.contains("kind") && json.contains("text"),
                         "AgentMessage:text 消息编码后含必填键 kind 与非 nil 键 text")
            report.check(!json.contains("tool"), "AgentMessage:text 消息编码后 JSON 不含 nil 键 tool(encodeIfPresent)")
            report.check(!json.contains("callID"), "AgentMessage:text 消息编码后 JSON 不含 nil 键 callID(encodeIfPresent)")
            report.check(!json.contains("isError"), "AgentMessage:text 消息编码后 JSON 不含 nil 键 isError(encodeIfPresent)")
        } else {
            report.check(false, "AgentMessage:text 消息应可编码为 UTF-8 JSON")
        }

        // 6 型样本经 JSONEncoder/Decoder round-trip 全等。
        let samples: [AgentMessage] = [t, th, tu, tr, st, er]
        var allEqual = true
        for m in samples {
            guard let d = try? enc.encode(m),
                  let back = try? dec.decode(AgentMessage.self, from: d),
                  back == m else { allEqual = false; break }
        }
        report.check(allEqual, "AgentMessage:6 型样本经 JSONEncoder/Decoder round-trip 全等")
    }
}
