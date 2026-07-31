// aa-agent —— `run` 子命令:把前六票拼成端到端的一刀。
//   建工作区(04)→ 组装启动参数(07)→ SystemAgentPort 拉起(06)→ 逐行读流 → 原样落 raw.ndjson +
//   归一化落 normalized.ndjson(02/03)→ 喂看门狗(05)→ 终态收敛(05)→ 一次 finish + report.html(04)。
//
// ============ 三条接线纪律(04/05/06 票 CR 回填,写错就会在盘上留下自相矛盾的现场)============
// 1. **中断时 meta 必须保持 `running`,drain 完了才一次 `finish`**。
//    若在发信号那一刻就把 meta 落成 `timeout`/`cancelled`,04 的终态冻结会让随后「drain 回读到 succeeded」的
//    `finish(.completed)` 抛 `illegalTransition` —— 05 那条「agent 恰好在信号落地前正常完成就报 completed」的
//    豁免在盘上**永远兑现不了**。故 `AgentCancellation.timeOut` 只用来迁**内存里**那份状态 + 发终止意图
//    (它的注释也写明「只保证值序,盘序是调用方的义务」),meta 一直留在 `running`,
//    收尾时用 `AgentInterruptPolicy.resolveIncludingTimeout` 算出终态、**一次** `finish`。
//    代价是「发信号后到 finish 之间宿主崩掉」会留下一个 `running`,那由 04 的孤儿扫描 + `orphaned → 证据终态`
//    的单向纠正边兜住 —— 这一侧的残留是可修的,而终态冻结那一侧的自相矛盾是不可修的。
// 2. **`timedOut` 旗标的语义是「`timeOut()` 真的执行过」,不是「verdict 曾判过 stalled」**。
//    拿「当下 verdict」当 timedOut,会把「用户取消后 drain 较慢」的场景误记成 timeout。
// 3. **句柄生命周期顺序不可乱**:`drain 到 EOF` → `terminate`(**即使进程已自然退出也必须调**,它是唯一的
//    waitpid 收尸处)→ 取 `exitCode` → `reclaim`。先 reclaim 后 terminate 会把僵尸永久漏掉。
//
// ============ 为什么读流与看门狗必须是两个执行流 ============
// `nextEvent` 是**阻塞**语义(「进程活着但暂无输出」必须阻塞,否则 05 的看门狗会把「暂无输出」误读成流终止)。
//   于是读流线程一旦阻塞,谁也没法在同一个执行流里定时问「静默多久了」。故:
//   * **读流线程**:只读、只落盘、只更新共享状态(它是唯一的 log 写者);
//   * **主线程(监工)**:定时问看门狗、必要时发终止意图、**独占 meta 的写入**(单写者,不与读流抢)。
//   `drainToEOF` 在「降级按 pid 单杀」或「子进程 setsid 逃出进程组」时可能永远等不到 EOF,
//   故监工手里还有一道 `--drain-timeout` 上界:超了就如实记一笔并放弃等待,绝不让 run 进程永远收不了尾。

import Foundation
import Darwin
import AAContracts
import AAAgentCore
import AAAgentSystem

// ============ 读流线程与监工线程之间的共享状态 ============

