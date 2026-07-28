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

// ============ CLI 本地错误码 + 统一错误信封(机读) ============

/// CLI 侧(未触达宿主语义)合成的 `error.code` 常量。
/// 与 `AAContracts.WireErrorCode`(宿主协议码)分工:这些码只出现在 aa 自己产生的错误信封里
/// (传输层失败 / 域子命令用法错 / install-cli 本地错),退出码另由具体分支直接指定(不经 forErrorCode)。
enum CLIErrorCode {
    /// 连不上宿主(或写请求 / 读响应期间断连)。→ 退出码 4。
    static let hostUnreachable = "host_unreachable"
    /// 等待宿主响应超时。→ 退出码 3。
    static let timeout = "timeout"
    /// 未知域/动词(域子命令映射到的能力 id 宿主不认)。→ 退出码 1(人体工学层视为用法错,给可发现提示)。
    static let unknownCommand = "unknown_command"
    /// 域子命令参数错(未知 --参数 / 类型强转失败)。→ 退出码 1。
    static let badArgument = "bad_argument"
    // —— install-cli 本地错(均 → 退出码 1)——
    static let targetExists = "target_exists"
    static let targetDirMissing = "target_dir_missing"
    static let targetIsDirectory = "target_is_directory"
    static let linkFailed = "link_failed"
    /// 覆盖/卸载时删除旧目标失败(如实报,不归因成 link_failed 建议 sudo)。→ 退出码 1。
    static let removeFailed = "remove_failed"
    /// 拒绝卸载:目标不是本 aa 建的符号链接(避免误删非自己建的)。→ 退出码 1。
    static let notOurLink = "not_our_link"
}

/// 把任意 `WireResponse<T>` 经 JSONEncoder 打到 stdout(稳定键序)。编码失败 → 协议错(退出码 6)。
func emitEnvelope<T: Codable>(_ resp: WireResponse<T>) {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(resp), let s = String(data: data, encoding: .utf8) else {
        errPrint("结果编码失败"); exit(AAExitCode.protocolError)
    }
    outPrint(s)
}

/// 打统一失败信封 `{"error":{"code","detail"},"ok":false}` 到 stdout(不手拼,走 WireResponse.failure)。
/// result 取 JSONValue 占位(必为 nil,编码时整键省略),与宿主失败信封同形状。
func emitErrorEnvelope(code: String, detail: String) {
    emitEnvelope(WireResponse<JSONValue>.failure(WireError(code: code, detail: detail)))
}

