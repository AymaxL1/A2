// aa-agent —— 「宿主委托本地 agent」的试驾 CLI(agent-delegation 07 票)。
//   `run`    组装委托 → 拉起 → 落盘 → 判终态 → 出 report.html
//   `status` / `cancel` / `list` / `prune`  管理已有任务
// 依赖边:aa-agent → AAAgentCore(纯逻辑:组装 / 状态机 / 归一化 / 看门狗)+ AAAgentSystem(真进程与真文件系统)
//   + AAContracts(退出码单一来源)。
//
// **绝不碰现有 `aa` CLI 与 AAHostMacOS**(与 v1-core-proxy 16 票的并行红线)。本可执行是独立 target,
//   与 `aa` 一个字节都不共享(两处各有一份 errPrint/outPrint 是刻意的:共享就要动 `aa` 的施工面)。
//
// 两个已固化的 Swift 坑(照抄 `Sources/aa/AAMain.swift` 的样板):
//   1) 入口 @main @MainActor struct + `-parse-as-library`(故文件名非 main.swift,顶层不放可执行语句);
//   2) 任何 print 之后 fflush(stdout)——stdout 被重定向时是块缓冲,不 flush 断言脚本可能读不到输出。
//
// 产品原则(与 `aa` 一致):CLI 自身永不交互提问;机读 JSON 走 stdout,诊断走 stderr;
//   退出码统一引用 `AAContracts.AAExitCode`,不散写魔数。
//
// ============ 安全姿态(读这个文件的人必须知道)============
// `run` 会**真的**拉起 claude / codex:消耗真实配额与费用;且 Claude 侧走 `--permission-mode bypassPermissions`
//   时对文件系统**无隔离**(01 spike 第 7 题实证:`../` 与 `/tmp/…` 越界写均成功)。
//   Codex 侧有真沙箱(默认 read-only 档),两家在这一点上**不对称**,别指望同一套心智模型。
//   故:门禁(Scripts/check.sh)**只**跑 `--dry-run` 与用法错分支,一次进程都不拉;
//   真跑归 `Scripts/agent-smoke.sh`(手动、需人在场、明标真实配额消耗)。

import Foundation
import Darwin
import AAContracts
import AAAgentCore
import AAAgentSystem

// ============ 输出 ============

/// 诊断走 stderr(stdout 只留机读 JSON / 结果行)。
func errPrint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// 结果走 stdout,并立即 fflush。
func outPrint(_ s: String) {
    print(s)
    fflush(stdout)
}

/// 把任意 Codable 值经 JSONEncoder 打到 stdout(键序稳定)。编码失败 → 协议错(退出码 6)。
func emitJSON<T: Encodable>(_ value: T, pretty: Bool = false) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
                                      : [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else {
        errPrint("结果编码失败")
        exit(AAExitCode.protocolError)
    }
    outPrint(s)
}

/// 用法错统一收口:诊断走 stderr,退出码 1(客户端本地错,未触达任何 agent)。
func failUsage(_ message: String) -> Never {
    errPrint(message)
    errPrint("(用 `aa-agent --help` 看完整用法与退出码语义)")
    exit(AAExitCode.usage)
}

// ============ 选项 ============

/// 全部子命令共用的一份选项袋(哪个子命令认哪些键由各自的校验决定)。
struct AgentCLIOptions {
    /// 任务工作区根目录。优先级:`--root` > `AA_AGENT_TASKS_ROOT` 环境变量 > `AAPaths.agentTasksRoot`。
    /// 环境变量这一档是**给门禁与冒烟脚本**用的:它们必须能把工作区指到临时目录,绝不能碰用户真实的 `~/.aa/`。
    var root: String = ProcessInfo.processInfo.environment["AA_AGENT_TASKS_ROOT"] ?? AAPaths.agentTasksRoot
    var json = false
    var agent: AgentVendor?
    var prompt: String?
    var model: String?
    var workdir: String?
    var execPath: String?
    var sandbox: AgentCodexSandbox = .readOnly
    var allowedTools: [String] = []
    var idleTimeout = AgentWatchdogPolicy.default.idleTimeoutSeconds
    var toolTimeout = AgentWatchdogPolicy.default.toolInFlightTimeoutSeconds
    /// 发出终止意图后,把管道读到底的**上界**(秒)。
    /// 为什么必须有界(06 票 CR 明写):`drainToEOF` 在「降级按 pid 单杀」或「子进程 setsid 逃出进程组」时
    ///   可能**永远等不到 EOF** —— 那时读流线程会一直阻塞在 read 上,run 进程永远收不了尾。
    var drainTimeout = 30
    /// Codex:从哪个真实 CODEX_HOME 拷 `auth.json`(**只读源目录**)。默认 `~/.codex`。
    var codexHomeSource: String = ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    var initiator = "cli"
    /// 只组装、只打印,**不建工作区、不拉进程**(门禁靠它验 CLI 与组装器的接线,零配额消耗)。
    var dryRun = false
    var olderThanDays: Int?
    var keep: Int?
    var positional: [String] = []
}