/// 读流线程与监工线程共享的一小块状态(全部经一把锁串行化)。
///
/// 刻意做成 class + 锁而不是把变量捕获进闭包:看门狗是 `mutating` 的值类型,两条线程各持一份副本
///   就等于两个互不知情的看门狗 —— 读流那份收着消息、监工那份永远静默,判决必然错。
final class AgentRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var watchdog: AgentWatchdog
    private var terminalStatus: AgentTerminalStatus?
    private var pendingSessionID: String?
    private var readerDone = false
    private var rawLines = 0
    private var normalizedMessages = 0
    private var writeFailures = 0

    init(policy: AgentWatchdogPolicy, startedAt: Int) {
        watchdog = AgentWatchdog(policy: policy, startedAt: startedAt)
    }

    /// 观察一条归一化消息(刷新活动时刻 + 维护在途工具集合)。
    func observe(_ message: AgentMessage, at epochSeconds: Int) {
        lock.lock(); defer { lock.unlock() }
        watchdog.observe(message, at: epochSeconds)
        normalizedMessages += 1
    }

    /// 一条**原始行**到达也算活动 —— 哪怕它归一化后产出 0 条消息(空行 / 未知形状)。
    ///
    /// 用一条合成的 `.status` 喂看门狗:`.status` 型只刷新活动时刻、不碰在途工具集合,
    ///   语义正好是「还有动静」。这条消息只活在内存里,不落盘(落盘的只有 agent 真说过的话)。
    func noteRawLine(at epochSeconds: Int) {
        lock.lock(); defer { lock.unlock() }
        rawLines += 1
        watchdog.observe(.status("raw-line"), at: epochSeconds)
    }

    /// 记下 session/thread id,等监工线程落盘(**meta 只有监工能写**,单写者)。
    func noteSessionID(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if pendingSessionID == nil { pendingSessionID = id }
    }

    /// 取走待落盘的 session id(取走即清空,避免重复写 meta)。
    func takePendingSessionID() -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = pendingSessionID
        pendingSessionID = nil
        return value
    }

    /// 记下 adapter 交回的终态。**后到的覆盖先到的**:一条流里正常只会有一个终态行,
    ///   真出现两个时以最后那个为准(它更接近进程的真实结局)。
    func noteTerminal(_ status: AgentTerminalStatus) {
        lock.lock(); defer { lock.unlock() }
        terminalStatus = status
    }

    func noteWriteFailure() {
        lock.lock(); defer { lock.unlock() }
        writeFailures += 1
    }

    func markReaderDone() {
        lock.lock(); defer { lock.unlock() }
        readerDone = true
    }

    var isReaderDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return readerDone
    }

    var terminal: AgentTerminalStatus? {
        lock.lock(); defer { lock.unlock() }
        return terminalStatus
    }

    func verdict(at epochSeconds: Int) -> AgentWatchdogVerdict {
        lock.lock(); defer { lock.unlock() }
        return watchdog.verdict(at: epochSeconds)
    }

    /// 当前生效的静默上限(诊断用:写进 meta.error 时要说清是哪一档判的)。
    var currentTimeoutSeconds: Int {
        lock.lock(); defer { lock.unlock() }
        return watchdog.currentTimeoutSeconds
    }

    var counters: (raw: Int, normalized: Int, failures: Int) {
        lock.lock(); defer { lock.unlock() }
        return (rawLines, normalizedMessages, writeFailures)
    }
}

// ============ run ============

/// `run` 的机读结果(`--json`)。
struct AgentRunResult: Encodable {
    let taskID: String
    let state: String
    let agent: String
    let exitCode: Int32?
    let report: String
    let workspace: String
    let rawLines: Int
    let messages: Int

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case state
        case agent
        case exitCode = "exit_code"
        case report
        case workspace
        case rawLines = "raw_lines"
        case messages
    }
}

/// `run --dry-run` 的机读结果(**没有任何副作用**:不建工作区、不拉进程、不碰 CODEX_HOME)。
struct AgentDryRunResult: Encodable {
    let agent: String
    let executable: String
    let arguments: [String]
    let commandLine: String
    let environment: [String: String]
    let workingDirectory: String
    let stdinMode: String
    let stdinPayload: String?
    let taskID: String
    let note: String

    enum CodingKeys: String, CodingKey {
        case agent, executable, arguments, environment, note
        case commandLine = "command_line"
        case workingDirectory = "working_directory"
        case stdinMode = "stdin_mode"
        case stdinPayload = "stdin_payload"
        case taskID = "task_id"
    }
}

