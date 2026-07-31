// ============ 域子命令(注册表元数据驱动的人体工学入口)============
import Foundation
import Darwin
import AAContracts

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
