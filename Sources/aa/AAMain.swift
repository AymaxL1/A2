// aa —— 面向 Agent/人 的双层命令面 CLI。02 票落地首个真命令:`aa capabilities list [--json]`。
// 依赖边:aa → AAContracts(线协议 / 描述符 / socket 路径常量都从这里取)。
//
// 两个已固化的 Swift 坑(照抄):
//   1) 入口 @main @MainActor struct + -parse-as-library(故文件名非 main.swift,顶层不放可执行语句;与 01 约定一致)。
//   2) 任何 print 之后 fflush(stdout)——stdout 被重定向时是块缓冲,不 flush 断言脚本可能读不到输出。
//
// 产品原则(spec):CLI 自身永不交互提问;机读 JSON 走 stdout,诊断走 stderr。
// dangerous 确认只在宿主 GUI 完成 —— 但那是 03 票 call 的事,本票只做只读 list。

import Foundation
import Darwin
import AAContracts

/// 退出码(沿用 S2 spike 约定,完整 UX 归 05 票):
/// 0=成功,1=用法/其它错误,3=超时,4=host 不可达。(2=denied 由 03 票 call 使用,本票不产生。)
enum ExitCode {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    static let timeout: Int32 = 3
    static let unreachable: Int32 = 4
}

// ============ 诊断 / 输出 ============

/// 诊断走 stderr(stdout 只留机读 JSON / 清单)。
func errPrint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// 机读输出走 stdout,并立即 fflush。
func outPrint(_ s: String) {
    print(s)
    fflush(stdout)
}

// ============ POSIX UDS 客户端(纯 Foundation/Darwin,不 import AppKit)============

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

// ============ 子命令实现 ============

func printUsage() {
    errPrint("""
    用法:
      aa capabilities list [--json]      列出已注册能力(--json 打机读 JSON,否则人读清单)
    退出码: 0=成功 1=用法/其它错误 3=超时 4=host 不可达
    """)
}

/// `aa capabilities list`。连 UDS → 发 list 请求 → 解 WireResponse<CapabilityListResult> → 输出。
/// - Parameter json: true 打机读 JSON 到 stdout;false 打人读清单。
func doCapabilitiesList(json: Bool) -> Never {
    guard let fd = connectUDS() else {
        errPrint("host 不可达:无法连接 \(AAPaths.socketPath)。请先启动 AAHost。")
        exit(ExitCode.unreachable)
    }
    // 注:此函数所有分支都以 exit(_:) 收尾,exit 不跑 defer;fd 由进程退出统一回收,故不设 defer close(那是死代码)。
    setTimeout(fd: fd, seconds: 10)

    guard sendRequest(fd: fd, request: WireRequest(op: WireOp.capabilitiesList)) else {
        errPrint("host 不可达:写请求失败")
        exit(ExitCode.unreachable)
    }

    switch readResponseLine(fd: fd) {
    case .line(let line):
        guard let data = line.data(using: .utf8),
              let response = try? JSONDecoder().decode(WireResponse<CapabilityListResult>.self, from: data) else {
            errPrint("响应解析失败: \(line)")
            exit(ExitCode.usage)
        }
        guard response.ok, let result = response.result else {
            let code = response.error?.code ?? "unknown"
            let detail = response.error?.detail ?? "(无 detail)"
            errPrint("host 返回错误 [\(code)]: \(detail)")
            exit(ExitCode.usage)
        }
        emit(result: result, json: json)
        exit(ExitCode.ok)
    case .eof:
        errPrint("host 关闭连接且无响应")
        exit(ExitCode.unreachable)
    case .timedOut:
        errPrint("等待响应超时")
        exit(ExitCode.timeout)
    case .error(let e):
        errPrint("读响应错误: \(String(cString: strerror(e)))")
        exit(ExitCode.unreachable)
    }
}

/// 输出能力清单。json=true → stdout 打机读 JSON(经 JSONEncoder 重编,键序稳定);否则打人读清单。
func emit(result: CapabilityListResult, json: Bool) {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(result), let s = String(data: data, encoding: .utf8) {
            outPrint(s)
        } else {
            errPrint("清单编码失败")
            exit(ExitCode.usage)
        }
    } else {
        outPrint("已注册能力(\(result.capabilities.count)):")
        for c in result.capabilities {
            let schema = c.schemaSummary.map { "  —  \($0)" } ?? ""
            outPrint("  \(c.id)  [\(c.risk.rawValue)]  \(c.summary)\(schema)")
        }
    }
}

// ============ 入口 ============

@main
@MainActor
struct AAMain {
    static func main() {
        // 命令面按「域子命令组 + 动作」组织,为 03 票的 describe/call 及将来域子命令留扩展位。
        let args = Array(CommandLine.arguments.dropFirst())
        guard let group = args.first else { printUsage(); exit(ExitCode.usage) }

        switch group {
        case "capabilities":
            dispatchCapabilities(Array(args.dropFirst()))
        case "-h", "--help", "help":
            printUsage(); exit(ExitCode.ok)
        default:
            errPrint("未知命令组: \(group)")
            printUsage()
            exit(ExitCode.usage)
        }
    }

    /// `capabilities` 子命令组分发。02 票只实现 `list`;03 票在此加 `describe` / `call`。
    static func dispatchCapabilities(_ rest: [String]) -> Never {
        guard let action = rest.first else {
            errPrint("用法: aa capabilities list [--json]")
            exit(ExitCode.usage)
        }
        switch action {
        case "list":
            let json = rest.dropFirst().contains("--json")
            doCapabilitiesList(json: json)
        default:
            errPrint("未知 capabilities 动作: \(action)(02 票仅支持 list)")
            exit(ExitCode.usage)
        }
    }
}
