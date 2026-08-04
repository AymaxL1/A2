// A2KernelClient —— 传输层(UDS 字节进出)。
//
// 缝在这里:`A2Transport` 只管字节,不认协议;`A2KernelClient` 只认协议,不碰 fd。
// 于是客户端的相关性、推送分发、超时顺延这些**协议逻辑**可以用 `socketpair()` 造的假内核驱动,
// 不必起真 daemon(真 daemon 那一关归烟测)。
//
// **只写 Darwin 一条路**:壳是 macOS 专属(`Package.swift` 的 platforms 就写着 `.macOS(.v13)`),
// 跨端承诺落在内核那侧(TS,macOS+Linux)。这里不摆一份编译不到、也从没跑过的 Linux 分支
// —— 那种代码只会让人以为它被验过。

import Foundation
import Darwin

/// 字节层传输。
public protocol A2Transport: AnyObject {
    /// 把这些字节**全部**写出去(半写要自己续,见实现头注)。
    func send(_ bytes: [UInt8]) throws
    /// 至多阻塞到 `deadline`;返回读到的字节。**空数组 = 到点了还没有数据**(不是错误);
    /// 对端关闭要抛 `A2ClientError.connectionClosed`。
    func receive(deadline: Date) throws -> [UInt8]
    func close()
}

/// UNIX 域套接字传输(真内核那一侧)。
public final class A2UnixSocketTransport: A2Transport {
    /// `sockaddr_un.sun_path` 的上限(macOS = 104 字节,含结尾 0)。测试用的临时 A2_HOME 一律取
    /// `/tmp` 短路径,就是被这条卡出来的。
    public static let maxSocketPathBytes = 104

    private var fd: Int32
    private var closed = false

    private init(fd: Int32) {
        self.fd = fd
        Self.disableSIGPIPE(fd)
    }

    /// **写到一条已被对端关闭的 socket 会触发 SIGPIPE,默认动作是杀掉进程。**
    ///
    /// 内核重启、被拒(`peer_rejected`)、用户退出 daemon —— 每一种都会让壳手里的连接变成"已关闭"。
    /// 若不关掉这个信号,壳会在"内核没了"的那一刻**直接死掉**,而不是把断连如实报给用户。
    /// macOS 的做法是 `SO_NOSIGPIPE`(BSD 系;Linux 那侧对应 `MSG_NOSIGNAL`,但壳不跑 Linux)。
    private static func disableSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 连上 `<A2_HOME>/run/kernel.sock`。
    ///
    /// 连不上**不是一种响应**,而是一类客户端侧事实(daemon 未装 / 未起 / socket 陈旧)——
    /// 调用方把它翻译成「拒绝即指引」,**永不隐式拉起 daemon**(ADR 0008 第 6 条)。
    public static func connect(socketPath: String) throws -> A2UnixSocketTransport {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < maxSocketPathBytes else {
            throw A2ClientError.daemonUnreachable(
                "socket 路径超过 \(maxSocketPathBytes) 字节上限(\(pathBytes.count)):\(socketPath)")
        }

        let handle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw A2ClientError.daemonUnreachable("socket() 失败:\(errnoText())")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxSocketPathBytes) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(handle, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let detail = errnoText()
            Darwin.close(handle)
            throw A2ClientError.daemonUnreachable("connect(\(socketPath)) 失败:\(detail)")
        }
        return A2UnixSocketTransport(fd: handle)
    }

    /// 用一个**已经连上的 fd** 建传输(测试用 `socketpair()` 造假内核走这条路)。
    public static func adopting(fd: Int32) -> A2UnixSocketTransport {
        A2UnixSocketTransport(fd: fd)
    }

    /// **半写必须自己续** —— `send(2)` 只保证"能写多少写多少"。
    /// 内核那侧在 08 票踩过同款坑(十几 KB 的快照一次写不完);客户端这侧同理:
    /// 注册报文虽小,但 `confirmations.resolve` 的 reason 是人打的字,长度不设上限。
    public func send(_ bytes: [UInt8]) throws {
        guard !closed else { throw A2ClientError.connectionClosed("连接已关闭,写不出去") }
        guard !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                Darwin.send(fd, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            throw A2ClientError.connectionClosed("写连接失败:\(Self.errnoText())")
        }
    }

    public func receive(deadline: Date) throws -> [UInt8] {
        guard !closed else { throw A2ClientError.connectionClosed("连接已关闭,读不到") }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return [] }
        try setReceiveTimeout(remaining)

        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = chunk.withUnsafeMutableBytes { raw -> Int in
            Darwin.recv(fd, raw.baseAddress, raw.count, 0)
        }
        if count > 0 { return Array(chunk[0..<count]) }
        if count == 0 { throw A2ClientError.connectionClosed("内核关闭了连接") }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return [] }
        throw A2ClientError.connectionClosed("读连接失败:\(Self.errnoText())")
    }

    public func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
        fd = -1
    }

    deinit { close() }

    private func setReceiveTimeout(_ seconds: TimeInterval) throws {
        var timeout = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        // 0/0 在 SO_RCVTIMEO 的语义里是「永不超时」—— 剩余时间不足 1 微秒时给 1 微秒,别把自己挂死。
        if timeout.tv_sec == 0 && timeout.tv_usec == 0 { timeout.tv_usec = 1 }
        let result = setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard result == 0 else {
            throw A2ClientError.connectionClosed("设置读超时失败:\(Self.errnoText())")
        }
    }

    private static func errnoText() -> String {
        let code = errno
        return "errno=\(code)(\(String(cString: strerror(code))))"
    }
}
