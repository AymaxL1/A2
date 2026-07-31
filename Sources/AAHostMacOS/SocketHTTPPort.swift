// AAHostMacOS —— HTTPPort 真实现。对 127.0.0.1:<port> 发同步 HTTP/1.0(裸 BSD socket,不经 URLSession)。
// 依赖边:AAHostMacOS → AAPluginSDK(HTTPPort 协议)、Foundation/Darwin。
//
// 为何裸 socket 而非 URLSession:仅需 localhost;裸 socket 完全在掌控内、无 ATS(明文 http)顾虑、
// 不依赖可能受损的本机工具链的高层网络栈。HTTP/1.0 + `Connection: close` → 服务端应答后即关连接,读到 EOF 收束干净
// (mihomo 的 Go http server 与测试 stub 的 python http.server 都支持)。设 2s 读/写超时,防内核卡死拖住 status。

import Foundation
import Darwin
import AAPluginSDK

/// HTTPPort 的裸 socket 实现(仅 localhost)。
public final class SocketHTTPPort: HTTPPort, @unchecked Sendable {
    private let timeoutSeconds: Int

    public init(timeoutSeconds: Int = 2) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func send(method: HTTPMethod, url: String, body: Data?) throws -> HTTPResponse {
        guard let comps = URLComponents(string: url), let host = comps.host, let port = comps.port else {
            throw SocketHTTPError.badURL(url)
        }
        var path = comps.path.isEmpty ? "/" : comps.path
        if let q = comps.query, !q.isEmpty { path += "?" + q }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketHTTPError.socketFailed(errno) }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        // 仅 localhost:host 应为点分四段(127.0.0.1)。inet_pton 失败即非法地址。
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw SocketHTTPError.badURL("非点分 IP 主机: \(host)")
        }
        let connRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connRes == 0 else { throw SocketHTTPError.connectFailed(errno) }  // 内核死亡 → ECONNREFUSED

        // 组请求(HTTP/1.0 + Connection: close)。
        var head = "\(method.rawValue) \(path) HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n"
        if let b = body {
            head += "Content-Type: application/json\r\nContent-Length: \(b.count)\r\n"
        }
        head += "\r\n"
        var outData = Data(head.utf8)
        if let b = body { outData.append(b) }
        guard writeAll(fd: fd, data: outData) else { throw SocketHTTPError.writeFailed }

        // 读到 EOF(HTTP/1.0 close 语义)。
        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                resp.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                break  // EOF
            } else {
                if errno == EINTR { continue }
                // EAGAIN(读超时)或其它错误:若已读到部分响应尝试解析,否则报超时/错误。
                if resp.isEmpty { throw SocketHTTPError.readFailed(errno) }
                break
            }
        }

        // 拆 headers / body,解状态码。
        guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else { throw SocketHTTPError.badResponse }
        let headerData = resp.subdata(in: resp.startIndex..<sep.lowerBound)
        let bodyData = resp.subdata(in: sep.upperBound..<resp.endIndex)
        let headerStr = String(decoding: headerData, as: UTF8.self)
        let statusLine = headerStr.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = statusLine.split(separator: " ")
        let code = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
        return HTTPResponse(statusCode: code, body: bodyData)
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var p = raw.bindMemory(to: UInt8.self).baseAddress else { return true /* 空 body */ }
            var remaining = data.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n > 0 { p = p.advanced(by: n); remaining -= n }
                else if n < 0 && errno == EINTR { continue }
                else { return false }
            }
            return true
        }
    }
}

/// SocketHTTPPort 的传输层错误。
public enum SocketHTTPError: Error, Equatable {
    case badURL(String)
    case socketFailed(Int32)
    case connectFailed(Int32)
    case writeFailed
    case readFailed(Int32)
    case badResponse
}