/// 本地(未触达宿主)用法/参数错的统一收口:`--json` 时 stdout 打机读错误信封,人读诊断走 stderr,退出码 1。
func failUsage(code: String, detail: String, human: String, json: Bool) -> Never {
    if json { emitErrorEnvelope(code: code, detail: detail) }
    errPrint(human)
    exit(AAExitCode.usage)
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

// ============ 子命令:list ============

/// `aa capabilities list`。连 UDS → 发 list 请求 → 解 WireResponse<CapabilityListResult> → 输出。
func doCapabilitiesList(json: Bool) -> Never {
    let line = roundTrip(WireRequest(op: WireOp.capabilitiesList), json: json)
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
    let line = roundTrip(WireRequest(op: WireOp.capabilitiesDescribe, capability: id), json: json)
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

/// `aa capabilities call <id> [--input '<json>']`。把 input 解析成 JSONValue,再走统一 call 底座 `performCall`。
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
    performCall(id: id, input: input, json: json)
}

/// 统一 call 底座(单一调用路径)。`capabilities call` 与域子命令都汇到这里:
/// 同一 UDS 请求(capabilities.call)、同一注册表路由、同一响应信封、同一退出码映射。
/// 域子命令只是把 `--参数 值` 强转成 input 的人体工学入口,底座与 call 完全一致。
func performCall(id: String, input: JSONValue?, json: Bool) -> Never {
    let line = roundTrip(WireRequest(op: WireOp.capabilitiesCall, capability: id, input: input), json: json)
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

// ============ 域子命令(注册表元数据驱动的人体工学入口)============

/// 解析后的域子命令:动词序列(域后的位置参数)、`--参数 值` 对(未强转的原始串)、是否 `--json`。
/// 域 + 动词序列先按 cliAlias 表匹配到能力 id,未命中再回退「id 段拼接」(见 `resolveDomainDescriptor`)。
struct DomainInvocation {
    let verbs: [String]
    let pairs: [(name: String, raw: String)]
    let json: Bool
}

/// 把 `aa <域> <动词...> [--<参数> <值> ...] [--json]` 解析成 DomainInvocation。
/// 形态约定:前导位置参数(不以 `--` 开头)= 域后的动词序列;其后是 `--参数 值` 对与 `--json`。
/// 任一用法错(缺动词 / 选项缺值 / 选项后再现位置参数)→ 退出码 1。
func parseDomainInvocation(domain: String, rest: [String], json0: Bool = false) -> DomainInvocation {
    var verbs: [String] = []
    var pairs: [(name: String, raw: String)] = []
    var json = json0
    var seenOption = false
    var i = 0
    while i < rest.count {
        let tok = rest[i]
        if tok == "--json" {
            json = true; seenOption = true; i += 1; continue
        }
        if tok == "-h" || tok == "--help" {
            // 显式 help 走 stdout(用法错才走 stderr)。
            outPrint(domainUsage(domain: domain)); exit(AAExitCode.success)
        }
        if tok.hasPrefix("--") {
            seenOption = true
            let name = String(tok.dropFirst(2))
            if name.isEmpty {
                failUsage(code: CLIErrorCode.badArgument, detail: "非法选项: \(tok)",
                          human: "非法选项: \(tok)\n\(domainUsage(domain: domain))", json: json)
            }
            // 值必须存在且不能是下一个旗标(以 -- 开头)——否则会把 `--message --json` 的 --json 误吞成值。
            i += 1
            guard i < rest.count, !rest[i].hasPrefix("--") else {
                failUsage(code: CLIErrorCode.badArgument, detail: "选项 --\(name) 需要一个值",
                          human: "选项 --\(name) 需要一个值(不能把下一个旗标当值)\n\(domainUsage(domain: domain))", json: json)
            }
            pairs.append((name, rest[i]))
            i += 1
            continue
        }
        // 裸位置参数:必须都在选项之前(构成动词序列)
        if seenOption {
            failUsage(code: CLIErrorCode.badArgument, detail: "多余的位置参数: \(tok)(动词须在选项之前)",
                      human: "多余的位置参数: \(tok)(动词须在选项之前)\n\(domainUsage(domain: domain))", json: json)
        }
        verbs.append(tok)
        i += 1
    }
    guard !verbs.isEmpty else {
        failUsage(code: CLIErrorCode.unknownCommand,
                  detail: "域 \(domain) 缺少动词",
                  human: "用法: \(domainUsage(domain: domain))\n用 `aa capabilities list` 查看可用能力。", json: json)
    }
    return DomainInvocation(verbs: verbs, pairs: pairs, json: json)
}

func domainUsage(domain: String) -> String {
    "aa \(domain) <动词...> [--<参数> <值> ...] [--json]  (映射到能力 \(domain).<动词...>,走 capabilities call 底座)"
}

/// 域子命令入口。先取能力清单(元数据),按 cliAlias 表 / id 段拼接把 `<域> <动词...>` 解析到能力 descriptor,
/// 再把 `--参数 值` 按声明类型强转成 input,走与 `capabilities call` 完全相同的底座(performCall)。
/// 未知域/动词 → 退出码 1 + 可发现提示。
func doDomainCommand(domain: String, rest: [String]) -> Never {
    let inv = parseDomainInvocation(domain: domain, rest: rest)
    let tokens = [domain] + inv.verbs

    // ① 取能力清单(一次 list 往返即拿到全部 descriptor + cliAlias + parameters)。传输失败在 roundTrip 内按统一 UX 收口。
    let descriptors = fetchCapabilityList(json: inv.json)

    // ② 元数据驱动解析:先按 cliAlias 表精确匹配 tokens,未命中回退 id 段拼接;都不中 → unknown_command(退出码1)。
    let descriptor = resolveDomainDescriptor(tokens: tokens, among: descriptors, json: inv.json)

    // ③ 按声明类型强转 `--参数 值`,组成 input 对象;无参数对则 input=nil(等价于 call <id> 不带 --input)。
    let specByName = Dictionary(descriptor.parameters.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    var obj: [String: JSONValue] = [:]
    for pair in inv.pairs {
        guard let spec = specByName[pair.name] else {
            let known = descriptor.parameters.map { "--\($0.name)" }.joined(separator: " ")
            failUsage(code: CLIErrorCode.badArgument,
                      detail: "能力 \(descriptor.id) 未声明参数 --\(pair.name)",
                      human: "未知参数 --\(pair.name)(能力 \(descriptor.id) 未声明)。可用参数: \(known.isEmpty ? "(无)" : known)。"
                           + "详见 `aa capabilities describe \(descriptor.id)`。",
                      json: inv.json)
        }
        obj[pair.name] = coerceArgument(raw: pair.raw, type: spec.type, param: pair.name, id: descriptor.id, json: inv.json)
    }
    let input: JSONValue? = inv.pairs.isEmpty ? nil : .object(obj)

    // ④ 走 call 底座:同路由、同响应信封、同退出码映射。
    performCall(id: descriptor.id, input: input, json: inv.json)
}

/// 域子命令用:取能力清单(含每条 descriptor 的 cliAlias + parameters)。宿主未运行等传输失败在 roundTrip 内统一收口。
func fetchCapabilityList(json: Bool) -> [CapabilityDescriptor] {
    let line = roundTrip(WireRequest(op: WireOp.capabilitiesList), json: json)
    let response = decodeResponse(line, as: CapabilityListResult.self)
    guard response.ok, let result = response.result else {
        failAndExit(response, json: json)
    }
    return result.capabilities
}

/// 把域子命令 tokens(`[域] + 动词...`)解析成能力 descriptor:
///   ① 先按 cliAlias 表精确匹配(元数据驱动,别名优先);
///   ② 未命中回退 05 的「id 段拼接映射」(tokens 直接拼成能力 id);
///   ③ 都不中 → 人体工学层「未知命令」→ 退出码 1 + 可发现提示(区别于底座 API 未知能力=协议错 6)。
func resolveDomainDescriptor(tokens: [String], among descriptors: [CapabilityDescriptor], json: Bool) -> CapabilityDescriptor {
    // ① cliAlias 精确匹配。first(where:) → 若两能力声明同一 cliAlias 会静默取首个(注册顺序在先者)。
    //    V1 能力集受控、别名唯一,故不做运行时去重;将来别名开放给动态插件时,应在注册期做重复别名检测/拒绝(记债)。
    if let hit = descriptors.first(where: { $0.cliAlias == tokens }) {
        return hit
    }
    // ② 回退:tokens 拼成能力 id 直接匹配。
    let id = tokens.joined(separator: ".")
    if let hit = descriptors.first(where: { $0.id == id }) {
        return hit
    }
    // ③ 未知命令。
    let shown = tokens.joined(separator: " ")
    failUsage(code: CLIErrorCode.unknownCommand,
              detail: "未知命令: \(shown)",
              human: "未知命令: \(shown)。用 `aa capabilities list` 查看可用能力,或 `aa capabilities describe <id>` 查看某能力的参数。",
              json: json)
}

/// 按 ParameterSpec 声明类型把字符串实参强转为 JSONValue。强转失败 → 退出码 1(客户端本地用法错)。
/// 类型串取值与 `JSONValue.typeName` / schema 对齐:string / number / bool / object / array;未知类型按 string 放行(与宿主宽松校验一致)。
func coerceArgument(raw: String, type: String, param: String, id: String, json: Bool) -> JSONValue {
    switch type {
    case "string":
        return .string(raw)
    case "number":
        // 钳制非有限值:Double("inf"/"nan"/"infinity") 会被 Double(_:) 接受,但 JSONValue.number(inf/nan)
        // 经 JSONEncoder 会抛错 → 在 sendRequest 里被当"写请求失败"误报退出码 4(宿主在跑却说不可达)。
        // 故非有限值一律判用法错(退出码 1),参照 timeoutSeconds() 里对 inf/nan 的同款钳制。
        guard let d = Double(raw), d.isFinite else {
            failUsage(code: CLIErrorCode.badArgument, detail: "参数 --\(param) 需要有限 number,得到 \"\(raw)\"",
                      human: "参数 --\(param)(能力 \(id))应为有限 number,无法接受 \"\(raw)\"(inf/nan 等非有限值不允许)。", json: json)
        }
        return .number(d)
    case "bool":
        switch raw.lowercased() {
        case "true":  return .bool(true)
        case "false": return .bool(false)
        default:
            failUsage(code: CLIErrorCode.badArgument, detail: "参数 --\(param) 需要 bool(true/false),得到 \"\(raw)\"",
                      human: "参数 --\(param)(能力 \(id))应为 bool,请传 true 或 false(得到 \"\(raw)\")。", json: json)
        }
    case "object":
        guard let v = parseJSONArgument(raw), case .object = v else {
            failUsage(code: CLIErrorCode.badArgument, detail: "参数 --\(param) 需要 JSON object,得到 \"\(raw)\"",
                      human: "参数 --\(param)(能力 \(id))应为 JSON object,如 --\(param) '{\"k\":\"v\"}'(得到 \"\(raw)\")。", json: json)
        }
        return v
    case "array":
        guard let v = parseJSONArgument(raw), case .array = v else {
            failUsage(code: CLIErrorCode.badArgument, detail: "参数 --\(param) 需要 JSON array,得到 \"\(raw)\"",
                      human: "参数 --\(param)(能力 \(id))应为 JSON array,如 --\(param) '[1,2]'(得到 \"\(raw)\")。", json: json)
        }
        return v
    default:
        // 未知声明类型:宿主侧 typeMatches 对未知期望类型放行,这里对齐为按原样字符串承载。
        return .string(raw)
    }
}

/// 把字符串按 JSON 解析成 JSONValue(object/array 参数用);解析失败返回 nil。
func parseJSONArgument(_ raw: String) -> JSONValue? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

// ============ aa docs agents-md(接入引导片段)============

/// `aa docs <主题>`。目前只有 `agents-md`:输出可整段贴进任意仓库 AGENTS.md 的 markdown 片段。
/// 纯文档,不连宿主(agent 离线也能取);指令文本英文。
func dispatchDocs(_ rest: [String]) -> Never {
    guard let topic = rest.first else {
        errPrint("用法: aa docs agents-md   输出可贴进仓库 AGENTS.md 的接入片段(markdown)")
        exit(AAExitCode.usage)
    }
    switch topic {
    case "agents-md":
        outPrint(agentsMarkdownSnippet())
        exit(AAExitCode.success)
    case "-h", "--help":
        outPrint("用法: aa docs agents-md   输出可贴进仓库 AGENTS.md 的接入片段(markdown)")
        exit(AAExitCode.success)
    default:
        errPrint("未知 docs 主题: \(topic)")
        errPrint("用法: aa docs agents-md")
        exit(AAExitCode.usage)
    }
}

/// AGENTS.md 接入片段(英文,面向 Codex 等外部 agent)。必含:何时用 / 发现·调用 / 退出码 / dangerous 语义 / prefix_rule 信任配置。
func agentsMarkdownSnippet() -> String {
    return """
    <!-- BEGIN aa CLI integration — generated by `aa docs agents-md` -->
    ## Using the `aa` CLI (agent-facing proxy/agent control)

    `aa` is the command surface for the local AA menu-bar agent host. Whenever you
    (an AI coding agent such as Codex) need to inspect or operate the local proxy
    or any registered capability, call `aa` instead of editing system settings
    directly.

    ### When to use `aa`

    - The task involves the proxy, the agent host, or any registered capability
      (status, mode, node, subscription, ...).
    - You need to discover which operations this machine actually supports.
    - You want a stable, machine-readable result you can branch on.

    If the task does not touch the agent/proxy, you do not need `aa`.

    ### Discover & call

    Discovery and invocation share one registry-backed surface. Every command
    accepts `--json` for stable machine-readable stdout; human diagnostics go to
    stderr.

    ```
    aa capabilities list --json                           # enumerate capabilities (id, risk, summary, schema)
    aa capabilities describe <id> --json                  # full structured schema (parameters) for one capability
    aa capabilities call <id> --input '<json>' --json     # invoke with a JSON input object
    ```

    Ergonomic domain sub-commands map registry metadata onto `<domain> <verb...>`
    and run through the exact same path as `capabilities call` (same route, same
    response envelope, same exit codes). Named flags are coerced to each
    parameter's declared type:

    ```
    aa demo echo --message hi --json
    # behaves identically to:
    aa capabilities call demo.echo --input '{"message":"hi"}' --json
    ```

    An unknown domain command (`aa <domain> <verb>` that maps to no capability)
    is a usage error: exit `1`, `error.code=unknown_command`. This differs from
    the base API `aa capabilities call|describe <id>` on an unknown capability id,
    which is a protocol/validation error: exit `6`, `error.code=unknown_capability`.

    ### Exit codes (stable contract)

    Branch on the process exit code; the `--json` error envelope carries a finer
    `error.code`.

    - `0`  success
    - `1`  usage error (bad CLI arguments, or an unknown domain sub-command)
    - `2`  denied (a dangerous capability was refused at the host)
    - `3`  timeout
    - `4`  host unreachable (the AA host is not running)
    - `5`  capability business failure
    - `6`  protocol / validation error (unknown capability, missing/typed param)

    On failure with `--json`, stdout is a `{"ok":false,"error":{"code":...,"detail":...}}`
    envelope; on success it is the capability's own JSON output.

    ### Dangerous capabilities

    Capabilities marked `dangerous` (trust-surface changes) require final
    confirmation in the host GUI. The CLI never blocks and never prompts: if the
    user approves, the call proceeds; if they refuse — or no GUI is available —
    the call returns `error.code=denied` with exit code `2`. Do not attempt to
    bypass this; there is no CLI flag that approves a dangerous capability.

    ### Trust setup for a sandboxed Codex (one-time)

    Under Codex's default `workspace-write` sandbox, all local IPC (Unix sockets
    and localhost TCP) is blocked at the syscall level, so `aa` cannot reach the
    host from inside the sandbox. The supported posture is to run `aa` *outside*
    the sandbox via an escalated trust rule scoped to the `aa` prefix:

    - Mark the command escalated: `sandbox_permissions: "require_escalated"`.
    - Scope the persisted trust to the `aa` prefix: `prefix_rule ["aa"]`.

    Codex surfaces this as a persistable allow-rule; approve it once in an
    interactive session. The design intent is that the approval persists across
    sessions, after which `aa ...` runs outside the sandbox with IPC intact.
    Note: the exact persisted config form and its cross-session persistence are
    not yet verified in practice — confirm with that one-time interactive
    approval. If this machine's Codex already runs `danger-full-access`, no
    action is needed. MCP tool calls do not go through the shell sandbox, so a
    future thin MCP adapter over the same registry would sidestep this entirely.
    <!-- END aa CLI integration -->
    """
}

// ============ aa install-cli(符号链接入 PATH)============

/// install-cli 的机读成功载荷。
struct InstallResult: Codable, Sendable, Equatable {
    /// installed / already-installed / overwritten。
    let action: String
    let target: String
    let source: String
}

/// 当前 aa 可执行的绝对路径(符号链接的源)。首选 `_NSGetExecutablePath`(macOS 规范取法),
/// 回退 argv[0] / Bundle;经 resolvingSymlinksInPath 规整为干净绝对路径。
func currentExecutablePath() -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)               // 先探所需缓冲大小
    if size > 0 {
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 {
            let raw = String(cString: buf)
            return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        }
    }
    if let p = Bundle.main.executablePath {
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
    let a0 = CommandLine.arguments.first ?? "aa"
    let abs = a0.hasPrefix("/") ? a0 : FileManager.default.currentDirectoryPath + "/" + a0
    return URL(fileURLWithPath: abs).resolvingSymlinksInPath().path
}

/// target 处的符号链接(canonical 化后)是否指向 source。
/// `destinationOfSymbolicLink` 返回原样存储值(可能相对 / 未规整);必须按链接所在目录解析成绝对路径再 canonical 化,
/// 否则相对链接、`/tmp` vs `/private/tmp`(/tmp 本身是 symlink)等"等价但字面不同"会被误判成"指向别处"、逼用户 --force。
/// source 已由 currentExecutablePath() 经 resolvingSymlinksInPath 规整,两边同等 canonical 再比。
func symlinkCanonicalDestination(linkPath: String) -> String? {
    guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else { return nil }
    let base = URL(fileURLWithPath: linkPath).deletingLastPathComponent()
    return URL(fileURLWithPath: dest, relativeTo: base).resolvingSymlinksInPath().path
}

func symlinkPointsTo(linkPath: String, source: String) -> Bool {
    symlinkCanonicalDestination(linkPath: linkPath) == source
}

/// 覆盖/卸载前删除旧目标;失败时如实报(remove_failed),不吞错、也不归因成 link_failed 建议 sudo。
/// 返回 Void(成功),失败走 failUsage(Never)。
func removeExistingTarget(_ path: String, json: Bool) {
    do {
        try FileManager.default.removeItem(atPath: path)
    } catch {
        failUsage(code: CLIErrorCode.removeFailed,
                  detail: "删除旧目标失败: \(path): \(error.localizedDescription)",
                  human: "install-cli 失败:无法删除旧目标 \(path)(\(error.localizedDescription))。", json: json)
    }
}

/// `aa install-cli [--prefix <dir>] [--force] [--json]`:把当前 aa 符号链接进 PATH。
/// 幂等:已指向同源→no-op 成功;指向别处/非链接文件→需 --force 覆盖;目标目录不存在→明确错误。均不连宿主。
func dispatchInstallCli(_ rest: [String]) -> Never {
    var prefix: String? = nil
    var force = false
    var json = false
    var uninstall = false
    var i = 0
    while i < rest.count {
        let tok = rest[i]
        switch tok {
        case "--force":     force = true
        case "--json":      json = true
        case "--uninstall": uninstall = true
        case "--prefix":
            i += 1
            guard i < rest.count else { errPrint("--prefix 需要一个目录参数"); exit(AAExitCode.usage) }
            prefix = rest[i]
        case "-h", "--help":
            outPrint(installCliUsage()); exit(AAExitCode.success)
        default:
            errPrint("未知选项: \(tok)"); errPrint(installCliUsage()); exit(AAExitCode.usage)
        }
        i += 1
    }
    if uninstall {
        doUninstallCli(prefix: prefix, json: json)   // --uninstall 与 --force 无关(卸载不需要 force)
    }
    doInstallCli(prefix: prefix, force: force, json: json)
}

func installCliUsage() -> String {
    """
    用法: aa install-cli [--prefix <dir>] [--force] [--json]
          aa install-cli --uninstall [--prefix <dir>] [--json]
      默认把 aa 符号链接到 /usr/local/bin/aa;--prefix 覆盖目标目录。
      幂等:已指向同一 aa → no-op 成功;指向别处/普通文件 → 需 --force 覆盖;目标目录不存在 → 报错。
      --uninstall:删除指向本 aa 的符号链接(幂等:不存在即成功;不误删普通文件/目录/指向别处的链接)。
    """
}

func doInstallCli(prefix: String?, force: Bool, json: Bool) -> Never {
    let fm = FileManager.default
    let source = currentExecutablePath()
    let dir = prefix ?? "/usr/local/bin"
    let target = (dir as NSString).appendingPathComponent("aa")

    // 目标目录须已存在(不代建,避免误建系统目录)。
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
        failUsage(code: CLIErrorCode.targetDirMissing, detail: "目标目录不存在: \(dir)",
                  human: "install-cli 失败:目标目录不存在: \(dir)(请先创建,或用 --prefix 指定已存在目录)。", json: json)
    }

    // 用 attributesOfItem(不追随末端符号链接)判目标当前形态。
    let itemType = (try? fm.attributesOfItem(atPath: target))?[.type] as? FileAttributeType

    if itemType == nil {
        // 不存在 → 直接建链接。
        installCreateLink(source: source, target: target, action: "installed", json: json)
    }
    if itemType == .typeSymbolicLink {
        // canonical 化后比较(修:相对链接 / /tmp vs /private/tmp 等价但字面不同不再误判为"指向别处")。
        let canonicalDest = symlinkCanonicalDestination(linkPath: target) ?? "(无法解析)"
        if symlinkPointsTo(linkPath: target, source: source) {
            // 幂等:已指向同源 → no-op 成功。
            installFinishSuccess(action: "already-installed", source: source, target: target, json: json,
                                 human: "install-cli:已安装且指向一致(no-op) \(target) → \(source)")
        }
        if !force {
            failUsage(code: CLIErrorCode.targetExists,
                      detail: "符号链接已存在且指向别处: \(target) → \(canonicalDest)",
                      human: "install-cli 失败:\(target) 已存在且指向 \(canonicalDest)(非本 aa)。确认后加 --force 覆盖。", json: json)
        }
        removeExistingTarget(target, json: json)
        installCreateLink(source: source, target: target, action: "overwritten", json: json)
    }
    if itemType == .typeDirectory {
        // 目录一律不覆盖(哪怕 --force),避免误删。
        failUsage(code: CLIErrorCode.targetIsDirectory, detail: "目标是目录,拒绝覆盖: \(target)",
                  human: "install-cli 失败:目标是目录,拒绝覆盖: \(target)。", json: json)
    }
    // 普通文件(或其它非目录非链接类型):需 --force 才覆盖。
    if !force {
        failUsage(code: CLIErrorCode.targetExists, detail: "目标已存在(非符号链接): \(target)",
                  human: "install-cli 失败:\(target) 已存在(非符号链接)。确认后加 --force 覆盖。", json: json)
    }
    removeExistingTarget(target, json: json)
    installCreateLink(source: source, target: target, action: "overwritten", json: json)
}

/// `aa install-cli --uninstall [--prefix <dir>]`:删除指向本 aa 的符号链接。
/// 幂等:目标不存在 → no-op 成功(not-installed);指向本 aa 的符号链接 → 删除(uninstalled);
/// 普通文件/目录 / 指向别处的链接 → 拒绝(不误删非自己建的),退出码 1。均不连宿主。
func doUninstallCli(prefix: String?, json: Bool) -> Never {
    let fm = FileManager.default
    let source = currentExecutablePath()
    let dir = prefix ?? "/usr/local/bin"
    let target = (dir as NSString).appendingPathComponent("aa")

    let itemType = (try? fm.attributesOfItem(atPath: target))?[.type] as? FileAttributeType
    if itemType == nil {
        // 幂等:本就不存在 → no-op 成功。
        installFinishSuccess(action: "not-installed", source: source, target: target, json: json,
                             human: "install-cli --uninstall:目标不存在,无需卸载(no-op) \(target)")
    }
    // 只删"指向本 aa 的符号链接";普通文件/目录 / 指向别处的链接一律拒绝(避免误删非自己建的)。
    guard itemType == .typeSymbolicLink, symlinkPointsTo(linkPath: target, source: source) else {
        let cur = symlinkCanonicalDestination(linkPath: target) ?? "(非符号链接)"
        failUsage(code: CLIErrorCode.notOurLink,
                  detail: "拒绝卸载:\(target) 不是指向本 aa 的符号链接(当前: \(cur))",
                  human: "install-cli --uninstall 失败:\(target) 不是本 aa 建的符号链接(当前指向 \(cur)),"
                       + "拒绝删除(避免误删非自己建的)。", json: json)
    }
    removeExistingTarget(target, json: json)
    installFinishSuccess(action: "uninstalled", source: source, target: target, json: json,
                         human: "install-cli:已卸载 \(target)(原指向 \(source))")
}

/// 建符号链接;失败(如目录无写权限)→ 退出码 1 + 明确提示。成功走统一成功收口。
func installCreateLink(source: String, target: String, action: String, json: Bool) -> Never {
    do {
        try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: source)
    } catch {
        failUsage(code: CLIErrorCode.linkFailed,
                  detail: "创建符号链接失败: \(target) → \(source): \(error.localizedDescription)",
                  human: "install-cli 失败:无法创建符号链接 \(target)(\(error.localizedDescription))。"
                       + "若目标目录需要权限,请用 sudo 或改 --prefix 到可写目录。", json: json)
    }
    let verb = action == "overwritten" ? "覆盖并安装" : "安装"
    installFinishSuccess(action: action, source: source, target: target, json: json,
                         human: "install-cli:已\(verb) \(target) → \(source)")
}

