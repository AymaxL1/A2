// PROTOTYPE — aa：CLI 薄客户端。纯 Foundation/Darwin，不 import AppKit。
// 连宿主 UDS 发逐行 JSON 请求、读一行 JSON 响应。
// 产品原则：CLI 自身永不交互提问——dangerous 确认只在宿主 GUI 完成，CLI 只拿结果。
// 退出码：0=成功，2=denied，3=超时，4=host 不可达，1=用法/其它错误。
import Foundation
import Darwin

let EXIT_OK: Int32 = 0
let EXIT_USAGE: Int32 = 1
let EXIT_DENIED: Int32 = 2
let EXIT_TIMEOUT: Int32 = 3
let EXIT_UNREACHABLE: Int32 = 4

// 诊断走 stderr（stdout 只留响应 JSON / 清单）
func errPrint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func outPrint(_ s: String) {
    print(s)
    fflush(stdout)
}

func socketPath() -> String {
    let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSup.appendingPathComponent("S2Spike/aa.sock").path
}

/// 连接 UDS。成功返回 fd；失败返回 nil（视为 host 不可达）。
func connectUDS() -> Int32? {
    let path = socketPath()
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

/// 设置读/写超时（SO_RCVTIMEO/SO_SNDTIMEO）。读超时后 read 返回 EAGAIN → 判为超时。
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

/// 读一行响应（到 '\n' 或 EOF）。SO_RCVTIMEO 触发时返回 .timedOut。
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

func sendRequest(fd: Int32, req: [String: Any]) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: req, options: []) else { return false }
    var out = data
    out.append(0x0A)
    return writeAll(fd: fd, data: out)
}

func parseObject(_ line: String) -> [String: Any]? {
    guard let d = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return obj
}

func printUsage() {
    errPrint("""
    用法:
      aa list                                          列出已注册能力
      aa call <capability> [--input '<json>'] [--timeout <秒,默认60>]   调用能力
    退出码: 0=成功 2=denied 3=超时 4=host不可达 1=用法/其它错误
    """)
}

// ---- 子命令: list ----
func doList() -> Never {
    guard let fd = connectUDS() else {
        errPrint("host 不可达：无法连接 \(socketPath())。请先启动 S2Host。")
        exit(EXIT_UNREACHABLE)
    }
    defer { close(fd) }
    setTimeout(fd: fd, seconds: 10)
    guard sendRequest(fd: fd, req: ["capability": "_list"]) else {
        errPrint("host 不可达：写请求失败"); exit(EXIT_UNREACHABLE)
    }
    switch readResponseLine(fd: fd) {
    case .line(let line):
        guard let obj = parseObject(line),
              let result = obj["result"] as? [String: Any],
              let caps = result["capabilities"] as? [[String: Any]] else {
            errPrint("响应解析失败: \(line)"); exit(EXIT_USAGE)
        }
        outPrint("已注册能力（\(caps.count)）:")
        for c in caps {
            let id = c["id"] as? String ?? "?"
            let risk = c["risk"] as? String ?? "?"
            let summary = c["summary"] as? String ?? ""
            outPrint("  \(id)  [\(risk)]  \(summary)")
        }
        exit(EXIT_OK)
    case .eof:      errPrint("host 关闭连接且无响应"); exit(EXIT_UNREACHABLE)
    case .timedOut: errPrint("等待响应超时"); exit(EXIT_TIMEOUT)
    case .error(let e): errPrint("读响应错误: \(String(cString: strerror(e)))"); exit(EXIT_UNREACHABLE)
    }
}

// ---- 子命令: call ----
func doCall(_ rest: [String]) -> Never {
    guard let capability = rest.first, !capability.hasPrefix("--") else {
        errPrint("用法: aa call <capability> [--input '<json>'] [--timeout <秒>]")
        exit(EXIT_USAGE)
    }
    var inputJSON: String?
    var timeout: Double = 60
    var i = 1
    while i < rest.count {
        switch rest[i] {
        case "--input":
            i += 1
            guard i < rest.count else { errPrint("--input 缺参数"); exit(EXIT_USAGE) }
            inputJSON = rest[i]
        case "--timeout":
            i += 1
            guard i < rest.count, let t = Double(rest[i]) else { errPrint("--timeout 需数字"); exit(EXIT_USAGE) }
            timeout = t
        default:
            errPrint("未知参数: \(rest[i])"); exit(EXIT_USAGE)
        }
        i += 1
    }

    var req: [String: Any] = ["capability": capability]
    if let inputJSON = inputJSON {
        guard let d = inputJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: d) else {
            errPrint("--input 不是合法 JSON: \(inputJSON)"); exit(EXIT_USAGE)
        }
        req["input"] = parsed
    }

    guard let fd = connectUDS() else {
        errPrint("host 不可达：无法连接 \(socketPath())。请先启动 S2Host。")
        exit(EXIT_UNREACHABLE)
    }
    defer { close(fd) }
    setTimeout(fd: fd, seconds: timeout)
    errPrint("→ 调用 \(capability)（超时 \(timeout)s）")
    guard sendRequest(fd: fd, req: req) else {
        errPrint("host 不可达：写请求失败"); exit(EXIT_UNREACHABLE)
    }
    switch readResponseLine(fd: fd) {
    case .line(let line):
        outPrint(line) // stdout 只打响应 JSON
        if let obj = parseObject(line) {
            if let ok = obj["ok"] as? Bool, ok { exit(EXIT_OK) }
            if let err = obj["error"] as? String, err == "denied" {
                errPrint("← 被拒绝 (denied)"); exit(EXIT_DENIED)
            }
            errPrint("← host 返回错误"); exit(EXIT_USAGE)
        }
        errPrint("← 响应非合法 JSON"); exit(EXIT_USAGE)
    case .eof:      errPrint("host 关闭连接且无响应"); exit(EXIT_UNREACHABLE)
    case .timedOut: errPrint("等待响应超时（\(timeout)s）"); exit(EXIT_TIMEOUT)
    case .error(let e): errPrint("读响应错误: \(String(cString: strerror(e)))"); exit(EXIT_UNREACHABLE)
    }
}

// ---- 顶层分发（main.swift 允许顶层代码）----
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { printUsage(); exit(EXIT_USAGE) }
switch cmd {
case "list": doList()
case "call": doCall(Array(args.dropFirst()))
case "-h", "--help", "help": printUsage(); exit(EXIT_OK)
default:
    errPrint("未知子命令: \(cmd)")
    printUsage()
    exit(EXIT_USAGE)
}
