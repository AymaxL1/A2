// aa-agent —— `status` / `cancel` / `list` / `prune`:已有任务的管理面。
//
// ============ 04 票 CR 回填的两条纪律,本文件是它们的落点 ============
// 1. **`list` / `status` 必须逐条降级,不能一颗老鼠坏一锅汤**。`AgentTaskState` 是**严格解码**的:
//    未知 state 值(比如将来某个版本写了 `paused`)会让 `readMeta` 抛错。`list()` 本身不解码 meta,
//    所以任务照常被列出;但**渲染状态那一步**必须 `try?` 逐条降级显示「不可读」——
//    绝不能让一个任务把整条 `list` 命令打挂(那时用户连「哪个任务坏了」都看不到)。
// 2. **读操作顺手做残留扫描**(提案 §4):`status` / `list` / `prune` 进来先扫一遍
//    「meta 记着 running 但 pid 已死」的崩溃残留,标 `orphaned`。扫描**只**改 state,
//    连 `finished_at` 都不填(不知道它何时死的,凭空写时间戳就是伪造证据),logs/ 一律不碰。
//
// `prune` 的铁律(04 票):**永不删 running / pending**,哪怕调用方点名要删;被跳过的必须如实报出来
//   —— 那恰恰是用户点了「清理」却发现磁盘没瘦下来时最需要的解释。

import Foundation
import Darwin
import AAContracts
import AAAgentCore
import AAAgentSystem

// ============ 共用 ============

/// 组装一套生产端口 + 工作区(四个管理子命令的共同开场)。
func makeWorkspace(_ o: AgentCLIOptions) -> (AgentTaskWorkspace, SystemFileSystem, SystemProcessLiveness) {
    let fs = SystemFileSystem()
    let workspace = AgentTaskWorkspace(root: o.root, fs: fs, clock: SystemClock())
    return (workspace, fs, SystemProcessLiveness())
}

/// 读操作顺手做的崩溃残留扫描。失败**只警告不中止**:扫描是顺手做的维护,不该让一次只读查询失败。
func sweepOrphans(_ workspace: AgentTaskWorkspace, _ liveness: SystemProcessLiveness) {
    do {
        let marked = try workspace.scanForOrphans(liveness: liveness)
        if !marked.isEmpty {
            errPrint("残留扫描:\(marked.count) 个任务的进程已不在,标为 orphaned(证据一律保留):\(marked.joined(separator: " "))")
        }
    } catch {
        errPrint("警告:残留扫描失败(\(error));列出的状态可能偏旧。")
    }
}

/// 取唯一的位置参数 `<task-id>`;个数不对即用法错。
func requireTaskID(_ o: AgentCLIOptions, command: String) -> String {
    guard o.positional.count == 1 else {
        failUsage("用法:aa-agent \(command) <task-id>(得到 \(o.positional.count) 个位置参数)")
    }
    return o.positional[0]
}

/// 目录占用字节数(递归)。取不到大小的条目按 0 计 —— 磁盘占用是给用户的**清理信号**,
/// 不是会计报表;为一个读不出属性的文件把整条 `list` 打挂是本末倒置。
func directorySize(_ path: String) -> Int64 {
    let url = URL(fileURLWithPath: path)
    guard let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
    ) else { return 0 }
    var total: Int64 = 0
    for case let item as URL in enumerator {
        let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == true, let size = values?.fileSize { total += Int64(size) }
    }
    return total
}

/// 人读的字节数(给用户看「要不要清」,不需要精确到字节)。
func humanBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
    return index == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[index])
}

// ============ status ============