func doRun(_ o: AgentCLIOptions) -> Never {
    guard let vendor = o.agent else { failUsage("run 需要 --agent <\(AgentVendor.allCases.map(\.rawValue).joined(separator: "|"))>") }
    guard let prompt = o.prompt, !prompt.isEmpty else { failUsage("run 需要 --prompt <文本>(不能为空)") }
    guard o.positional.isEmpty else { failUsage("run 不接受位置参数,多余的:\(o.positional.joined(separator: " "))") }
    let executable = resolveExecutable(vendor: vendor, override: o.execPath)

    let fs = SystemFileSystem()
    let clock = SystemClock()
    let workspace = AgentTaskWorkspace(root: o.root, fs: fs, clock: clock)

    let now = clock.now()
    let taskID = AgentTaskID.make(stamp: now.stamp, prompt: prompt, suffix: randomTaskSuffix())
    let taskDirectory = workspace.directory(for: taskID)
    // Codex 的每任务私有 CODEX_HOME 放在任务目录内:随任务一起被 prune 清掉,不在别处留孤儿目录。
    let taskCodexHome = taskDirectory + "/codex-home"

    // ---- dry-run:只组装、只打印。门禁靠这一支验「CLI 与组装器确实接上了」,零进程零配额 ----
    if o.dryRun {
        let spec = AgentLaunchAssembler.assemble(makeDelegation(
            o: o, vendor: vendor, prompt: prompt, executable: executable,
            workingDirectory: o.workdir ?? (taskDirectory + "/work"), codexHome: taskCodexHome
        ))
        emitDryRun(spec: spec, vendor: vendor, taskID: taskID, json: o.json)
    }

    // ---- ① 建工作区(04):meta.json(pending) + prompt.md + 三个空日志文件 ----
    let snapshot: [String: String] = [
        "agent": vendor.rawValue,
        "model": o.model ?? "(agent 默认)",
        "executable": executable,
        "sandbox": vendor == .codex ? o.sandbox.rawValue : "(不适用:Claude 侧 bypass 无文件系统隔离)",
        "idle-timeout-seconds": String(o.idleTimeout),
        "tool-timeout-seconds": String(o.toolTimeout),
        "drain-timeout-seconds": String(o.drainTimeout),
        "allowed-tools": o.allowedTools.isEmpty
            ? (vendor == .claude ? AgentLaunchAssembler.claudeDefaultAllowedTools.joined(separator: ",") : "(不适用)")
            : o.allowedTools.joined(separator: ","),
    ]
    let meta: AgentTaskMeta
    do {
        meta = try workspace.create(
            taskID: taskID, prompt: prompt, promptSnapshot: snapshot,
            agent: vendor.rawValue, model: o.model, workdir: o.workdir, initiator: o.initiator
        )
    } catch {
        errPrint("建任务工作区失败(\(o.root)):\(error)")
        exit(AAExitCode.protocolError)
    }
    errPrint("任务已建立:\(taskID)")
    errPrint("工作区:\(taskDirectory)")

    // ---- ② Codex:每任务独立 CODEX_HOME(只拷 auth.json,绝不拷 config.toml)----
    if vendor == .codex {
        do {
            try AgentCodexHome.prepare(from: o.codexHomeSource, to: taskCodexHome, fs: fs)
        } catch AgentCodexHomeError.authFileMissing(let path) {
            // 目标目录此刻已建好且为空 —— 照常跑。02 spike 实证:没有 auth 就是 401 fail-closed,
            // **不会**静默回退到用户的真实身份,故这是安全的一档,只需如实告知。
            errPrint("提示:\(path) 不存在,本任务将以无鉴权的空 CODEX_HOME 运行(实证行为:401 fail-closed,不会误用你的真身份)。")
        } catch {
            errPrint("准备任务私有 CODEX_HOME 失败:\(error)")
            try? workspace.finish(taskID: taskID, state: .failed, exitCode: nil, finalText: nil,
                                  error: "准备任务私有 CODEX_HOME 失败:\(error)")
            exit(AAExitCode.protocolError)
        }
    }

    // ---- ③ 组装 + 拉起(06)----
    let spec = AgentLaunchAssembler.assemble(makeDelegation(
        o: o, vendor: vendor, prompt: prompt, executable: executable,
        workingDirectory: meta.workdir, codexHome: taskCodexHome
    ))
    let port = SystemAgentPort()
    let handle: AgentProcessHandle
    do {
        handle = try port.launch(spec)
    } catch {
        errPrint("拉起 agent 失败:\(error)")
        // 拉起就失败也要收尾:pending → failed 是合法迁移,任务不该停在 pending 让人猜。
        try? workspace.finish(taskID: taskID, state: .failed, exitCode: nil, finalText: nil,
                              error: "拉起失败:\(error)")
        cleanupCodexHome(vendor: vendor, path: taskCodexHome, fs: fs)
        exit(AAExitCode.hostUnreachable)
    }

    // 先落盘 running + pid,**再**开始读流:崩溃残留扫描的唯一判据就是 meta.pid
    // (宿主重启后句柄早没了,磁盘上只剩这个数字)。这两步反过来会留下一段「进程已在跑但盘上没 pid」的窗口。
    let started = clock.now()
    do {
        try workspace.updateMeta(taskID: taskID) { m in
            m.state = .running
            m.startedAt = started.iso8601
            m.pid = port.processIdentifier(handle)
        }
    } catch {
        // 写 running 失败有两种成因,后果天差地别,必须分开处置:
        // (a) **另一条路径已经把任务写成终态了** —— 现实中就是 `aa-agent cancel` 在我们 launch 与这次
        //     updateMeta 之间的窄窗口里,对还是 `pending` 的任务落了 `cancelled`(它那条路不需要 pid)。
        //     此时若「照常执行」,盘上写着 cancelled、进程却一路跑到底,配额照烧 —— 与取消语义正相反。
        //     故:回读一次 meta,已是终态就**立刻收尸退出**,不给它跑起来的机会。
        // (b) 其它写盘故障(权限 / 磁盘满)—— 任务照常执行,只是崩溃残留扫描会缺少判据,如实警告即可。
        let disk = try? workspace.readMeta(taskID: taskID)
        if let disk, disk.state.isTerminal {
            errPrint("任务在拉起瞬间已被另一条路径判为 \(disk.state.rawValue),立即终止刚拉起的进程(不让它白跑烧配额)。")
            port.terminate(handle)
            port.reclaim(handle)
            cleanupCodexHome(vendor: vendor, path: taskCodexHome, fs: fs)
            exit(processExitCode(for: disk.state))
        }
        errPrint("警告:写 running 状态失败(\(error));任务照常执行,但崩溃残留扫描会缺少判据。")
    }
    errPrint("已拉起 \(vendor.rawValue)(pid=\(port.processIdentifier(handle).map { String($0) } ?? "?"));"
             + "静默阈值 \(o.idleTimeout)s / 工具在途 \(o.toolTimeout)s。")

    // ---- ④ 读流线程(唯一的 log 写者)----
    let state = AgentRunState(
        policy: AgentWatchdogPolicy(idleTimeoutSeconds: o.idleTimeout, toolInFlightTimeoutSeconds: o.toolTimeout),
        startedAt: started.epochSeconds
    )
    let reader = Thread {
        while let line = port.nextEvent(handle) {
            let at = clock.now().epochSeconds
            // raw 与 normalized **永不互写**(04 铁律 2):两条路各自独立,连共用的 append 助手都不设。
            do { try workspace.appendRaw(line, taskID: taskID) } catch { state.noteWriteFailure() }
            state.noteRawLine(at: at)

            let output = vendor == .claude
                ? ClaudeAdapter.normalize(line: line)
                : CodexAdapter.normalize(line: line)
            for message in output.messages {
                do { try workspace.appendNormalized(message, taskID: taskID) } catch { state.noteWriteFailure() }
                state.observe(message, at: at)
            }
            if let sessionID = output.sessionID { state.noteSessionID(sessionID) }
            if let terminal = output.terminal { state.noteTerminal(terminal) }
        }
        state.markReaderDone()
    }
    reader.name = "aa-agent.reader"
    reader.start()

    // ---- ⑤ 监工循环:看门狗 + session_id 落盘 + 有界 drain(meta 的唯一写者)----
    var timedOut = false              // 语义:`timeOut()` **真的执行过**(不是「verdict 曾判过 stalled」)
    var interruptIssued = false
    var stdinClosed = false           // Claude 的显式收尾只做一次(closeStdin 本身幂等,这里省掉无谓的重复调用)
    var stalledSilentSeconds = 0
    var stalledToolInFlight = false
    var stalledBudget = 0
    var drainDeadline: Int? = nil
    var drainAbandoned = false

    while !state.isReaderDone {
        usleep(200_000)   // 200ms:对 120s 起步的阈值足够细,又不会把 CPU 空转起来
        let tick = clock.now()

        // session_id 拿到即落盘(提案 §3:为将来 resume 留门)。写者只有监工这一条线。
        if let sessionID = state.takePendingSessionID() {
            do { try workspace.updateMeta(taskID: taskID) { $0.sessionID = sessionID } }
            catch { errPrint("警告:写 session_id 失败(\(error))") }
        }

        // Claude 的**显式收尾** —— `.writeThenKeepOpen` 承诺的另一半,拿到终态行就关掉 stdin 写端。
        //
        // 不关会怎样(01 spike 样本 06 `06-stdin-keepopen.meta.txt` 就是这条路的实证:`natural_exit: no`、
        //   `waited_secs: 45` 后进程仍活着、最后 `exit_code: 143` 靠 SIGTERM 才收的尾):
        //   result 行落地后 claude **不会自退**,读流线程一直阻塞在 read 上,于是一次**正常完成**的委托
        //   要空转满一个静默阈值(默认 120 秒)才被自家看门狗判「卡死」、挨一刀 SIGTERM 才收得了尾。
        //   终态碰巧还是 completed(05 的 succeeded 豁免优先于 timedOut),所以门禁与冒烟的断言全都照样绿 ——
        //   这正是它危险的地方:盘上会留下 `state=completed` 配 `exit_code=143` 配一行「看门狗判定卡死」的
        //   自相矛盾现场,而那条豁免本是给罕见竞态留的,不该每一次成功都去踩它。
        //   更坏的一支:claude 若在空闲态收到 SIGTERM 后再补一条 `aborted_streaming` 终态,
        //   `noteTerminal` 的「后到覆盖先到」会把 succeeded 覆盖掉 → 一次真实成功被记成 timeout。
        //
        // Codex 侧 stdin 接的是 /dev/null,压根没有写端可关(它靠自己退出给 EOF),故这一步只对 Claude 有意义。
        if !stdinClosed, vendor == .claude, state.terminal != nil {
            stdinClosed = true
            port.closeStdin(handle)   // 幂等;terminate 也会关,但那是取消路径,不是正常收尾路径
        }

        if !interruptIssued, case let .stalled(silent, toolInFlight) = state.verdict(at: tick.epochSeconds) {
            interruptIssued = true
            timedOut = true                       // ← 只有真走到这里才置位(纪律 2)
            stalledSilentSeconds = silent
            stalledToolInFlight = toolInFlight
            stalledBudget = state.currentTimeoutSeconds
            // 只迁**内存**里的状态 + 发终止意图;meta 保持 running(纪律 1),终态等 drain 完了一次写。
            var inMemoryState = AgentTaskState.running
            let drainPolicy = (try? AgentCancellation.timeOut(
                state: &inMemoryState, handle: handle, port: port, vendor: vendor
            )) ?? AgentInterruptPolicy.drainPolicy(for: vendor)
            errPrint("看门狗判定卡死:静默 \(silent) 秒(阈值 \(stalledBudget) 秒,工具在途=\(toolInFlight ? "是" : "否"));"
                     + "已发终止意图,drain 姿态=\(drainPolicy)。")
            drainDeadline = tick.epochSeconds + o.drainTimeout
        }

        if let deadline = drainDeadline, tick.epochSeconds > deadline {
            // drain 必须有界:降级单杀 / 子进程 setsid 逃组时管道可能永远不 EOF(06 票 CR 明写)。
            drainAbandoned = true
            errPrint("警告:发出终止意图后 \(o.drainTimeout) 秒仍未读到 EOF,放弃继续 drain(可能有子进程逃出了进程组)。")
            break
        }
    }

    // 补最后一次 session_id 落盘:短任务可能在监工的第一次 200ms tick 之前就读完了整条流
    // (那时循环体一次都没进过),不补这一下就会把 thread_id / session_id 丢掉 —— 而它是将来 resume 的唯一指针。
    if let sessionID = state.takePendingSessionID() {
        do { try workspace.updateMeta(taskID: taskID) { $0.sessionID = sessionID } }
        catch { errPrint("警告:写 session_id 失败(\(error))") }
    }

    // ---- ⑥ 句柄生命周期:terminate(必调,唯一收尸处)→ exitCode → stderr → reclaim ----
    port.terminate(handle)
    let exitCode = port.exitCode(handle)
    let stderrText = port.drainedStderr(handle)
    if !stderrText.isEmpty {
        for line in stderrText.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            try? workspace.appendStderr(String(line), taskID: taskID)
        }
    }
    port.reclaim(handle)

    // 任务私有 CODEX_HOME 用完即弃:它里面躺着一份用户 auth.json 的**副本**,
    // 留在 ~/.aa/agent-tasks/ 下就是一份长期存在的凭据拷贝(而且会被 tar 走、被同步、被误分享)。
    cleanupCodexHome(vendor: vendor, path: taskCodexHome, fs: fs)

    // ---- ⑦ 终态收敛 + 一次 finish(04/05)----
    let terminal = state.terminal
    // `cancelRequested` 恒 false:本进程里没有用户取消这条路径(`aa-agent cancel` 是**另一个进程**,
    //   它只发信号)。那次取消对我们的表现形式是:Claude → drain 回读到 `aborted` 终态;
    //   Codex → 流里没有终态行 + 退出码 -15。两条都被 04 的 `resolve` 正确收敛成 `.cancelled`,
    //   不需要、也不该由本进程凭空记一笔取消账。
    let resolved = AgentInterruptPolicy.resolveIncludingTimeout(
        terminal: terminal, exitCode: exitCode, cancelRequested: false, timedOut: timedOut
    )
    let errorText = composeErrorText(
        state: resolved, terminal: terminal, exitCode: exitCode,
        timedOut: timedOut, silentSeconds: stalledSilentSeconds, toolInFlight: stalledToolInFlight,
        budget: stalledBudget, interruptIssuedByUs: interruptIssued,
        drainAbandoned: drainAbandoned, drainTimeout: o.drainTimeout,
        writeFailures: state.counters.failures
    )
    do {
        try workspace.finish(taskID: taskID, state: resolved, exitCode: exitCode,
                             finalText: terminal?.finalText, error: errorText)
    } catch AgentTaskWorkspaceError.metaFrozen(let s) {
        // 良性竞争:另一条路径(残留扫描后的纠正 / 另一个进程)已经把终态写定了。记一行,不当致命错。
        errPrint("提示:终态已由另一条路径写定为 \(s.rawValue),本次收尾按良性竞争处理。")
    } catch AgentTaskWorkspaceError.illegalTransition(let from, let to) {
        errPrint("提示:终态迁移 \(from.rawValue) → \(to.rawValue) 被拒(另一条路径先落了不同的终态),按良性竞争处理。")
    } catch {
        errPrint("收尾写盘失败:\(error)")
        exit(AAExitCode.protocolError)
    }

    // 以**磁盘上的**最终状态为准报告(万一是另一条路径赢了,如实说它赢了什么)。
    let finalState = (try? workspace.readMeta(taskID: taskID))?.state ?? resolved
    let counters = state.counters
    let reportPath = workspace.reportPath(for: taskID)

    if o.json {
        emitJSON(AgentRunResult(
            taskID: taskID, state: finalState.rawValue, agent: vendor.rawValue, exitCode: exitCode,
            report: reportPath, workspace: taskDirectory,
            rawLines: counters.raw, messages: counters.normalized
        ))
    } else {
        outPrint("任务 \(taskID) 结束:\(finalState.rawValue)"
                 + (exitCode.map { "(退出码 \($0))" } ?? "(退出码未知)"))
        outPrint("报告:\(reportPath)")
        outPrint("日志:\(workspace.rawLogPath(for: taskID)) / \(workspace.normalizedLogPath(for: taskID))")
    }
    if counters.failures > 0 {
        errPrint("警告:有 \(counters.failures) 次日志落盘失败(报告与终态照常产出,但 raw/normalized 可能不完整)。")
    }
    exit(processExitCode(for: finalState))
}

