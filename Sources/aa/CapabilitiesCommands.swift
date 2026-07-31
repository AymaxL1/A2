// ============ 子命令:list ============
import Foundation
import Darwin
import AAContracts

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
    if result.pending, let requestID = result.requestID {
        emitJSON(JSONValue.object(["pending": .bool(true), "requestId": .string(requestID)]), pretty: !json)
        exit(AAExitCode.success)
    }
    guard let output = result.output else {
        errPrint("宿主返回了既非 pending 也无 output 的 call 结果")
        exit(AAExitCode.protocolError)
    }
    // 成功:打能力输出(任意 JSON)。--json 走稳定键序紧凑;否则漂亮打印便于人读。
    emitJSON(output, pretty: !json)
    exit(AAExitCode.success)
}

func doCapabilitiesResult(requestID: String, json: Bool) -> Never {
    let line = roundTrip(WireRequest(op: WireOp.capabilitiesResult, requestID: requestID), json: json)
    let response = decodeResponse(line, as: CallResult.self)
    guard response.ok, let result = response.result else { failAndExit(response, json: json) }
    if result.pending {
        emitJSON(JSONValue.object(["pending": .bool(true), "requestId": .string(requestID)]), pretty: !json)
    } else if let output = result.output {
        emitJSON(output, pretty: !json)
    } else {
        errPrint("宿主返回了无效的 result 结果")
        exit(AAExitCode.protocolError)
    }
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
