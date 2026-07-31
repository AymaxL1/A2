// ============ 帮助 ============
import Foundation
import Darwin
import AAContracts

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
      aa capabilities result <request-id> [--json]          查询 dangerous pending 调用结果
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

        case "result":
            let (requestID, json) = parseIDAndJSON(tail, usage: "aa capabilities result <request-id> [--json]")
            doCapabilitiesResult(requestID: requestID, json: json)

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