func doStatus(_ o: AgentCLIOptions) -> Never {
    let taskID = requireTaskID(o, command: "status")
    let (workspace, _, liveness) = makeWorkspace(o)
    sweepOrphans(workspace, liveness)

    do {
        let meta = try workspace.readMeta(taskID: taskID)
        if o.json {
            emitJSON(meta, pretty: true)
        } else {
            outPrint("task-id:    \(meta.taskID)")
            outPrint("state:      \(meta.state.rawValue)")
            outPrint("agent:      \(meta.agent)\(meta.model.map { "(model=\($0))" } ?? "")")
            outPrint("workdir:    \(meta.workdir)")
            outPrint("initiator:  \(meta.initiator)")
            outPrint("created:    \(meta.createdAt)")
            if let started = meta.startedAt   { outPrint("started:    \(started)") }
            if let finished = meta.finishedAt { outPrint("finished:   \(finished)") }
            if let pid = meta.pid             { outPrint("pid:        \(pid)") }
            if let code = meta.exitCode       { outPrint("exit-code:  \(code)") }
            if let session = meta.sessionID   { outPrint("session-id: \(session)") }
            if let error = meta.error         { outPrint("error:      \(error)") }
            outPrint("report:     \(workspace.reportPath(for: taskID))")
        }
        exit(AAExitCode.success)
    } catch AgentTaskWorkspaceError.invalidTaskID(let bad) {
        // 路径穿越拦在域逻辑里(04):`../../etc/passwd` 这类 id 在**读盘之前**就被拒。
        failUsage("非法 task-id:\(bad)(不得为空 / 含 `/` / 含 `..` / 以 `.` 开头)")
    } catch {
        // 分两档如实报:任务不存在是用户敲错了(1);meta 解不出是数据/协议问题(6)。
        if !FileManager.default.fileExists(atPath: workspace.metaPath(for: taskID)) {
            failUsage("未知任务:\(taskID)(在 \(o.root) 下找不到它的 meta.json;用 `aa-agent list` 看有哪些)")
        }
        errPrint("meta.json 读不出来(\(taskID)):\(error)")
        errPrint("证据仍在 \(workspace.directory(for: taskID)),本命令绝不删改它。")
        exit(AAExitCode.protocolError)
    }
}

// ============ cancel ============

