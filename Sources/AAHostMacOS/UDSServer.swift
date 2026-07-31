// AAHostMacOS —— Unix 域套接字(UDS)server(POSIX socket/bind/listen/accept)。
// 照 S2 spike 的线程模型重写(study 而非 copy):
//   * socket/bind/listen 在 start();sun_path 逐字节填、写 sun_len、bind 前 unlink 旧文件。
//   * accept 循环跑在后台串行队列;每条连接派发到并发队列独立处理。
//   * 03 票:route 路由 list / describe / call 三 op。call 的校验/风险路由/执行全在 registry.invoke
//     (宿主侧集中,不可绕过);safe/normal 直执行,dangerous 留 seam 给 04 票。服务端读超时仍记为债(未做)。
//
// 全部经 JSONDecoder/JSONEncoder;禁止手拼字符串。响应类型是 Contracts 的 WireResponse<R>(R 随 op 而异)。

import Foundation
import Darwin
import AAContracts
import AAHostRuntime

/// 把 errno 包成可读 NSError(调用后立即取 errno,勿在中间插入其它系统调用)。
private func posixError(_ op: String) -> NSError {
    let e = errno
    return NSError(domain: "AAUDS", code: Int(e),
                   userInfo: [NSLocalizedDescriptionKey: "\(op) 失败: \(String(cString: strerror(e))) (errno=\(e))"])
}

/// UDS server。持有不可变 `Registry`(Sendable),可安全跨连接处理线程并发 list()。
final class UDSServer {
    let socketPath: String
    let registry: Registry
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "aa.uds.accept")
    private let handleQueue = DispatchQueue(label: "aa.uds.handle", attributes: .concurrent)

    init(socketPath: String, registry: Registry) {
        self.socketPath = socketPath
        self.registry = registry
    }

    /// 建 socket → unlink 旧文件 → bind → listen → 后台 accept 循环。失败抛错。
    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        listenFD = fd

        // UDS 文件不随进程退出自动清除,bind 前先删残留旧 socket。
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)   // macOS 上 sun_path 容量为 104
        guard pathBytes.count < cap else {
            throw NSError(domain: "AAUDS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "socket 路径过长(\(pathBytes.count) >= \(cap)): \(socketPath)"])
        }
        // sun_path 被 Swift 导入为定长 CChar 元组,只能借指针逐字节填。
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
        hostLog("UDS accept 循环启动 (fd=\(listenFD))")
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                hostLog("accept 失败 errno=\(errno) (\(String(cString: strerror(errno)))),退出 accept 循环")
                break
            }
            // 每连接独立并发处理(list 不阻塞,但沿用 S2 模型为 03 票的 dangerous 阻塞留位)。
            handleQueue.async { [weak self] in self?.handle(client: client) }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        guard let reqLine = readLine(fd: client) else {
            hostLog("连接无有效请求行,关闭")
            return
        }
        hostLog("请求: \(reqLine)")
        let responseData = route(requestLine: reqLine)
        var out = responseData
        out.append(0x0A) // 追加 '\n' 收尾一行
        writeAll(fd: client, data: out)
        hostLog("响应: \(String(data: responseData, encoding: .utf8) ?? "<非UTF8>")")
    }

    /// 解析请求行、按 op 路由、编码统一信封为一行 JSON 的 Data(不含结尾换行)。
    /// list/describe/call 三 op 都走 registry 的纯逻辑,再包成 `WireResponse<R>`;未知 op 明确报错(不静默)。
    private func route(requestLine: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // 稳定键序,便于诊断与断言

        // 解不出合法请求 → bad_request 失败信封
        guard let data = requestLine.data(using: .utf8),
              let request = try? JSONDecoder().decode(WireRequest.self, from: data) else {
            return encodeFailure(encoder, code: WireErrorCode.badRequest, detail: "请求非合法 JSON 或缺 op 字段")
        }

        switch request.op {
        case WireOp.capabilitiesList:
            let response = WireResponse<CapabilityListResult>.success(
                CapabilityListResult(capabilities: registry.list()))
            return encode(encoder, response)

        case WireOp.capabilitiesDescribe:
            guard let id = request.capability else {
                return encodeFailure(encoder, code: WireErrorCode.invalidParams, detail: "describe 请求缺 capability 字段")
            }
            guard let descriptor = registry.describe(id) else {
                return encodeFailure(encoder, code: WireErrorCode.unknownCapability, detail: "未知能力: \(id)")
            }
            let response = WireResponse<DescribeResult>.success(DescribeResult(descriptor: descriptor))
            return encode(encoder, response)

        case WireOp.capabilitiesCall:
            guard let id = request.capability else {
                return encodeFailure(encoder, code: WireErrorCode.invalidParams, detail: "call 请求缺 capability 字段")
            }
            // 宿主侧集中校验 + 风险路由 + 执行都在 registry.invoke(不可绕过)。
            switch registry.invoke(capabilityID: id, input: request.input) {
            case .success(let output):
                let response = WireResponse<CallResult>.success(CallResult(output: output))
                return encode(encoder, response)
            case .failure(let err):
                return encodeFailure(encoder, code: err.code, detail: err.detail)
            case .pending(let requestID):
                return encode(encoder, WireResponse<CallResult>.success(CallResult(pending: requestID)))
            }

        case WireOp.capabilitiesResult:
            guard let requestID = request.requestID, !requestID.isEmpty else {
                return encodeFailure(encoder, code: WireErrorCode.invalidParams, detail: "result 请求缺 requestID 字段")
            }
            switch registry.invocationStatus(requestID: requestID) {
            case .pending:
                return encode(encoder, WireResponse<CallResult>.success(CallResult(pending: requestID)))
            case .completed(.success(let output)):
                return encode(encoder, WireResponse<CallResult>.success(CallResult(output: output)))
            case .completed(.failure(let error)):
                return encodeFailure(encoder, code: error.code, detail: error.detail)
            case .completed(.pending), .notFound:
                return encodeFailure(encoder, code: WireErrorCode.invalidParams, detail: "未知 requestID: \(requestID)")
            }

        default:
            return encodeFailure(encoder, code: WireErrorCode.unknownOp, detail: "未知操作: \(request.op)")
        }
    }

    /// 编码成功信封;编码失败退回统一失败信封(仍走 Codable)。
    private func encode<R: Codable & Sendable>(_ encoder: JSONEncoder, _ response: WireResponse<R>) -> Data {
        (try? encoder.encode(response)) ?? encodeFailure(encoder, code: WireErrorCode.encodeFailed, detail: "响应编码失败")
    }

    /// 编码彻底失败时的预编码保底信封(load 时算一次;此固定输入实际不会编码失败)。
    /// 用它替代手拼 JSON 字符串:保底信封也走 Codable。
    private static let fallbackFailure: Data = {
        let response = WireResponse<CapabilityListResult>.failure(WireError(code: WireErrorCode.encodeFailed, detail: "响应编码失败"))
        return (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
    }()

    /// 编码失败信封(参数化到 CapabilityListResult 以复用同一信封类型;result 省略)。
    private func encodeFailure(_ encoder: JSONEncoder, code: String, detail: String) -> Data {
        let response = WireResponse<CapabilityListResult>.failure(WireError(code: code, detail: detail))
        // 失败信封无外部输入,编码不应失败;万一失败退回预编码保底常量。
        return (try? encoder.encode(response)) ?? UDSServer.fallbackFailure
    }

    /// 读到 '\n' 或 EOF;单字节读足够简单可靠(协议为单行请求)。返回 nil 表示无数据/出错。
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