/// 解析一个子命令的参数。任何用法错一律退出码 1(未触达 agent,是纯客户端错)。
func parseOptions(_ tokens: [String], command: String) -> AgentCLIOptions {
    var o = AgentCLIOptions()
    var i = 0
    /// 取下一个 token 当值:缺值、或下一个 token 是旗标 → 用法错(不把 `--json` 误吞成上一个选项的值)。
    func nextValue(_ flag: String) -> String {
        i += 1
        guard i < tokens.count, !tokens[i].hasPrefix("--") else {
            failUsage("选项 \(flag) 需要一个值(不能把下一个旗标当值)")
        }
        return tokens[i]
    }
    /// 取下一个 token 当值,**不检查它像不像旗标**。只给 `--prompt` 用。
    ///
    /// 委托原文完全可能以 `-` 甚至 `--` 开头(组装器专门为此在 Codex 侧补 `--` 终止符,还配了断言);
    ///   若 prompt 也套用上面那条保守规则,`aa-agent run --prompt "--help me"` 会在解析层就被判用法错,
    ///   组装器那条路径经 CLI **永远走不到** —— 测试覆盖了一个 CLI 造不出来的输入,是自相矛盾。
    /// 真正的缺值仍拦得住:`--prompt` 落在末尾时 `i >= tokens.count`,照样是用法错(门禁有断言)。
    func nextRawValue(_ flag: String) -> String {
        i += 1
        guard i < tokens.count else { failUsage("选项 \(flag) 需要一个值") }
        return tokens[i]
    }
    func nextInt(_ flag: String) -> Int {
        let raw = nextValue(flag)
        guard let v = Int(raw) else { failUsage("选项 \(flag) 需要一个整数,得到 \"\(raw)\"") }
        return v
    }

    while i < tokens.count {
        let token = tokens[i]
        switch token {
        case "--json":          o.json = true
        case "--dry-run":       o.dryRun = true
        case "-h", "--help":    outPrint(usageText()); exit(AAExitCode.success)
        case "--root":          o.root = nextValue(token)
        case "--prompt":        o.prompt = nextRawValue(token)   // 委托原文可以长得像旗标,见 nextRawValue
        case "--model":         o.model = nextValue(token)
        case "--workdir":       o.workdir = nextValue(token)
        case "--exec":          o.execPath = nextValue(token)
        case "--initiator":     o.initiator = nextValue(token)
        case "--codex-home":    o.codexHomeSource = nextValue(token)
        case "--allow-tool":    o.allowedTools.append(nextValue(token))
        case "--idle-timeout":  o.idleTimeout = nextInt(token)
        case "--tool-timeout":  o.toolTimeout = nextInt(token)
        case "--drain-timeout": o.drainTimeout = nextInt(token)
        case "--older-than":    o.olderThanDays = nextInt(token)
        case "--keep":          o.keep = nextInt(token)
        case "--agent":
            let raw = nextValue(token)
            guard let vendor = AgentVendor(rawValue: raw) else {
                failUsage("未知 agent: \(raw)(可选:\(AgentVendor.allCases.map(\.rawValue).joined(separator: " / ")))")
            }
            o.agent = vendor
        case "--sandbox":
            let raw = nextValue(token)
            guard let mode = AgentCodexSandbox(rawValue: raw) else {
                failUsage("未知 sandbox 档: \(raw)(可选:\(AgentCodexSandbox.allCases.map(\.rawValue).joined(separator: " / ")))")
            }
            o.sandbox = mode
        default:
            if token.hasPrefix("-") { failUsage("未知选项: \(token)(子命令 \(command))") }
            o.positional.append(token)
        }
        i += 1
    }

    // 阈值必须为正:`AgentWatchdogPolicy` 刻意「可配就真可配」不钳制(非正数意味着任何静默都算卡死),
    // 它把这道校验明确留给了 CLI —— 就是这里。
    if o.idleTimeout <= 0 || o.toolTimeout <= 0 || o.drainTimeout <= 0 {
        failUsage("超时阈值必须为正整数(idle=\(o.idleTimeout) tool=\(o.toolTimeout) drain=\(o.drainTimeout))")
    }
    return o
}