func doCancel(_ o: AgentCLIOptions) -> Never {
    let taskID = requireTaskID(o, command: "cancel")
    let (workspace, _, liveness) = makeWorkspace(o)

    let meta: AgentTaskMeta
    do {
        meta = try workspace.readMeta(taskID: taskID)
    } catch AgentTaskWorkspaceError.invalidTaskID(let bad) {
        failUsage("非法 task-id:\(bad)(不得为空 / 含 `/` / 含 `..` / 以 `.` 开头)")
    } catch {
        failUsage("读不到任务 \(taskID) 的 meta.json(\(error))")
    }

    if meta.state.isTerminal {
        // 对已终结的任务发取消是调用方状态没理清 —— 让它响,而不是静默变成一次真杀
        //(05 票 `AgentCancellation` 的同款姿态)。
        failUsage("任务 \(taskID) 已是终态 \(meta.state.rawValue),没有可取消的进程。")
    }

    if meta.state == .pending {
        // 还没拉起:没有进程、没有句柄,直接落终态即可(`pending → cancelled` 是合法迁移)。
        do {
            try workspace.finish(taskID: taskID, state: .cancelled, exitCode: nil, finalText: nil,
                                 error: "用户取消(任务尚未拉起,没有进程被终止)")
            outPrint("任务 \(taskID) 已取消(此前尚未拉起)。")
            exit(AAExitCode.success)
        } catch {
            errPrint("写取消终态失败:\(error)")
            exit(AAExitCode.protocolError)
        }
    }

    // state == running:进程在别的进程里(run 那一个)被拉起,我们手里没有句柄,只有 meta.pid。
    guard let pid = meta.pid, pid > 0 else {
        failUsage("任务 \(taskID) 状态是 running 但 meta 里没有 pid,无法定位进程。"
                  + "(没有判据就不猜;若它其实已经死了,`aa-agent list` 的残留扫描会把它标成 orphaned)")
    }
    guard liveness.isAlive(pid: pid) else {
        // 进程已经不在了 —— 这正是崩溃残留的形状。按 04 的语义标 `orphaned`(**只**改 state,不填 finished_at:
        // 我们并不知道它是何时死的,凭空写一个时间戳就是伪造证据),而不是凭空判一个 cancelled。
        do {
            try workspace.updateMeta(taskID: taskID) { $0.state = .orphaned }
            outPrint("任务 \(taskID) 的进程(pid=\(pid))已不在,标为 orphaned(证据全部保留)。")
            exit(AAExitCode.success)
        } catch {
            errPrint("标记 orphaned 失败:\(error)")
            exit(AAExitCode.protocolError)
        }
    }

    // 发终止意图。**能按进程组发就按组发**(连带杀 agent 派生的子进程树,反孤儿铁律);
    // 但只有在核验过 `getpgid(pid) == pid`(即该 pid 确实是组长,与 SystemAgentPort 的 SETPGROUP 一致)时才这么做。
    // 核验不过就降级只杀这一个 pid —— **绝不**把信号发给一个可能属于别人(甚至属于我们自己 shell)的进程组。
    // 这是本文件最不能错的一步:`kill(-pgid, …)` 打错组的后果是杀掉无关进程。
    let pgid = getpgid(pid)
    if pgid == pid {
        _ = kill(-pid, SIGTERM)
        outPrint("已向任务 \(taskID) 的进程组(pgid=\(pid))发出 SIGTERM。")
    } else {
        _ = kill(pid, SIGTERM)
        errPrint("提示:pid=\(pid) 不是进程组组长(pgid=\(pgid)),已降级为只终止该进程;"
                 + "它派生的子进程可能需要手工清理。")
        outPrint("已向任务 \(taskID) 的进程(pid=\(pid))发出 SIGTERM。")
    }
    // **刻意不在这里写终态**:终态归正在 drain 的那个 run 进程一次写定(接线纪律 1)。
    // Claude 会先补 `[Request interrupted by user]` 再落 `aborted_streaming` 终态才退出(01 spike);
    // Codex 流里根本没有终态行,由退出码 -15 收敛成 cancelled(02 spike)。两条路都由 run 进程如实收口。
    errPrint("终态由 run 进程 drain 完后一次写定;稍后用 `aa-agent status \(taskID)` 查看。")
    errPrint("(若那个 run 进程已经不在,下一次 `aa-agent list` 的残留扫描会把它标成 orphaned)")
    exit(AAExitCode.success)
}

// ============ list ============

/// `list --json` 的一行。
struct AgentTaskListRow: Encodable {
    let taskID: String
    let state: String
    let agent: String?
    let createdAt: String?
    let bytes: Int64

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case state
        case agent
        case createdAt = "created_at"
        case bytes
    }
}

func doList(_ o: AgentCLIOptions) -> Never {
    guard o.positional.isEmpty else { failUsage("list 不接受位置参数,多余的:\(o.positional.joined(separator: " "))") }
    let (workspace, _, liveness) = makeWorkspace(o)
    sweepOrphans(workspace, liveness)

    let ids: [String]
    do {
        ids = try workspace.list()
    } catch {
        errPrint("列举任务失败(\(o.root)):\(error)")
        exit(AAExitCode.protocolError)
    }

    var rows: [AgentTaskListRow] = []
    var total: Int64 = 0
    for id in ids {
        let bytes = directorySize(workspace.directory(for: id))
        total += bytes
        // ← 纪律 1:**逐条降级**。一个未来版本写下的未知 state 值会让 readMeta 抛错,
        //   但那绝不该让整条 list 挂掉 —— 那个任务如实显示「meta 不可读」,其余照常列出。
        if let meta = try? workspace.readMeta(taskID: id) {
            rows.append(AgentTaskListRow(taskID: id, state: meta.state.rawValue, agent: meta.agent,
                                         createdAt: meta.createdAt, bytes: bytes))
        } else {
            rows.append(AgentTaskListRow(taskID: id, state: "(meta 不可读)", agent: nil,
                                         createdAt: nil, bytes: bytes))
        }
    }

    if o.json {
        struct Payload: Encodable {
            let root: String
            let count: Int
            let bytes: Int64
            let tasks: [AgentTaskListRow]
        }
        emitJSON(Payload(root: o.root, count: rows.count, bytes: total, tasks: rows), pretty: true)
    } else {
        for row in rows {
            outPrint("\(row.taskID)  [\(row.state)]  \(row.agent ?? "?")  \(humanBytes(row.bytes))")
        }
        // 条数 + 磁盘占用:提案 §4 要的「给用户清理信号」。
        outPrint("任务数: \(rows.count)  磁盘占用: \(humanBytes(total))  根目录: \(o.root)")
        if rows.isEmpty { outPrint("(没有任务;`aa-agent run --agent claude --prompt \"…\"` 可以委托一个)") }
    }
    exit(AAExitCode.success)
}