// ============ 助手 ============

/// job 终态 → 进程退出码。语义表见 `usageText()`,数字取自 `AAContracts.AAExitCode`(不散写魔数)。
func processExitCode(for state: AgentTaskState) -> Int32 {
    switch state {
    case .completed:            return AAExitCode.success            // 0
    case .timeout:              return AAExitCode.timeout            // 3
    case .failed, .cancelled:   return AAExitCode.capabilityFailure  // 5:任务跑了但没成功
    case .orphaned:             return AAExitCode.capabilityFailure  // 5:同上(推测性终态,同样不算成功)
    case .pending, .running:    return AAExitCode.protocolError      // 6:收尾后还停在活态 = 我们自己的 bug
    }
}

/// 由本次运行的现场拼出 `meta.error` 的内容。
///
/// **判定面收敛,诊断面如实**(07 票面第 6 条接线契约):`state` 只有七个值,信息量极小;
///   「为什么判它卡死」「是谁发的信号」这些唯一有诊断价值的事实没有专属字段承载,
///   不显式写进 `error` 就只活在这个进程的内存里 —— 用户 `aa-agent status` 只会看到一个光秃秃的 `timeout`。
func composeErrorText(
    state: AgentTaskState,
    terminal: AgentTerminalStatus?,
    exitCode: Int32?,
    timedOut: Bool,
    silentSeconds: Int,
    toolInFlight: Bool,
    budget: Int,
    interruptIssuedByUs: Bool,
    drainAbandoned: Bool,
    drainTimeout: Int,
    writeFailures: Int
) -> String? {
    var parts: [String] = []
    if timedOut {
        // 看门狗的现场:静默多久、卡在哪一档、当时有没有工具在途 —— 这三样是判定卡死的唯一证据。
        parts.append("看门狗判定静默超时:静默 \(silentSeconds) 秒 > 阈值 \(budget) 秒;卡死时工具在途=\(toolInFlight ? "是" : "否")")
    }
    if let reason = terminal?.reason, !reason.isEmpty {
        parts.append("agent 终态理由:\(reason)")
    }
    if let code = exitCode {
        if code < 0 {
            // 负值 = 被信号杀(对 Codex 成立;Claude 是捕获 SIGTERM 后自 exit 143,不走这一支)。
            parts.append(interruptIssuedByUs
                ? "被信号 \(-code) 终止(本平台发起)"
                : "被信号 \(-code) 终止,非本平台发起(可能是 OOM / 外部 pkill / 用户在别处取消)")
        } else if code != 0 {
            parts.append("退出码 \(code)")
        }
    } else {
        parts.append("拿不到退出码(收尸未取得状态,按 fail-closed 处置)")
    }
    if drainAbandoned {
        parts.append("发出终止意图后 \(drainTimeout) 秒未读到 EOF,drain 被放弃(可能有子进程逃出进程组)")
    }
    if writeFailures > 0 {
        parts.append("有 \(writeFailures) 次日志落盘失败,raw/normalized 可能不完整")
    }
    // 成功任务不写 error(04 断言:nil error 时整键省略,meta.json 不产噪音键)。
    // 唯一的例外是上面那两条「产出可能不完整」的旁注 —— 它们即便在 completed 上也必须留痕。
    if state == .completed {
        let notes = parts.filter { $0.hasPrefix("发出终止意图后") || $0.hasPrefix("有 ") }
        return notes.isEmpty ? nil : notes.joined(separator: ";")
    }
    return parts.isEmpty ? nil : parts.joined(separator: ";")
}

