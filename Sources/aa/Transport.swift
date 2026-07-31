// ============ POSIX UDS 客户端(纯 Foundation/Darwin,不 import AppKit)============
import Foundation
import Darwin
import AAContracts

/// 连接 UDS。成功返回 fd;失败返回 nil(视为 host 不可达)。路径读 Contracts 常量。
func connectUDS() -> Int32? {
    let path = AAPaths.socketPath
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    if bytes.count >= cap { close(fd); return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { raw in
        raw.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
            for i in 0..<bytes.count { dst[i] = bytes[i] }
            dst[bytes.count] = 0
        }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let res = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if res != 0 { close(fd); return nil }
    return fd
}

/// 设置读/写超时(SO_RCVTIMEO/SO_SNDTIMEO)。读超时后 read 返回 EAGAIN → 判为超时。
func setTimeout(fd: Int32, seconds: Double) {
    var tv = timeval(tv_sec: Int(seconds),
                     tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

func writeAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard var p = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
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

enum ReadResult {
    case line(String)
    case eof
    case timedOut
    case error(Int32)
}

/// 读一行响应(到 '\n' 或 EOF)。SO_RCVTIMEO 触发时返回 .timedOut。
func readResponseLine(fd: Int32) -> ReadResult {
    var buffer = [UInt8]()
    var byte: UInt8 = 0
    while true {
        let n = read(fd, &byte, 1)
        if n == 1 {
            if byte == 0x0A { return .line(String(decoding: buffer, as: UTF8.self)) }
            buffer.append(byte)
        } else if n == 0 {
            return buffer.isEmpty ? .eof : .line(String(decoding: buffer, as: UTF8.self))
        } else {
            let e = errno
            if e == EINTR { continue }
            if e == EAGAIN || e == EWOULDBLOCK { return .timedOut }
            return .error(e)
        }
    }
}

/// 编码请求为一行 JSON 并发送(经 JSONEncoder,禁手拼)。
func sendRequest(fd: Int32, request: WireRequest) -> Bool {
    guard let data = try? JSONEncoder().encode(request) else { return false }
    var out = data
    out.append(0x0A)
    return writeAll(fd: fd, data: out)
}

// ============ 通用请求-响应往返(连 UDS → 发 → 收一行)============

/// 传输层失败统一收口(05 票:宿主未运行 UX 正式化)。
/// 人读诊断走 stderr;`--json` 时 stdout 补一份机读错误信封(WireError 风格);再按专属退出码退出。
/// 对所有需要连宿主的命令(list / describe / call / 域子命令)一致生效。
func exitTransport(exitCode: Int32, errCode: String, detail: String, human: String, json: Bool) -> Never {
    errPrint(human)
    if json { emitErrorEnvelope(code: errCode, detail: detail) }
    exit(exitCode)
}

/// 连 UDS、发请求、读一行响应,统一把不可达/超时/EOF 折叠成退出。成功则返回响应行文本。
/// 语义错误(host 返回 ok=false)交给上层按 error.code 映射退出码,故这里只处理「传输层」失败。
/// `json`:失败时是否额外向 stdout 打机读错误信封(由调用方按 `--json` 传入)。
func roundTrip(_ request: WireRequest, json: Bool) -> String {
    guard let fd = connectUDS() else {
        // 宿主未运行的正式 UX:人读明确「未运行 + 如何启动」;机读统一错误信封;退出码 4。
        exitTransport(exitCode: AAExitCode.hostUnreachable, errCode: CLIErrorCode.hostUnreachable,
                      detail: "无法连接 \(AAPaths.socketPath);AA 宿主未运行",
                      human: "host 不可达:无法连接 \(AAPaths.socketPath)。AA 宿主未运行 —— "
                           + "请先启动宿主(V1 骨架期为前台运行宿主可执行;12 票起为菜单栏 App)后重试。",
                      json: json)
    }
    // 注:本函数所有失败分支都 exit(_:),exit 不跑 defer;fd 由进程退出统一回收,故不设 defer close。
    setTimeout(fd: fd, seconds: timeoutSeconds())
    guard sendRequest(fd: fd, request: request) else {
        exitTransport(exitCode: AAExitCode.hostUnreachable, errCode: CLIErrorCode.hostUnreachable,
                      detail: "写请求失败(宿主可能已退出)", human: "host 不可达:写请求失败", json: json)
    }
    switch readResponseLine(fd: fd) {
    case .line(let line):
        return line
    case .eof:
        exitTransport(exitCode: AAExitCode.hostUnreachable, errCode: CLIErrorCode.hostUnreachable,
                      detail: "宿主关闭连接且无响应", human: "host 不可达:host 关闭连接且无响应", json: json)
    case .timedOut:
        exitTransport(exitCode: AAExitCode.timeout, errCode: CLIErrorCode.timeout,
                      detail: "等待宿主响应超时", human: "等待响应超时", json: json)
    case .error(let e):
        exitTransport(exitCode: AAExitCode.hostUnreachable, errCode: CLIErrorCode.hostUnreachable,
                      detail: "读响应错误: \(String(cString: strerror(e)))",
                      human: "读响应错误: \(String(cString: strerror(e)))", json: json)
    }
}

/// 把响应行解成 `WireResponse<R>`;解不出即协议错(退出码 6)。
func decodeResponse<R: Codable & Sendable>(_ line: String, as type: R.Type) -> WireResponse<R> {
    guard let data = line.data(using: .utf8),
          let response = try? JSONDecoder().decode(WireResponse<R>.self, from: data) else {
        errPrint("响应解析失败: \(line)")
        exit(AAExitCode.protocolError)
    }
    return response
}

/// 统一失败处理:按需把统一 JSON 错误信封打到 stdout(便于 agent 解析 error.code),
/// 人读诊断打到 stderr,并按 error.code 映射退出码。永不返回。
func failAndExit<R: Codable & Sendable>(_ response: WireResponse<R>, json: Bool) -> Never {
    let err = response.error ?? WireError(code: "unknown", detail: "(响应无 error 字段)")
    if json {
        // 重编本失败信封(result 为 nil → `{"error":{...},"ok":false}`),不手拼。
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(response), let s = String(data: data, encoding: .utf8) {
            outPrint(s)
        }
    }
    errPrint("能力请求失败 [\(err.code)]: \(err.detail)")
    exit(AAExitCode.forErrorCode(err.code))
}
