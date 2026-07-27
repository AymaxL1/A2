// PROTOTYPE — Unix 域套接字（UDS）server。POSIX socket/bind/listen/accept，逐行 JSON 请求/响应。
// 关键：accept 循环在后台线程；每连接派发到并发队列处理；dangerous 确认经注册表回调切回主线程弹窗。
import Foundation
import Darwin

/// 把 errno 包成可读 NSError（调用后立即取 errno，勿在中间插入其它系统调用）。
private func posixError(_ op: String) -> NSError {
    let e = errno
    return NSError(domain: "S2UDS", code: Int(e),
                  userInfo: [NSLocalizedDescriptionKey: "\(op) 失败: \(String(cString: strerror(e))) (errno=\(e))"])
}

final class UDSServer {
    let socketPath: String
    let registry: Registry
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "s2.uds.accept")
    private let handleQueue = DispatchQueue(label: "s2.uds.handle", attributes: .concurrent)

    init(socketPath: String, registry: Registry) {
        self.socketPath = socketPath
        self.registry = registry
    }

    /// 建 socket -> unlink 旧文件 -> bind -> listen -> 后台 accept 循环。失败抛错。
    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        listenFD = fd

        // 删除可能残留的旧 socket 文件（UDS 文件不随进程退出自动清除）
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)   // macOS 上 sun_path 容量为 104
        guard pathBytes.count < cap else {
            throw NSError(domain: "S2UDS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "socket 路径过长(\(pathBytes.count) >= \(cap)): \(socketPath)"])
        }
        // 把路径字节写进 sun_path（它被 Swift 导入为 CChar 元组，只能借指针逐字节填）
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for i in 0..<pathBytes.count { dst[i] = pathBytes[i] }
                dst[pathBytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else { throw posixError("bind") }
        guard listen(fd, 16) == 0 else { throw posixError("listen") }

        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        s2log("UDS accept 循环启动 (fd=\(listenFD))")
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                s2log("accept 失败 errno=\(errno) (\(String(cString: strerror(errno))))，退出 accept 循环")
                break
            }
            // 每连接独立并发处理：dangerous 确认阻塞时不拖住其它连接与 accept
            handleQueue.async { [weak self] in self?.handle(client: client) }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        guard let reqLine = readLine(fd: client) else {
            s2log("连接无有效请求行，关闭")
            return
        }
        s2log("请求: \(reqLine)")
        let response = route(requestLine: reqLine)
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            s2log("响应序列化失败")
            return
        }
        var out = data
        out.append(0x0A) // 追加 '\n' 收尾一行
        writeAll(fd: client, data: out)
        s2log("响应: \(String(data: data, encoding: .utf8) ?? "<非UTF8>")")
    }

    private func route(requestLine: String) -> [String: Any] {
        guard let data = requestLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capID = obj["capability"] as? String else {
            return ["ok": false, "error": "bad_request",
                    "detail": "请求非合法 JSON 或缺 capability 字段"]
        }
        return registry.invoke(capabilityID: capID, input: obj["input"])
    }

    /// 读到 '\n' 或 EOF；单字节读足够简单可靠（协议为单行请求）。返回 nil 表示无数据/出错。
    private func readLine(fd: Int32) -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n == 1 {
                if byte == 0x0A { break }
                buffer.append(byte)
            } else if n == 0 {
                break // EOF
            } else {
                if errno == EINTR { continue }
                return nil
            }
        }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }

    private func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = data.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n > 0 {
                    p = p.advanced(by: n)
                    remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }
}