/// 把 CLI 选项折成一次委托(组装器只吃值,不去读环境、不去猜路径)。
func makeDelegation(
    o: AgentCLIOptions, vendor: AgentVendor, prompt: String,
    executable: String, workingDirectory: String, codexHome: String
) -> AgentDelegation {
    AgentDelegation(
        vendor: vendor,
        prompt: prompt,
        model: o.model,
        workingDirectory: workingDirectory,
        executablePath: executable,
        codexHome: vendor == .codex ? codexHome : nil,
        sandbox: o.sandbox,
        allowedTools: o.allowedTools.isEmpty ? nil : o.allowedTools,
        hostEnvironment: ProcessInfo.processInfo.environment,
        extraArguments: []
    )
}

/// 打印 dry-run 结果并退出(**零副作用**)。
func emitDryRun(spec: AgentLaunchSpec, vendor: AgentVendor, taskID: String, json: Bool) -> Never {
    let stdinMode: String
    var stdinPayload: String? = nil
    switch spec.stdin {
    case .devNull: stdinMode = "devNull"
    case let .writeThenKeepOpen(payload): stdinMode = "writeThenKeepOpen"; stdinPayload = payload
    }
    let commandLine = ([spec.executablePath] + spec.arguments).joined(separator: " ")
    let note = "dry-run:未建工作区、未拉起任何进程、未碰 CODEX_HOME,零配额消耗。"
    if json {
        emitJSON(AgentDryRunResult(
            agent: vendor.rawValue, executable: spec.executablePath, arguments: spec.arguments,
            commandLine: commandLine, environment: spec.environment,
            workingDirectory: spec.workingDirectory, stdinMode: stdinMode, stdinPayload: stdinPayload,
            taskID: taskID, note: note
        ))
    } else {
        outPrint("agent: \(vendor.rawValue)")
        outPrint("task-id(将会使用): \(taskID)")
        outPrint("命令行: \(commandLine)")
        outPrint("工作目录: \(spec.workingDirectory)")
        outPrint("stdin: \(stdinMode)" + (stdinPayload.map { " payload=\($0)" } ?? ""))
        outPrint("环境变量(白名单透传): \(spec.environment.keys.sorted().joined(separator: " "))")
        outPrint(note)
    }
    exit(AAExitCode.success)
}

