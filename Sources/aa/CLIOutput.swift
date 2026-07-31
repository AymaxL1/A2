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
