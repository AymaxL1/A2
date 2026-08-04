// 09 票 —— NDJSON 拆行缓冲(字节级)。
//
// 这一组盯的是**一个具体的、必然会发生的洞**:多字节字符被 chunk 边界劈开。
// 内核的报文里全是中文(指引文案、审计 detail、能力 summary),十几 KB 的快照必定跨多个 recv;
// 若先把每个 chunk 转成 String 再拼,劈开的那个字就成了两个替换字符,整帧再也解不动。
// 断言用**真的被劈开的字节**来验,不是用"看起来像"的构造。

import Foundation
import Testing
@testable import A2KernelClient

@Suite("09 NDJSON 字节级拆行")
struct A2LineBufferTests {

    private func text(_ line: [UInt8]) -> String { String(decoding: line, as: UTF8.self) }

    @Test("一段字节里有几行就吐几行,行尾 \\n 不带出来")
    func splitsMultipleLines() {
        var buffer = A2LineBuffer()
        buffer.append(Array(#"{"a":1}"#.utf8) + [0x0A] + Array(#"{"b":2}"#.utf8) + [0x0A])
        #expect(text(buffer.nextLine() ?? []) == #"{"a":1}"#)
        #expect(text(buffer.nextLine() ?? []) == #"{"b":2}"#)
        #expect(buffer.nextLine() == nil)
        #expect(buffer.pendingByteCount == 0)
    }

    @Test("没收到行尾就一个字节都不吐(半帧不是帧)")
    func withholdsIncompleteLine() {
        var buffer = A2LineBuffer()
        buffer.append(Array(#"{"a":"#.utf8))
        #expect(buffer.nextLine() == nil)
        #expect(buffer.pendingByteCount == 5)
        buffer.append(Array(#"1}"#.utf8) + [0x0A])
        #expect(text(buffer.nextLine() ?? []) == #"{"a":1}"#)
    }

    @Test("中文字被 chunk 边界劈开:拼回来仍是同一个字(先切行、后解码)")
    func survivesMultibyteSplitAcrossChunks() {
        // 「机场甲」的第一个字 UTF-8 是 3 字节;这里**故意**在它的第 1 与第 2 字节之间切开。
        let payload = #"{"name":"机场甲"}"#
        let bytes = Array(payload.utf8) + [0x0A]
        guard let leadIndex = bytes.firstIndex(where: { $0 >= 0xE0 }) else {
            Issue.record("样本里没有三字节字符,这条断言就白写了"); return
        }
        let cut = leadIndex + 1

        var buffer = A2LineBuffer()
        buffer.append(Array(bytes[0..<cut]))
        #expect(buffer.nextLine() == nil, "半个字符不该被当成一行")
        buffer.append(Array(bytes[cut...]))

        let line = buffer.nextLine()
        #expect(line != nil)
        #expect(text(line ?? []) == payload)
        #expect(text(line ?? []).contains("机场甲"), "多字节字符被切碎了(出现替换字符就说明按字符拼了)")
    }

    @Test("逐字节喂也拼得回来(最坏的 chunk 切法)")
    func survivesByteByByteFeeding() {
        let payload = #"{"summary":"没有下一步的指引等于没有指引。"}"#
        var buffer = A2LineBuffer()
        var produced: [String] = []
        for byte in Array(payload.utf8) + [0x0A] {
            buffer.append([byte])
            while let line = buffer.nextLine() { produced.append(text(line)) }
        }
        #expect(produced == [payload])
    }

    @Test("空行跳过(不让调用方去解一个空字符串)")
    func skipsEmptyLines() {
        var buffer = A2LineBuffer()
        buffer.append([0x0A, 0x0A] + Array(#"{"a":1}"#.utf8) + [0x0A])
        #expect(text(buffer.nextLine() ?? []) == #"{"a":1}"#)
        #expect(buffer.nextLine() == nil)
    }

    @Test("一条 64KB 级的帧跨很多 chunk 也能完整拼回")
    func reassemblesLargeFrame() {
        let big = String(repeating: "确认器在场时 dangerous 走带外确认。", count: 2000)
        let payload = "{\"detail\":\"\(big)\"}"
        let bytes = Array(payload.utf8) + [0x0A]
        var buffer = A2LineBuffer()
        var offset = 0
        var line: [UInt8]?
        while offset < bytes.count {
            let end = min(offset + 4096, bytes.count)
            buffer.append(Array(bytes[offset..<end]))
            offset = end
            if let candidate = buffer.nextLine() { line = candidate }
        }
        #expect(line != nil)
        #expect(text(line ?? []) == payload)
    }
}