// ============ prune ============

func doPrune(_ o: AgentCLIOptions) -> Never {
    guard o.positional.isEmpty else { failUsage("prune 不接受位置参数,多余的:\(o.positional.joined(separator: " "))") }
    // **必须显式给一条规则**:裸 `prune` 就把全部终态任务删光,是一个太容易手滑的默认。
    guard o.olderThanDays != nil || o.keep != nil else {
        failUsage("prune 需要至少一条规则:--older-than <天> 或 --keep <条>(裸 prune 会删掉全部终态任务,故不提供)")
    }
    if let days = o.olderThanDays, days < 0 { failUsage("--older-than 需要非负整数") }
    if let keep = o.keep, keep < 0 { failUsage("--keep 需要非负整数") }

    let (workspace, _, liveness) = makeWorkspace(o)
    sweepOrphans(workspace, liveness)

    let ids: [String]
    do { ids = try workspace.list() } catch {
        errPrint("列举任务失败(\(o.root)):\(error)")
        exit(AAExitCode.protocolError)
    }

    // 两条规则各自算出「要保留的」,取**并集** —— 保留是保守方向,两条规则里任一条说留就留。
    var keepIDs = Set<String>()
    if let keep = o.keep {
        // task-id 以 `YYYYMMDD-HHmm` 打头,`list()` 已排序 → 末尾 N 个就是最新的 N 个。
        keepIDs.formUnion(ids.suffix(keep))
    }
    if let days = o.olderThanDays {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        for id in ids {
            guard let meta = try? workspace.readMeta(taskID: id) else {
                keepIDs.insert(id)          // meta 读不出 → 保留(fail-closed:看不懂就不动它)
                continue
            }
            let stamp = meta.finishedAt ?? meta.createdAt
            guard let date = iso.date(from: stamp) else {
                keepIDs.insert(id)          // 时间戳解不出 → 同样保留,不靠猜删东西
                continue
            }
            if date > cutoff { keepIDs.insert(id) }
        }
    }

    let result: AgentTaskPruneResult
    do { result = try workspace.prune(keepIDs: keepIDs) } catch {
        errPrint("清理失败:\(error)")
        exit(AAExitCode.protocolError)
    }

    if o.json {
        struct Payload: Encodable {
            let removed: [String]
            let skipped: [String]
            let kept: [String]
        }
        emitJSON(Payload(removed: result.removed, skipped: result.skipped, kept: keepIDs.sorted()), pretty: true)
    } else {
        outPrint("已删除 \(result.removed.count) 个终态任务目录。")
        for id in result.removed { outPrint("  删除: \(id)") }
        // 「没删哪些」必须如实报出:跳过的多半是 running/pending(铁律 3)或 meta 读不出的可疑目录。
        if !result.skipped.isEmpty {
            outPrint("跳过 \(result.skipped.count) 个(running/pending 永不删;meta 读不出的不销毁证据):")
            for id in result.skipped { outPrint("  跳过: \(id)") }
        }
        outPrint("保留 \(keepIDs.count) 个(按 --keep / --older-than 规则)。")
    }
    exit(AAExitCode.success)
}