/// 任务私有 CODEX_HOME 的清理(只对 Codex 有意义;失败只警告 —— 收尾不该被清理失败掀翻)。
func cleanupCodexHome(vendor: AgentVendor, path: String, fs: AgentFileSystemPort) {
    guard vendor == .codex else { return }
    do { try AgentCodexHome.discard(path, fs: fs) }
    catch { errPrint("警告:清理任务私有 CODEX_HOME 失败(\(path)):\(error);里面有一份 auth.json 副本,请手工删除。") }
}

/// task-id 的随机尾(hex4)。刻意由调用方生成:`AgentTaskID` 是纯函数,不引入随机数端口。
func randomTaskSuffix() -> String {
    String(format: "%04x", UInt32.random(in: 0...0xFFFF))
}

/// 找到 agent 可执行文件。优先级:`--exec` > 专用环境变量 > PATH 搜索 > 已知安装位置。
///
/// 全程**只做文件存在性与可执行位检查,绝不拉起进程**(连 `--version` 都不跑)。
/// 两种失败分开报:`--exec` 指错是**用法错**(退出码 1,用户能立刻改);自动查找失败是**环境问题**
///   (退出码 4「不可达」,与 `aa` 里「宿主未运行」同一档语义)。
func resolveExecutable(vendor: AgentVendor, override: String?) -> String {
    let fm = FileManager.default
    // **一律折成绝对路径**(CR 补:相对路径会在最难查的地方炸)。
    //   `SystemAgentPort.launch` 是**先 chdir 到任务工作目录、再 exec**;一个相对的可执行路径在那一刻
    //   解析的是「任务目录下的相对路径」,于是这里 `isExecutableFile` 校验通过、真拉起时 ENOENT ——
    //   报错点离病因十万八千里(用户看到的是「拉起 agent 失败 errno=2」,而他明明刚验过那个文件存在)。
    //   在入口就地绝对化,校验与执行看到的才是同一个文件。
    //   顺带**标准化**(`standardizedFileURL` 折掉 `./` 与 `..`):裸拼会得到 `<cwd>/./Scripts/x`,
    //   能跑,但它会原样落进 meta.json 的 prompt 快照与 dry-run 输出,给人对不上号的路径。
    func absolute(_ path: String) -> String {
        URL(fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL.path
    }
    if let path = override {
        let resolved = absolute(path)
        guard fm.isExecutableFile(atPath: resolved) else {
            failUsage("--exec 指向的文件不存在或不可执行:\(path)")
        }
        return resolved
    }
    let envKey = vendor == .claude ? "AA_AGENT_CLAUDE_BIN" : "AA_AGENT_CODEX_BIN"
    if let fromEnv = ProcessInfo.processInfo.environment[envKey], fm.isExecutableFile(atPath: absolute(fromEnv)) {
        return absolute(fromEnv)
    }
    let name = vendor.rawValue
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = String(dir) + "/" + name
        if fm.isExecutableFile(atPath: candidate) { return candidate }
    }
    // 已知安装位置兜底:Claude 在 /usr/local/bin;本机的 Codex 是 ChatGPT 桌面 App 内置的插件版,
    // **不在 PATH 里**(02 spike 明写「不在 PATH,全路径调用」),故必须有这一条。
    let home = fm.homeDirectoryForCurrentUser.path
    let fallbacks = vendor == .claude
        ? ["/usr/local/bin/claude", home + "/.local/bin/claude"]
        : [home + "/.codex/plugins/.plugin-appserver/codex", "/usr/local/bin/codex", home + "/.local/bin/codex"]
    for candidate in fallbacks where fm.isExecutableFile(atPath: candidate) { return candidate }

    errPrint("找不到 \(name) 可执行文件(试过 $\(envKey)、PATH、以及 \(fallbacks.joined(separator: " / ")))。")
    errPrint("用 --exec <绝对路径> 显式指定。")
    exit(AAExitCode.hostUnreachable)
}
