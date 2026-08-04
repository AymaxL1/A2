// 09 票 —— 假内核(测试基建)。
//
// 用 `socketpair()` 在进程内造一对连上的 UDS:一端给被测客户端,另一端由测试**手写**协议行为。
// 起真 daemon 那一关归活体烟测(`Scripts/a2-smoke-09.sh`);这一层要验的是**协议逻辑**——
// 相关性、推送分流、超时顺延、字节边界 —— 那些用真 daemon 反而难以精确构造(你没法让真内核
// "在一个中文字的第二个字节处停一下")。
//
// 纪律(与 kernel/test/support/fake-client.ts 同款):**假件不复用被测代码的任何一行判据**。
// 拆行、帧判别在这里手写一遍;客户端若把判别方式改歪了,这份假件会吵起来,而不是跟着一起歪。

import Foundation
import Darwin
import Testing
@testable import A2Contract

/// 进程内的一对已连上的 UDS。
final class FakeKernel {
    /// 交给被测客户端的那一端。
    let clientFD: Int32
    /// 测试自己拿着的那一端(扮演内核)。
    private var kernelFD: Int32
    private var pending: [UInt8] = []
    private var closed = false

    init() throws {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        guard result == 0 else {
            throw FakeKernelError.setupFailed("socketpair 失败:errno=\(errno)")
        }
        clientFD = fds[0]
        kernelFD = fds[1]
        // 与被测客户端同一条口径:写到已关闭的对端不许把测试进程用 SIGPIPE 打死。
        var on: Int32 = 1
        _ = setsockopt(kernelFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    enum FakeKernelError: Error, CustomStringConvertible {
        case setupFailed(String)
        case timedOut(String)
        case closed(String)

        var description: String {
            switch self {
            case let .setupFailed(detail): return "假内核起不来:\(detail)"
            case let .timedOut(detail): return "假内核等超时:\(detail)"
            case let .closed(detail): return "假内核那端断了:\(detail)"
            }
        }
    }

    /// 读客户端发来的一整行(手写拆行:找 `\n`,不认 `\r`)。
    func readLine(timeout: TimeInterval = 2) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Array(pending[0..<newline])
                pending.removeSubrange(0...newline)
                if !line.isEmpty { return Data(line) }
                continue
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw FakeKernelError.timedOut("等客户端的一行请求") }
            var timeval = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000))
            if timeval.tv_sec == 0 && timeval.tv_usec == 0 { timeval.tv_usec = 1 }
            _ = setsockopt(kernelFD, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<Darwin.timeval>.size))
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = chunk.withUnsafeMutableBytes { raw in Darwin.recv(kernelFD, raw.baseAddress, raw.count, 0) }
            if count > 0 { pending.append(contentsOf: chunk[0..<count]); continue }
            if count == 0 { throw FakeKernelError.closed("客户端关了连接") }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            throw FakeKernelError.closed("读失败:errno=\(errno)")
        }
    }

    /// 读一行并按请求包封解开(测试要看 op / params)。
    func readRequest(timeout: TimeInterval = 2) throws -> A2RequestEnvelope {
        try JSONDecoder().decode(A2RequestEnvelope.self, from: try readLine(timeout: timeout))
    }

    /// 写一段**原始字节**(要在多字节字符中间切开时用这个)。
    func writeRaw(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                Darwin.send(kernelFD, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            if written > 0 { offset += written; continue }
            if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            throw FakeKernelError.closed("写失败:errno=\(errno)")
        }
    }

    /// 写一帧(自己补行尾)。
    func writeFrame(_ json: A2JSON) throws {
        var data = try JSONEncoder().encode(json)
        data.append(0x0A)
        try writeRaw(Array(data))
    }

    /// 成功响应。
    func writeSuccess(id: String, result: A2JSON) throws {
        try writeFrame(.object(["v": .int(1), "id": .string(id), "ok": .bool(true), "result": result]))
    }

    /// 失败响应。
    func writeFailure(id: String, error: A2JSON) throws {
        try writeFrame(.object(["v": .int(1), "id": .string(id), "ok": .bool(false), "error": error]))
    }

    /// 推送帧。
    func writePush(id: String = "push-\(UUID().uuidString)", event: A2JSON) throws {
        try writeFrame(.object(["v": .int(1), "id": .string(id), "push": .bool(true), "event": event]))
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(kernelFD)
        kernelFD = -1
    }

    deinit { close() }
}

/// 金标样本(客户端这侧也读同一批文件:响应载荷用真数据,不用手捏的假快照)。
enum GoldenFixtures {
    static var goldenDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // A2KernelClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <root>
            .appendingPathComponent("kernel/contract/golden", isDirectory: true)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: goldenDirectory.appendingPathComponent(name))
    }

    static func json(_ name: String) throws -> A2JSON {
        try JSONDecoder().decode(A2JSON.self, from: try data(name))
    }
}
