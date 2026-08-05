// 09 票 —— 假内核(测试基建)。
//
// 用 `socketpair()` 在进程内造一对连上的 UDS:一端给被测客户端,另一端由测试**手写**协议行为。
// 起真 daemon 那一关归活体烟测(`Scripts/a2-smoke-09.sh`);这一层要验的是**协议逻辑** ——
// 相关性、推送分流、超时顺延、字节边界 —— 那些用真 daemon 反而难以精确构造(你没法让真内核
// "在一个中文字的第二个字节处停一下")。
//
// **纪律:假件不 import 被测代码的任何一行**(与 `kernel/test/support/fake-client.ts` 同款)。
// 本文件只用 Foundation:拆行手写,帧用 `JSONSerialization` 拼与解。
// 09 票 CR 抓到过这条头注失实(当时 `readRequest` 用被测的 `A2RequestEnvelope` 解码)——**现已真正独立**。
// 为什么值得较真:假件若用被测的编解码器造输入,同一个 bug 在编与解两侧**会互相抵消**,测试照绿;
// 手写一遍,客户端把包封或帧判别写歪时这份假件才会跟它吵起来,而不是跟着一起歪。

import Foundation
import Darwin

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
        case malformed(String)

        var description: String {
            switch self {
            case let .setupFailed(detail): return "假内核起不来:\(detail)"
            case let .timedOut(detail): return "假内核等超时:\(detail)"
            case let .closed(detail): return "假内核那端断了:\(detail)"
            case let .malformed(detail): return "假内核收到的不是一行 JSON 对象:\(detail)"
            }
        }
    }

    /// 读客户端发来的一整行(**手写拆行**:找 `\n`,不认 `\r`,空行跳过)。
    ///
    /// 默认窗口给到 5 秒:并行跑测试时线程调度会有几百毫秒级的抖动,而这里等的是"客户端有没有发出来",
    /// 不是被测的时序语义 —— 给足余量,免得把调度抖动读成协议错误。
    func readLine(timeout: TimeInterval = 5) throws -> Data {
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
            var window = timeval(
                tv_sec: Int(remaining),
                tv_usec: Int32(remaining.truncatingRemainder(dividingBy: 1) * 1_000_000))
            if window.tv_sec == 0 && window.tv_usec == 0 { window.tv_usec = 1 }
            _ = setsockopt(kernelFD, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = chunk.withUnsafeMutableBytes { raw in Darwin.recv(kernelFD, raw.baseAddress, raw.count, 0) }
            if count > 0 { pending.append(contentsOf: chunk[0..<count]); continue }
            if count == 0 { throw FakeKernelError.closed("客户端关了连接") }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            throw FakeKernelError.closed("读失败:errno=\(errno)")
        }
    }

    /// 读一行并按 JSON 对象解开(**用 Foundation 的 JSONSerialization,不碰被测的包封类型**)。
    func readRequest(timeout: TimeInterval = 5) throws -> [String: Any] {
        let line = try readLine(timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw FakeKernelError.malformed(String(decoding: line, as: UTF8.self))
        }
        return object
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

    /// 把一个 JSON 对象编成一帧的字节(含行尾)。
    static func frameBytes(_ object: [String: Any]) throws -> [UInt8] {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return Array(data)
    }

    /// 写一帧(自己补行尾)。
    func writeFrame(_ object: [String: Any]) throws {
        try writeRaw(try Self.frameBytes(object))
    }

    /// 成功响应。
    func writeSuccess(id: String, result: Any) throws {
        try writeFrame(["v": 1, "id": id, "ok": true, "result": result])
    }

    /// 失败响应。
    func writeFailure(id: String, error: Any) throws {
        try writeFrame(["v": 1, "id": id, "ok": false, "error": error])
    }

    /// 推送帧。
    func writePush(id: String = "push-\(UUID().uuidString)", event: Any) throws {
        try writeFrame(["v": 1, "id": id, "push": true, "event": event])
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(kernelFD)
        kernelFD = -1
    }

    deinit { close() }
}

/// JSON 对象的取值便捷式(测试断言用;同样只依赖 Foundation)。
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func child(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
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

    /// 读成 Foundation 的 JSON 对象(**不经被测类型**)。
    static func object(_ name: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: try data(name)) as? [String: Any] else {
            throw FakeKernel.FakeKernelError.malformed(name)
        }
        return object
    }

    /// 取金标推送样本里的 `event` 载荷(测试要单独发某一族事件时用)。
    static func event(of pushSample: String) throws -> [String: Any] {
        guard let event = try object(pushSample).child("event") else {
            throw FakeKernel.FakeKernelError.malformed("\(pushSample) 里没有 event")
        }
        return event
    }
}