/// install-cli 成功收口:`--json` 打机读信封;否则人读一行;退出码 0。
func installFinishSuccess(action: String, source: String, target: String, json: Bool, human: String) -> Never {
    if json {
        emitEnvelope(WireResponse.success(InstallResult(action: action, target: target, source: source)))
    } else {
        outPrint(human)
    }
    exit(AAExitCode.success)
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

func usageText() -> String {
    """
    用法:
      aa capabilities list [--json]                         列出已注册能力
      aa capabilities describe <id> [--json]                打印单个能力完整 schema(含 parameters)
      aa capabilities call <id> [--input '<json>'] [--json] 调用能力;结果 JSON 走 stdout
      aa <域> <动词...> [--<参数> <值> ...] [--json]         域子命令:映射到能力 <域>.<动词...>,走 call 底座
                                                            (如 aa demo echo --message hi ≡ call demo.echo)
      aa docs agents-md                                     输出可贴进仓库 AGENTS.md 的接入片段(markdown)
      aa install-cli [--prefix <dir>] [--force] [--json]    把 aa 符号链接进 PATH(默认 /usr/local/bin)
      aa install-cli --uninstall [--prefix <dir>] [--json]  删除指向本 aa 的符号链接(幂等)

    \(exitCodeTable())
    """
}

/// 用法错分支:用法文本走 stderr(诊断)。显式 `-h/--help` 请走 `outPrint(usageText())`(stdout),口径一致。
func printUsage() {
    errPrint(usageText())
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
        case "docs":
            dispatchDocs(Array(args.dropFirst()))
        case "install-cli":
            dispatchInstallCli(Array(args.dropFirst()))
        case "-h", "--help", "help":
            outPrint(usageText()); exit(AAExitCode.success)   // 显式 help → stdout
        default:
            // 其余首 token 视为「域」——域子命令(注册表元数据驱动的人体工学入口),映射到能力 <域>.<动词...>。
            // 保留字 capabilities / docs / install-cli / help 已在上面拦截,不会落到这里。
            doDomainCommand(domain: group, rest: Array(args.dropFirst()))
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
            outPrint(usageText()); exit(AAExitCode.success)   // 显式 help → stdout

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
