// aa —— 面向 Agent/人 的双层命令面 CLI。
//   02 票:`aa capabilities list [--json]`。
//   03 票:`aa capabilities describe <id> [--json]`、`aa capabilities call <id> [--input '<json>'] [--json]`,
//          并把退出码语义表落进 `--help`,退出码统一引用 AAContracts.AAExitCode(不散写魔数)。
// 依赖边:aa → AAContracts(线协议 / 描述符 / socket 路径常量 / 退出码表都从这里取)。
//
// 两个已固化的 Swift 坑(照抄):
//   1) 入口 @main @MainActor struct + -parse-as-library(故文件名非 main.swift,顶层不放可执行语句)。
//   2) 任何 print 之后 fflush(stdout)——stdout 被重定向时是块缓冲,不 flush 断言脚本可能读不到输出。
//
// 产品原则(spec):CLI 自身永不交互提问;机读 JSON 走 stdout,诊断走 stderr。
// dangerous 确认只在宿主 GUI 完成(退出码 2=denied 留给 04 票);本 CLI 不做交互阻塞。

import Foundation
import Darwin
import AAContracts

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

/// 读/写超时秒数。默认 10s;可经 `AA_TIMEOUT_SECONDS` 覆盖(仅供门禁 E2E 造超时用,不改默认行为)。
/// 钳制:非有限(inf/nan)、<=0、超上界的输入一律回退/收口,防 `setTimeout` 里 `Int(seconds)` 对 inf/超大值运行时 trap。
func timeoutSeconds() -> Double {
    let defaultSeconds = 10.0
    let maxSeconds = 3600.0   // 上界(1 小时);远超任何真实用途,只为杜绝 Int(seconds) 溢出 trap
    guard let raw = ProcessInfo.processInfo.environment["AA_TIMEOUT_SECONDS"],
          let v = Double(raw), v.isFinite, v > 0 else {
        return defaultSeconds
    }
    return min(v, maxSeconds)
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

// ============ 通用请求-响应往返(连 UDS → 发 → 收一行)============

/// 连 UDS、发请求、读一行响应,统一把不可达/超时/EOF 折叠成退出。成功则返回响应行文本。
/// 语义错误(host 返回 ok=false)交给上层按 error.code 映射退出码,故这里只处理「传输层」失败。
func roundTrip(_ request: WireRequest) -> String {
    guard let fd = connectUDS() else {
        errPrint("host 不可达:无法连接 \(AAPaths.socketPath)。请先启动 AAHost。")
        exit(AAExitCode.hostUnreachable)
    }
    // 注:本函数所有失败分支都 exit(_:),exit 不跑 defer;fd 由进程退出统一回收,故不设 defer close。
    setTimeout(fd: fd, seconds: timeoutSeconds())
    guard sendRequest(fd: fd, request: request) else {
        errPrint("host 不可达:写请求失败")
        exit(AAExitCode.hostUnreachable)
    }
    switch readResponseLine(fd: fd) {
    case .line(let line):
        return line
    case .eof:
        errPrint("host 关闭连接且无响应")
        exit(AAExitCode.hostUnreachable)
    case .timedOut:
        errPrint("等待响应超时")
        exit(AAExitCode.timeout)
    case .error(let e):
        errPrint("读响应错误: \(String(cString: strerror(e)))")
        exit(AAExitCode.hostUnreachable)
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

// ============ 子命令:list ============

/// `aa capabilities list`。连 UDS → 发 list 请求 → 解 WireResponse<CapabilityListResult> → 输出。
func doCapabilitiesList(json: Bool) -> Never {
    let line = roundTrip(WireRequest(op: WireOp.capabilitiesList))
    let response = decodeResponse(line, as: CapabilityListResult.self)
    guard response.ok, let result = response.result else {
        failAndExit(response, json: json)
    }
    if json {
        emitJSON(result)
    } else {
        outPrint("已注册能力(\(result.capabilities.count)):")
        for c in result.capabilities {
            let schema = c.schemaSummary.map { "  —  \($0)" } ?? ""
            outPrint("  \(c.id)  [\(c.risk.rawValue)]  \(c.summary)\(schema)")
        }
    }
    exit(AAExitCode.success)
}

// ============ 子命令:describe ============

/// `aa capabilities describe <id>`。输出完整描述符(id/risk/summary/parameters),足以让 agent 构造调用。
func doCapabilitiesDescribe(id: String, json: Bool) -> Never {
    let line = roundTrip(WireRequest(op: WireOp.capabilitiesDescribe, capability: id))
    let response = decodeResponse(line, as: DescribeResult.self)
    guard response.ok, let result = response.result else {
        failAndExit(response, json: json)
    }
    let d = result.descriptor
    if json {
        emitJSON(d) // 直接打描述符对象(含 parameters 数组),而非包一层 result
    } else {
        outPrint("\(d.id)  [\(d.risk.rawValue)]  \(d.summary)")
        if let s = d.schemaSummary { outPrint("  摘要: \(s)") }
        outPrint("  参数(\(d.parameters.count)):")
        for p in d.parameters {
            outPrint("    \(p.name): \(p.type)\(p.required ? " (必填)" : " (可选)")  —  \(p.description)")
        }
    }
    exit(AAExitCode.success)
}

// ============ 子命令:call ============

/// `aa capabilities call <id> [--input '<json>']`。把 input 解析成 JSONValue、发 call、打机读结果、映射退出码。
func doCapabilitiesCall(id: String, inputJSON: String?, json: Bool) -> Never {
    // 解析 --input(仅校验 JSON 语法;schema 校验是宿主的事,客户端不可绕过)。语法错 → 用法错(退出码 1)。
    var input: JSONValue? = nil
    if let raw = inputJSON {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            errPrint("--input 不是合法 JSON: \(raw)")
            exit(AAExitCode.usage)
        }
        input = parsed
    }

    let line = roundTrip(WireRequest(op: WireOp.capabilitiesCall, capability: id, input: input))
    let response = decodeResponse(line, as: CallResult.self)
    guard response.ok, let result = response.result else {
        failAndExit(response, json: json)
    }
    // 成功:打能力输出(任意 JSON)。--json 走稳定键序紧凑;否则漂亮打印便于人读。
    emitJSON(result.output, pretty: !json)
    exit(AAExitCode.success)
}

// ============ 输出编码助手 ============

/// 把任意 Codable 值经 JSONEncoder 打到 stdout(键序稳定;pretty 时缩进)。编码失败 → 协议错(退出码 6)。
func emitJSON<T: Encodable>(_ value: T, pretty: Bool = false) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
    guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else {
        errPrint("结果编码失败")
        exit(AAExitCode.protocolError)
    }
    outPrint(s)
}

// ============ 帮助 ============

func exitCodeTable() -> String {
    // 退出码数字与语义由 AAExitCode.semantics 单一来源生成(不再手写数字),消灭帮助 prose 与常量的重复知识。
    let rows = AAExitCode.semantics
        .map { "  \($0.code)  \($0.label)" }
        .joined(separator: "\n")
    return """
    退出码语义(单一来源: AAContracts.AAExitCode;细因见响应 error.code):
    \(rows)
    error.code 细因: unknown_capability / missing_parameter / type_mismatch / invalid_params / capability_failed 等
    """
}

func printUsage() {
    errPrint("""
    用法:
      aa capabilities list [--json]                         列出已注册能力
      aa capabilities describe <id> [--json]                打印单个能力完整 schema(含 parameters)
      aa capabilities call <id> [--input '<json>'] [--json] 调用能力;结果 JSON 走 stdout

    \(exitCodeTable())
    """)
}

// ============ 入口 ============

@main
@MainActor
struct AAMain {
    static func main() {
        // 命令面按「域子命令组 + 动作」组织。
        let args = Array(CommandLine.arguments.dropFirst())
        guard let group = args.first else { printUsage(); exit(AAExitCode.usage) }

        switch group {
        case "capabilities":
            dispatchCapabilities(Array(args.dropFirst()))
        case "-h", "--help", "help":
            printUsage(); exit(AAExitCode.success)
        default:
            errPrint("未知命令组: \(group)")
            printUsage()
            exit(AAExitCode.usage)
        }
    }

    /// `capabilities` 子命令组分发:list / describe / call(+ --help)。
    static func dispatchCapabilities(_ rest: [String]) -> Never {
        guard let action = rest.first else {
            printUsage()
            exit(AAExitCode.usage)
        }
        let tail = Array(rest.dropFirst())
        switch action {
        case "list":
            doCapabilitiesList(json: tail.contains("--json"))

        case "describe":
            let (id, json) = parseIDAndJSON(tail, usage: "aa capabilities describe <id> [--json]")
            doCapabilitiesDescribe(id: id, json: json)

        case "call":
            let (id, inputJSON, json) = parseCallArgs(tail)
            doCapabilitiesCall(id: id, inputJSON: inputJSON, json: json)

        case "-h", "--help":
            printUsage(); exit(AAExitCode.success)

        default:
            errPrint("未知 capabilities 动作: \(action)")
            printUsage()
            exit(AAExitCode.usage)
        }
    }

    /// 解析「<id> [--json]」型参数。缺 id 或多余定位参数 → 用法错(退出码 1)。
    static func parseIDAndJSON(_ tokens: [String], usage: String) -> (String, Bool) {
        var id: String? = nil
        var json = false
        for tok in tokens {
            if tok == "--json" { json = true }
            else if tok.hasPrefix("--") { errPrint("未知选项: \(tok)"); exit(AAExitCode.usage) }
            else if id == nil { id = tok }
            else { errPrint("多余参数: \(tok)"); exit(AAExitCode.usage) }
        }
        guard let capID = id else { errPrint("用法: \(usage)"); exit(AAExitCode.usage) }
        return (capID, json)
    }

    /// 解析「<id> [--input '<json>'] [--json]」。缺 id / --input 缺值 / 多余参数 → 用法错(退出码 1)。
    static func parseCallArgs(_ tokens: [String]) -> (String, String?, Bool) {
        var id: String? = nil
        var inputJSON: String? = nil
        var json = false
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            switch tok {
            case "--json":
                json = true
            case "--input":
                i += 1
                guard i < tokens.count else { errPrint("--input 需要一个 JSON 参数"); exit(AAExitCode.usage) }
                inputJSON = tokens[i]
            default:
                if tok.hasPrefix("--") { errPrint("未知选项: \(tok)"); exit(AAExitCode.usage) }
                if id == nil { id = tok } else { errPrint("多余参数: \(tok)"); exit(AAExitCode.usage) }
            }
            i += 1
        }
        guard let capID = id else {
            errPrint("用法: aa capabilities call <id> [--input '<json>'] [--json]")
            exit(AAExitCode.usage)
        }
        return (capID, inputJSON, json)
    }
}