// ============ 帮助 ============

/// 退出码语义表 —— 数字与语义由 `AAContracts.AAExitCode.semantics` **单一来源**生成(不手写数字),
/// 与 `aa --help` 同一口径(消灭「帮助 prose 与常量各说各话」这类重复知识)。
func exitCodeTable() -> String {
    let rows = AAExitCode.semantics.map { "  \($0.code)  \($0.label)" }.joined(separator: "\n")
    return """
    退出码语义(单一来源: AAContracts.AAExitCode):
    \(rows)
    run 子命令的终态映射:completed→0 / timeout→3 / 拉起失败(agent 可执行不可达)→4 /
      failed·cancelled·orphaned→5 / 工作区或 meta 读写失败→6
    """
}

func usageText() -> String {
    """
    用法:
      aa-agent run --agent <claude|codex> --prompt <文本> [选项]   委托一次任务(会真拉起 agent)
      aa-agent status <task-id> [--json]                          只读某任务的 meta.json
      aa-agent cancel <task-id>                                   取消一个运行中的任务
      aa-agent list [--json]                                      列出全部任务(条数 + 磁盘占用)
      aa-agent prune [--older-than <天>] [--keep <条>]             清理终态任务目录(永不删 running/pending)

    run 选项:
      --model <名>           透传给 agent 的模型名(不给 = 用 agent 自己的默认)
      --workdir <目录>       agent 的工作目录(不给 = 任务目录下的 work/)
      --exec <路径>          agent 可执行路径(不给 = 按 PATH 与已知位置查找)
      --sandbox <档>         Codex 沙箱档: read-only(默认) / workspace-write / danger-full-access
      --allow-tool <工具>    Claude 工具白名单(可重复;不给 = 内置默认白名单)
      --idle-timeout <秒>    看门狗静默阈值(默认 \(AgentWatchdogPolicy.default.idleTimeoutSeconds))
      --tool-timeout <秒>    有工具在途时的放宽阈值(默认 \(AgentWatchdogPolicy.default.toolInFlightTimeoutSeconds))
      --drain-timeout <秒>   发出终止意图后把管道读到底的上界(默认 30)
      --codex-home <目录>    从哪个 CODEX_HOME 拷 auth.json(只读源目录;默认 ~/.codex)
      --dry-run              只组装并打印启动参数,**不建工作区、不拉进程、零配额消耗**

    通用选项:
      --root <目录>          任务工作区根目录(默认 ~/.aa/agent-tasks,可用 AA_AGENT_TASKS_ROOT 覆盖)
      --json                 机读输出走 stdout(诊断始终走 stderr)

    安全提示:
      * run 会消耗真实配额与费用;Claude 侧走 bypassPermissions,对文件系统**没有隔离**
        (实证:相对路径 ../ 与绝对路径 /tmp/… 的越界写都会成功)。请在专用目录里跑,并有人在场。
      * Codex 侧每任务使用独立的 $CODEX_HOME(只拷 auth.json,绝不拷 config.toml),用完即弃。

    \(exitCodeTable())
    """
}

// ============ 入口 ============

@main
@MainActor
struct AAAgentMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let sub = args.first else {
            errPrint("缺少子命令。")
            errPrint(usageText())
            exit(AAExitCode.usage)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "run":     doRun(parseOptions(rest, command: "run"))
        case "status":  doStatus(parseOptions(rest, command: "status"))
        case "cancel":  doCancel(parseOptions(rest, command: "cancel"))
        case "list":    doList(parseOptions(rest, command: "list"))
        case "prune":   doPrune(parseOptions(rest, command: "prune"))
        case "-h", "--help", "help":
            outPrint(usageText())          // 显式 help → stdout(用法错才走 stderr)
            exit(AAExitCode.success)
        default:
            errPrint("未知子命令: \(sub)")
            errPrint(usageText())
            exit(AAExitCode.usage)
        }
    }
}
