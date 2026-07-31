// AAAgentTestKit —— 任务状态机 + 工作区落盘的纯逻辑测试(agent-delegation 04)。
// 依赖边:AAAgentTestKit → AAAgentCore、AAContracts(+ 系统 Foundation)。
//
// **全票零副作用**:所有断言跑在 `FakeFileSystem` / `FakeClock` / `FakeLiveness` 上 ——
//   零真实文件系统(根目录用 `/fake/agent-tasks`,内存里的路径串而已,不碰磁盘)、零真实时钟、零真实进程。
//   本套件里任何一处真去 `~/.aa/` 或真读系统时间的写法都是 bug。
//
// 覆盖的十件事(与 03 票《任务工作区结构提案》逐条对齐):
//   ① 状态迁移合法/非法逐条;② adapter 终态 → job 状态的映射(含 terminal 缺失时按退出码收敛);
//   ③ task-id 生成(slug 规则含中文回退)与 **task-id 形状校验**(路径穿越);④ 建工作区的目录结构与 meta 字段;
//   ⑤ **raw 与 normalized 永不互写**;⑥ session_id 拿到即写 + task_id/schema_version 不可变;
//   ⑦ 崩溃残留标 orphaned 且**不销毁证据**,以及**孤儿可被一手证据纠正** + `finish` 同态幂等/报告自愈/error 一次写盘;
//   ⑧ HTML 报告(agent 自产不覆盖 / 兜底生成 / escape 顺序 / **finalText 缺失时退回 normalized 最后一条 text**);
//   ⑨ prune 永不删 running·pending;⑩ 读侧容忍未知字段**且写侧原样写回**。
//   外加 turn 边界不当闸门(03 票 CR 回填的实测约束)与写入失败的错误传播。
//
// 说明:本套件由 check.sh 动态生成的 runner 执行,打印 report.lines;各描述串是 check.sh 阶段 B
//   assert_contains 的定长子串目标,**不得随意改字**(改则同步改 check.sh 断言组 1f)。

import Foundation
import AAContracts
import AAAgentCore

/// 任务状态机 + 工作区落盘的纯逻辑测试。
public enum AgentTaskTests {
    /// 假工作区根 —— 纯内存路径串,不存在于任何磁盘上。
    private static let root = "/fake/agent-tasks"

    public static func run() -> AgentTestReport {
        var report = AgentTestReport()
        testStateMachine(&report)
        testTerminalMapping(&report)
        testTaskID(&report)
        testTaskIDShapeIsValidated(&report)
        testCreateWorkspace(&report)
        testRawNeverMixesWithNormalized(&report)
        testTurnBoundaryIsNotAGate(&report)
        testSessionIDWrittenImmediately(&report)
        testImmutableMetaFields(&report)
        testIllegalTransitionLeavesDiskUntouched(&report)
        testOrphanScanKeepsEvidence(&report)
        testOrphanRaceIsCorrectableByFinish(&report)
        testFinishIsIdempotentAndSelfHeals(&report)
        testFinishWritesErrorInOneShot(&report)
        testFinalTextFallsBackToLastNormalizedText(&report)
        testReportFallback(&report)
        testPruneNeverDeletesLiveTasks(&report)
        testUnknownFieldTolerance(&report)
        return report
    }

    // MARK: - 助手

    private static func makeClock() -> FakeClock {
        FakeClock([
            AgentWallClock(stamp: "20260729-1432", iso8601: "2026-07-29T14:32:00Z", epochSeconds: 1_785_508_320),
            AgentWallClock(stamp: "20260729-1433", iso8601: "2026-07-29T14:33:00Z", epochSeconds: 1_785_508_380),
            AgentWallClock(stamp: "20260729-1500", iso8601: "2026-07-29T15:00:00Z", epochSeconds: 1_785_510_000),
        ])
    }

    private static func makeWorkspace() -> (AgentTaskWorkspace, FakeFileSystem, FakeClock) {
        let fs = FakeFileSystem()
        let clock = makeClock()
        return (AgentTaskWorkspace(root: root, fs: fs, clock: clock), fs, clock)
    }

    /// 建一个已拉起(running + pid)的任务,供残留扫描 / prune 用。
    private static func makeRunningTask(
        _ ws: AgentTaskWorkspace, id: String, pid: Int32
    ) throws {
        try ws.create(taskID: id, prompt: "diagnose network", agent: "claude", initiator: "cli")
        try ws.updateMeta(taskID: id) { meta in
            meta.state = .running
            meta.pid = pid
            meta.startedAt = "2026-07-29T14:33:00Z"
        }
    }

    // MARK: - ① 状态迁移

    private static func testStateMachine(_ report: inout AgentTestReport) {
        let pending = AgentTaskState.pending
        report.check(pending.canTransition(to: .running)
                        && pending.canTransition(to: .failed)
                        && pending.canTransition(to: .cancelled),
                     "任务状态机:pending 迁 running/failed/cancelled 三条全合法")
        report.check(!pending.canTransition(to: .completed),
                     "任务状态机:pending 直接迁 completed 非法(没跑过就不可能完成)")
        report.check(!pending.canTransition(to: .timeout) && !pending.canTransition(to: .orphaned),
                     "任务状态机:pending 迁 timeout/orphaned 非法(还没拉起,静默与残留都无从谈起)")

        let running = AgentTaskState.running
        report.check(running.canTransition(to: .completed)
                        && running.canTransition(to: .failed)
                        && running.canTransition(to: .cancelled)
                        && running.canTransition(to: .timeout)
                        && running.canTransition(to: .orphaned),
                     "任务状态机:running 迁 completed/failed/cancelled/timeout/orphaned 五条全合法")
        report.check(!running.canTransition(to: .pending),
                     "任务状态机:running 迁回 pending 非法(时间不倒流)")

        let terminals = AgentTaskState.allCases.filter { $0.isTerminal }
        report.check(terminals.count == 5 && !terminals.contains(.pending) && !terminals.contains(.running),
                     "任务状态机:isTerminal 恰是 pending/running 之外的五个")

        // 证据终态(orphaned 之外的四个)零出边:写定即封存,含迁向自身。
        let sealed = terminals.filter { $0 != .orphaned }
        report.check(sealed.count == 4
                        && sealed.allSatisfy { from in AgentTaskState.allCases.allSatisfy { !from.canTransition(to: $0) } },
                     "任务状态机:orphaned 之外的四个终态迁向任何状态一律非法(含迁向自身)")

        // orphaned 是**猜**出来的终态(判据只有「meta 记着 running 但 pid 死了」),必须能被一手证据纠正 ——
        //   否则「run 进程还在 drain、另一个终端先扫到」这条真实时序会把一次成功的任务永久记成孤儿。
        let orphaned = AgentTaskState.orphaned
        report.check(orphaned.canTransition(to: .completed) && orphaned.canTransition(to: .failed)
                        && orphaned.canTransition(to: .cancelled) && orphaned.canTransition(to: .timeout),
                     "任务状态机:orphaned 迁 completed/failed/cancelled/timeout 四条全合法(推测性终态可被一手证据纠正)")
        report.check(!orphaned.canTransition(to: .pending) && !orphaned.canTransition(to: .running)
                        && !orphaned.canTransition(to: .orphaned),
                     "任务状态机:orphaned 不可复活成 pending/running 也不可迁向自身(纠正不是复活)")
        report.check(!AgentTaskState.completed.canTransition(to: .orphaned)
                        && !AgentTaskState.failed.canTransition(to: .orphaned)
                        && !AgentTaskState.cancelled.canTransition(to: .orphaned)
                        && !AgentTaskState.timeout.canTransition(to: .orphaned),
                     "任务状态机:四个证据终态一律不得退回 orphaned(证据升级是单向的)")
    }

    // MARK: - ② adapter 终态 → job 状态

    private static func testTerminalMapping(_ report: inout AgentTestReport) {
        report.check(AgentTaskState.from(.succeeded) == .completed,
                     "终态映射:adapter succeeded 映射为 job completed")
        report.check(AgentTaskState.from(.failed) == .failed,
                     "终态映射:adapter failed 映射为 job failed")
        report.check(AgentTaskState.from(.aborted) == .cancelled,
                     "终态映射:adapter aborted 映射为 job cancelled")

        let succeeded = AgentTerminalStatus(outcome: .succeeded, reason: "completed", finalText: "done")
        report.check(AgentTaskState.resolve(terminal: succeeded, exitCode: 1, cancelRequested: false) == .completed,
                     "终态收敛:adapter 给了终态就以它为准(退出码不翻案)")

        // 下面五条全是 Codex 的现实:中断/硬超时时事件流里根本没有终态行,adapter 诚实交回 nil。
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: -15, cancelRequested: false) == .cancelled,
                     "终态收敛:terminal 缺失且退出码为负 判 cancelled(负值即被信号杀)")
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: 0, cancelRequested: false) == .completed,
                     "终态收敛:terminal 缺失且退出码 0 判 completed")
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: 2, cancelRequested: false) == .failed,
                     "终态收敛:terminal 缺失且退出码为正 判 failed")
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: nil, cancelRequested: false) == .failed,
                     "终态收敛:terminal 与退出码都缺失 判 failed(fail-closed)")
        report.check(AgentTaskState.resolve(terminal: nil, exitCode: 0, cancelRequested: true) == .cancelled,
                     "终态收敛:terminal 缺失但收到过取消意图 判 cancelled")

        // 最要命的一条护栏:无论输入怎么组合,收敛结果必须是终态 —— 绝不存在把任务留在 running 的路径。
        var alwaysTerminal = true
        for terminal: AgentTerminalStatus? in [nil, succeeded,
                                               AgentTerminalStatus(outcome: .failed, reason: nil),
                                               AgentTerminalStatus(outcome: .aborted, reason: nil)] {
            for code: Int32? in [nil, -9, -15, 0, 1, 127] {
                for cancelled in [true, false] {
                    let state = AgentTaskState.resolve(terminal: terminal, exitCode: code, cancelRequested: cancelled)
                    if !state.isTerminal { alwaysTerminal = false }
                }
            }
        }
        report.check(alwaysTerminal,
                     "终态收敛:所有输入组合都收敛到终态,绝无把任务挂在 running 的路径")
    }

    // MARK: - ③ task-id 生成

    private static func testTaskID(_ report: inout AgentTestReport) {
        report.check(AgentTaskID.make(stamp: "20260729-1432", prompt: "Diagnose network. Then report.", suffix: "x7f3")
                        == "20260729-1432-diagnose-network-x7f3",
                     "task-id:固定 stamp 与 suffix 下整体形如 stamp-slug-suffix")
        // 时间前缀经 ClockPort 注入 —— 域逻辑一次都不读系统时钟,故 task-id 是可逐字断言的。
        let injected = AgentTaskID.make(stamp: makeClock().now().stamp, prompt: "Diagnose network", suffix: "x7f3")
        report.check(injected == "20260729-1432-diagnose-network-x7f3",
                     "task-id:时间前缀经 ClockPort 注入而非读系统时钟(故可逐字断言)")
        report.check(AgentTaskID.slug(from: "Diagnose  NETWORK__x7f3! rest") == "diagnose-network-x7f3",
                     "task-id:slug 取首句、小写、连续非字母数字折成单个连字符")

        let long = AgentTaskID.slug(from: "abcdefghij klmnopqrst uvwxyz0123456789")
        report.check(long.count == 24 && !long.hasSuffix("-"),
                     "task-id:超长 prompt 的 slug 截到 24 字符以内")
        report.check(AgentTaskID.slug(from: "abcdefghijklmnopqrstuvw xyz") == "abcdefghijklmnopqrstuvw",
                     "task-id:截断正好落在连字符上时再去一次尾部连字符")

        report.check(AgentTaskID.slug(from: "诊断一下网络为什么这么慢。谢谢") == "task",
                     "task-id:全中文 prompt 折不出字符时回退 task")
        report.check(AgentTaskID.slug(from: "") == "task",
                     "task-id:空 prompt 回退 task")
        report.check(AgentTaskID.slug(from: "  ---  ") == "task",
                     "task-id:只有分隔符的 prompt 回退 task")
        let trimmed = AgentTaskID.slug(from: "  --leading and trailing--  rest")
        report.check(!trimmed.hasPrefix("-") && !trimmed.hasSuffix("-"),
                     "task-id:slug 不带首尾连字符")
    }

    // MARK: - ③b task-id 形状校验(路径穿越)

    /// 喂一个形状非法的 id,核验 `create` 与 `readMeta` **都**以 `invalidTaskID` 拒之,且磁盘一个字节都没动。
    ///
    /// 为什么连 `readMeta` 也要查:07 票的 CLI 会把用户敲的 `<task-id>` 直接喂进读路径,
    /// `../../..` 之类的串在真 FileManager 上能读到工作区**之外**的任意文件。
    private static func refusesTaskID(_ id: String) -> Bool {
        let fs = FakeFileSystem()
        let ws = AgentTaskWorkspace(root: root, fs: fs, clock: makeClock())

        var createRefused = false
        do { _ = try ws.create(taskID: id, prompt: "p", agent: "claude", initiator: "cli") }
        catch AgentTaskWorkspaceError.invalidTaskID { createRefused = true }
        catch { }

        var readRefused = false
        do { _ = try ws.readMeta(taskID: id) }
        catch AgentTaskWorkspaceError.invalidTaskID { readRefused = true }
        catch { }   // 「文件不存在」这类错不算数:必须是形状校验先拦下的

        let untouched = fs.allFilePaths().isEmpty && fs.allDirectoryPaths().isEmpty
        return createRefused && readRefused && untouched
    }

    private static func testTaskIDShapeIsValidated(_ report: inout AgentTestReport) {
        report.check(refusesTaskID(""),
                     "task-id 校验:空串被拒且磁盘零写入(空 id 会把工作区根目录本身当成一个任务)")
        report.check(refusesTaskID("../../Users/x/.ssh"),
                     "task-id 校验:含两点的向上穿越串被拒且磁盘零写入(生产端口是真 FileManager,会越出 root 写文件)")
        report.check(refusesTaskID("sub/dir"),
                     "task-id 校验:含斜杠的 id 被拒且磁盘零写入(目录名即 task-id,只准一层扁平结构)")
        report.check(refusesTaskID(".hidden"),
                     "task-id 校验:以点开头的 id 被拒且磁盘零写入(建得出却被 list 与 ls 藏起来的任务是坏证据)")

        // 正常形状的 id 一律照收 —— 校验只拦穿越,不顺手把合法 id 也收窄掉。
        let fs = FakeFileSystem()
        let ws = AgentTaskWorkspace(root: root, fs: fs, clock: makeClock())
        var accepted = false
        do {
            _ = try ws.create(taskID: "20260729-1432-diagnose-network-x7f3",
                              prompt: "p", agent: "claude", initiator: "cli")
            accepted = true
        } catch { accepted = false }
        report.check(accepted,
                     "task-id 校验:AgentTaskID.make 产出的正常 id 照常通过(校验只拦穿越,不收窄合法字符集)")
    }

    // MARK: - ④ 建工作区(目录结构 + meta 字段)

    private static func testCreateWorkspace(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let id = "20260729-1432-diagnose-network-x7f3"
        do {
            let meta = try ws.create(
                taskID: id,
                prompt: "Diagnose network",
                promptSnapshot: ["sandbox": "workspace-write", "timeout": "600"],
                agent: "claude",
                model: nil,
                workdir: nil,
                initiator: "cli"
            )

            let entries = try fs.listDirectory(at: ws.directory(for: id))
            report.check(entries == ["logs", "meta.json", "prompt.md", "work"],
                         "工作区:create 后任务目录恰是 meta.json/prompt.md/logs/work 四项")
            let logs = try fs.listDirectory(at: ws.logsDirectory(for: id))
            report.check(logs == ["normalized.ndjson", "raw.ndjson", "stderr.log"],
                         "工作区:logs 目录恰是 raw.ndjson 与 normalized.ndjson 与 stderr.log 三件套")
            report.check(!fs.exists(at: ws.reportPath(for: id)) && !fs.exists(at: ws.changesPath(for: id)),
                         "工作区:create 时不产 report.html 与 changes.md(它们是终态产物)")

            report.check(meta.schemaVersion == 1 && meta.state == .pending,
                         "工作区:新建任务的 meta 是 schema_version 1 且 state 为 pending")
            report.check(meta.workdir == ws.defaultWorkPath(for: id),
                         "工作区:缺省 workdir 指向任务目录下的 work 子目录")

            let metaText = fs.contents(at: ws.metaPath(for: id)) ?? ""
            report.check(metaText.contains("\"schema_version\" : 1"),
                         "工作区:meta.json 落盘含 schema_version 为 1")
            report.check(metaText.contains("\"task_id\"") && metaText.contains("\"created_at\""),
                         "工作区:meta.json 键名走 snake_case(task_id 与 created_at)")
            report.check(metaText.contains("\"state\" : \"pending\""),
                         "工作区:meta.json 落盘 state 为 pending")
            report.check(!metaText.contains("model"),
                         "工作区:meta.json 的 nil 字段整键省略,不产 model 为 null 的噪音键")

            let promptText = fs.contents(at: ws.promptPath(for: id)) ?? ""
            report.check(promptText.contains("Diagnose network")
                            && promptText.contains("sandbox: workspace-write")
                            && promptText.contains("timeout: 600"),
                         "工作区:prompt.md 同时落委托原文与全部委托参数快照(可审计可重跑)")

            // 有副作用任务的变更清单:按需写,纯只读任务不调用即不产该文件(提案 §2 的「b 类任务」)。
            try ws.writeChanges("# 变更清单\n\n- 改了 Sources/a.swift:补了一处判空;回滚 git revert HEAD\n", taskID: id)
            report.check((fs.contents(at: ws.changesPath(for: id)) ?? "").contains("变更清单")
                            && fs.writeCount(at: ws.metaPath(for: id)) == 1,
                         "工作区:有副作用任务的 changes.md 经 writeChanges 落盘,且不牵动 meta.json")

            // 同名 create 绝不覆盖既有工作区(那会一次性毁掉别人的全部证据)。
            var refused = false
            do { _ = try ws.create(taskID: id, prompt: "again", agent: "claude", initiator: "cli") }
            catch { refused = true }
            report.check(refused, "工作区:同名任务再次 create 抛错,绝不覆盖既有工作区")
        } catch {
            report.check(false, "工作区:create 基本路径意外抛错 \(error)")
        }

        // 委托指定外部 workdir 时不建 work/(提案 §2)。
        let (ws2, fs2, _) = makeWorkspace()
        let id2 = "20260729-1433-external-workdir-a1b2"
        do {
            let meta = try ws2.create(taskID: id2, prompt: "build", agent: "codex",
                                      workdir: "/fake/elsewhere/repo", initiator: "gui")
            let entries = try fs2.listDirectory(at: ws2.directory(for: id2))
            report.check(entries == ["logs", "meta.json", "prompt.md"],
                         "工作区:委托指定外部 workdir 时不建 work 目录")
            report.check(meta.workdir == "/fake/elsewhere/repo" && meta.initiator == "gui",
                         "工作区:外部 workdir 与 initiator 如实落进 meta")
        } catch {
            report.check(false, "工作区:外部 workdir 路径意外抛错 \(error)")
        }

        // 半截目录:上一次「目录与日志都建好了、meta 还没写就崩了」。存在性判据若只看 meta.json,
        //   这次 create 就会静默复用并覆盖它 —— 而那半截目录的 logs/ 里可能正躺着上次崩溃的唯一线索。
        let (ws3, fs3, _) = makeWorkspace()
        let halfID = "20260729-1434-half-built-dir-c9d0"
        do {
            try fs3.createDirectory(at: ws3.logsDirectory(for: halfID))
            try fs3.append(#"{"type":"assistant","message":{"content":[]}}"#, to: ws3.rawLogPath(for: halfID))
            let evidenceBefore = fs3.contents(at: ws3.rawLogPath(for: halfID))

            var refused = false
            do { _ = try ws3.create(taskID: halfID, prompt: "again", agent: "claude", initiator: "cli") }
            catch AgentTaskWorkspaceError.taskAlreadyExists { refused = true }
            catch { }
            report.check(refused && fs3.contents(at: ws3.rawLogPath(for: halfID)) == evidenceBefore,
                         "工作区:缺 meta.json 的半截目录也算已存在,create 抛错且其 logs 证据一字未动")
            report.check(!fs3.exists(at: ws3.metaPath(for: halfID)),
                         "工作区:被拒的 create 没有往半截目录里补写 meta.json(不假装它是自己建的)")
            report.check(try ws3.list().isEmpty,
                         "工作区:缺 meta.json 的半截目录对 list 不可见(已知限制:证据不销毁优先于自动清理)")
        } catch {
            report.check(false, "工作区:半截目录用例意外抛错 \(error)")
        }
    }

    // MARK: - ⑤ raw 与 normalized 永不互写

    private static func testRawNeverMixesWithNormalized(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let id = "20260729-1432-mixed-streams-c3d4"
        let rawA = #"{"type":"system","subtype":"init","session_id":"sess-1"}"#
        let rawB = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#
        do {
            try ws.create(taskID: id, prompt: "mixed", agent: "claude", initiator: "cli")
            // 交替写两种,模拟真实流:原始行进 raw、归一化消息进 normalized。
            try ws.appendRaw(rawA, taskID: id)
            try ws.appendNormalized(AgentMessage.status(.sessionStarted), taskID: id)
            try ws.appendRaw(rawB, taskID: id)
            try ws.appendNormalized(AgentMessage.text("hello"), taskID: id)
            try ws.appendNormalized(AgentMessage.toolUse(callID: "call-1", tool: "Write", input: nil), taskID: id)
            try ws.appendStderr("ERROR some noisy stderr line", taskID: id)

            let raw = fs.contents(at: ws.rawLogPath(for: id)) ?? ""
            let normalized = fs.contents(at: ws.normalizedLogPath(for: id)) ?? ""
            let stderr = fs.contents(at: ws.stderrLogPath(for: id)) ?? ""

            report.check(raw.contains(rawA) && raw.contains(rawB),
                         "工作区:两条原始行逐字进了 raw.ndjson(agent 原话全量落盘)")
            report.check(!raw.contains("kind"),
                         "工作区:raw.ndjson 里不含归一化消息的任何一行(raw 与 normalized 永不互写)")
            report.check(normalized.contains("\"kind\"") && normalized.contains("session-started"),
                         "工作区:归一化消息逐行 JSON 进了 normalized.ndjson")
            report.check(!normalized.contains(rawA) && !normalized.contains(rawB),
                         "工作区:normalized.ndjson 里不含任何一条原始行(两个文件内容互不含对方)")
            report.check(normalized.contains("\"callID\" : \"call-1\"") || normalized.contains("\"callID\":\"call-1\""),
                         "工作区:归一化落盘保住 callID(全链不丢)")
            report.check(fs.appendCount(at: ws.rawLogPath(for: id)) == 2
                            && fs.appendCount(at: ws.normalizedLogPath(for: id)) == 3
                            && fs.appendCount(at: ws.stderrLogPath(for: id)) == 1,
                         "工作区:三条追加路径各写各的文件,追加次数逐个对得上")
            report.check(stderr.contains("ERROR some noisy stderr line") && !raw.contains("noisy stderr"),
                         "工作区:stderr 只进 logs 下的 stderr.log,不污染 raw.ndjson")
            report.check(normalized.split(separator: "\n").count == 3,
                         "工作区:normalized.ndjson 是逐行 JSON,三条消息恰三行")

            // 写入失败必须如实抛出(不吞错:吞掉就等于日志静默丢了一段还没人知道)。
            fs.programWriteFailure(at: ws.rawLogPath(for: id))
            var threw = false
            do { try ws.appendRaw("another", taskID: id) } catch { threw = true }
            report.check(threw, "工作区:文件系统写入失败时如实抛出,不吞错")
        } catch {
            report.check(false, "工作区:raw 与 normalized 分流路径意外抛错 \(error)")
        }
    }

    // MARK: - CR 回填约束:turn 边界不当闸门

    private static func testTurnBoundaryIsNotAGate(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let id = "20260729-1432-pre-turn-item-e5f6"
        do {
            try ws.create(taskID: id, prompt: "codex run", agent: "codex", initiator: "cli")
            // 02 spike 的 exec6 实证形状:item 的 error 出现在 turn.started **之前**。
            try ws.appendNormalized(AgentMessage.error("model metadata missing"), taskID: id)
            try ws.appendNormalized(AgentMessage.status(.turnStarted), taskID: id)
            try ws.appendNormalized(AgentMessage.text("done"), taskID: id)

            let normalized = fs.contents(at: ws.normalizedLogPath(for: id)) ?? ""
            let itemIndex = normalized.range(of: "model metadata missing")?.lowerBound
            let turnIndex = normalized.range(of: "turn-started")?.lowerBound
            report.check(itemIndex != nil && turnIndex != nil && itemIndex! < turnIndex!,
                         "工作区:turn-started 之前到达的 item 消息照样全量落盘且次序不变(不拿 turn 边界当闸门)")
            report.check(normalized.split(separator: "\n").count == 3,
                         "工作区:pre-turn 的 item 消息不被丢弃,三条消息全在(丢它就是丢诊断信息)")
        } catch {
            report.check(false, "工作区:turn 边界用例意外抛错 \(error)")
        }
    }

    // MARK: - ⑥ session_id 拿到即写

    private static func testSessionIDWrittenImmediately(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let id = "20260729-1432-session-write-7a8b"
        do {
            try ws.create(taskID: id, prompt: "session", agent: "claude", initiator: "cli")
            try ws.updateMeta(taskID: id) { meta in
                meta.state = .running
                meta.pid = 4242
                meta.startedAt = "2026-07-29T14:33:00Z"
            }
            // 会话起始行一到手就落盘(提案 §3:学 multica「立刻落盘」,为将来 resume 留门)。
            try ws.updateMeta(taskID: id) { $0.sessionID = "sess-abc-123" }

            let meta = try ws.readMeta(taskID: id)
            let metaText = fs.contents(at: ws.metaPath(for: id)) ?? ""
            report.check(meta.sessionID == "sess-abc-123" && metaText.contains("\"session_id\""),
                         "工作区:session_id 拿到即经 updateMeta 落盘(提案 §3 立刻落盘)")
            report.check(meta.state == .running && meta.pid == 4242,
                         "工作区:pending 迁 running 并把 pid 落进 meta(残留判定的唯一依据)")
            report.check(fs.writeCount(at: ws.metaPath(for: id)) == 3,
                         "工作区:meta.json 恰被写了 create 与两次 updateMeta 共三次(单写者)")
            report.check(fs.appendCount(at: ws.rawLogPath(for: id)) == 0
                            && fs.appendCount(at: ws.normalizedLogPath(for: id)) == 0,
                         "工作区:写 meta 绝不顺手碰两个 ndjson(单写者只写自己那份)")
        } catch {
            report.check(false, "工作区:session_id 落盘用例意外抛错 \(error)")
        }
    }

    // MARK: - meta 的两个不可变字段(task_id / schema_version)

    private static func testImmutableMetaFields(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let id = "20260729-1432-immutable-fields-5e6f"
        do {
            try ws.create(taskID: id, prompt: "immutable", agent: "claude", initiator: "cli")
            let before = fs.contents(at: ws.metaPath(for: id))
            let writesBefore = fs.writeCount(at: ws.metaPath(for: id))

            // task_id 就是目录名:改了它,磁盘上同一个目录里会写着另一个 id —— 凭空造出第二个真相。
            var threwTaskID = false
            do { try ws.updateMeta(taskID: id) { $0.taskID = "20260729-1432-somebody-else-0000" } }
            catch AgentTaskWorkspaceError.taskIDImmutable { threwTaskID = true }
            catch { }
            report.check(threwTaskID,
                         "工作区:updateMeta 改 task_id 被拒并抛 taskIDImmutable(目录名即 id,不容第二个真相)")

            // schema_version 的迁移不是一次普通更新(要动的是整份文件的读法),不许顺手改。
            var threwSchema = false
            do { try ws.updateMeta(taskID: id) { $0.schemaVersion = 2 } }
            catch AgentTaskWorkspaceError.schemaVersionImmutable { threwSchema = true }
            catch { }
            report.check(threwSchema,
                         "工作区:updateMeta 改 schema_version 被拒并抛 schemaVersionImmutable(版本迁移不是普通更新)")

            report.check(fs.contents(at: ws.metaPath(for: id)) == before
                            && fs.writeCount(at: ws.metaPath(for: id)) == writesBefore,
                         "工作区:两次改不可变字段都被拒,meta.json 内容与写入次数皆未变(校验先于写盘)")
        } catch {
            report.check(false, "工作区:不可变字段用例意外抛错 \(error)")
        }
    }

    // MARK: - 非法迁移抛错且磁盘一字未改

    private static func testIllegalTransitionLeavesDiskUntouched(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let id = "20260729-1432-illegal-move-9c0d"
        do {
            try ws.create(taskID: id, prompt: "illegal", agent: "claude", initiator: "cli")
            let before = fs.contents(at: ws.metaPath(for: id))
            let writesBefore = fs.writeCount(at: ws.metaPath(for: id))

            var threw = false
            do { try ws.updateMeta(taskID: id) { $0.state = .completed } } catch { threw = true }
            report.check(threw, "工作区:非法迁移 pending 到 completed 时 updateMeta 抛错")
            report.check(fs.contents(at: ws.metaPath(for: id)) == before,
                         "工作区:非法迁移抛错时 meta.json 内容一字未改(绝不静默改写)")
            report.check(fs.writeCount(at: ws.metaPath(for: id)) == writesBefore,
                         "工作区:非法迁移抛错时 meta.json 写入次数未增加(校验先于写盘)")

            // 走完整生命周期后,终态 meta 冻结:再更新(含迁向自身)一律抛错。
            try ws.updateMeta(taskID: id) { $0.state = .running }
            try ws.finish(taskID: id, state: .completed, exitCode: 0, finalText: "done")
            let frozen = fs.contents(at: ws.metaPath(for: id))

            var threwSelf = false
            do { try ws.updateMeta(taskID: id) { $0.state = .completed } } catch { threwSelf = true }
            report.check(threwSelf, "工作区:终态任务再迁向自身被拒且 updateMeta 抛错(终态元数据冻结)")

            var threwRevive = false
            do { try ws.updateMeta(taskID: id) { $0.state = .running } } catch { threwRevive = true }
            report.check(threwRevive, "工作区:终态任务迁回 running 被拒且 updateMeta 抛错(终态不可复活)")
            report.check(fs.contents(at: ws.metaPath(for: id)) == frozen,
                         "工作区:两次被拒的更新都没改动终态 meta.json")

            var threwNonTerminal = false
            do { try ws.finish(taskID: id, state: .running, exitCode: 0, finalText: nil) } catch { threwNonTerminal = true }
            report.check(threwNonTerminal, "工作区:finish 收到非终态时抛错")
        } catch {
            report.check(false, "工作区:非法迁移用例意外抛错 \(error)")
        }
    }

    // MARK: - ⑦ 崩溃残留:标 orphaned 且不销毁证据

    private static func testOrphanScanKeepsEvidence(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let dead = "20260729-1400-dead-host-aaaa"
        let live = "20260729-1401-live-agent-bbbb"
        let idle = "20260729-1402-never-started-cccc"
        let noPID = "20260729-1403-running-no-pid-dddd"
        do {
            try makeRunningTask(ws, id: dead, pid: 4242)
            try ws.appendRaw(#"{"type":"system","subtype":"init"}"#, taskID: dead)
            try ws.appendRaw(#"{"type":"assistant","message":{"content":[]}}"#, taskID: dead)
            try ws.appendStderr("some stderr", taskID: dead)
            try makeRunningTask(ws, id: live, pid: 100)
            try ws.create(taskID: idle, prompt: "not started", agent: "codex", initiator: "cli")
            // 拉起成功与「把 pid 落进 meta」之间宿主就崩了:state 已是 running,但没有 pid。
            try ws.create(taskID: noPID, prompt: "no pid", agent: "codex", initiator: "cli")
            try ws.updateMeta(taskID: noPID) { $0.state = .running }

            let rawBefore = fs.contents(at: ws.rawLogPath(for: dead))
            let promptBefore = fs.contents(at: ws.promptPath(for: dead))
            let stderrBefore = fs.contents(at: ws.stderrLogPath(for: dead))
            let rawWritesBefore = fs.appendCount(at: ws.rawLogPath(for: dead))

            let liveness = FakeLiveness(alive: [100])   // 4242 已死,100 还活着
            let marked = try ws.scanForOrphans(liveness: liveness)

            report.check(marked == [dead],
                         "残留扫描:state 为 running 且 pid 已死的任务被标出,且只标它一个")
            report.check((try? ws.readMeta(taskID: dead))?.state == .orphaned,
                         "残留扫描:崩溃残留任务的 meta 状态改为 orphaned")
            report.check((try? ws.readMeta(taskID: live))?.state == .running,
                         "残留扫描:pid 仍存活的 running 任务不被误标")
            report.check((try? ws.readMeta(taskID: idle))?.state == .pending,
                         "残留扫描:尚未拉起因而没有 pid 的 pending 任务不被误标")
            report.check((try? ws.readMeta(taskID: noPID))?.state == .running
                            && !liveness.queriedPIDs().isEmpty,
                         "残留扫描:state 为 running 但没记下 pid 的任务不被标 orphaned(没有判据就不判,不凭空断言它死了)")
            report.check((try? ws.readMeta(taskID: dead))?.finishedAt == nil,
                         "残留扫描:不臆造 finished_at 时间戳(并不知道它是何时死的)")

            report.check(fs.contents(at: ws.rawLogPath(for: dead)) == rawBefore
                            && fs.appendCount(at: ws.rawLogPath(for: dead)) == rawWritesBefore,
                         "残留扫描:标 orphaned 后 logs 下的 raw.ndjson 一个字节都没动(证据不销毁)")
            report.check(fs.contents(at: ws.promptPath(for: dead)) == promptBefore
                            && fs.contents(at: ws.stderrLogPath(for: dead)) == stderrBefore,
                         "残留扫描:prompt.md 与 stderr.log 同样一字未动")
            report.check(fs.writeCount(at: ws.promptPath(for: dead)) == 1
                            && fs.writeCount(at: ws.rawLogPath(for: dead)) == 1,
                         "残留扫描:除 meta.json 外没有任何文件被重写")
            report.check(liveness.queriedPIDs().contains(4242) && liveness.queriedPIDs().contains(100),
                         "残留扫描:判定确实走的是按 pid 探活(宿主重启后只剩 pid 可用)")

            // 再扫一遍不该重复标(它已经是终态了)。
            let again = try ws.scanForOrphans(liveness: liveness)
            report.check(again.isEmpty, "残留扫描:已标过的残留不会被重复标记")
        } catch {
            report.check(false, "残留扫描用例意外抛错 \(error)")
        }
    }

    // MARK: - ⑦b 孤儿是「猜」出来的:一手证据必须能纠正它(两轴 CR 独立收敛到的同一条)

    /// 复现那条真实失败时序,并钉死它现在能被纠正:
    ///   agent 子进程退出 → run 进程还在 drain 把事件流读到底(spec 要求,可达秒级)
    ///   → 另一个终端跑 `list` 触发 `scanForOrphans` → 看到 running + pid 已死 → 标 `orphaned`
    ///   → run 进程随后 `finish(.completed)`。
    /// 修之前:第四步抛 `illegalTransition`,一次**成功**的任务被永久记成孤儿、报告缺失、无任何纠正路径。
    private static func testOrphanRaceIsCorrectableByFinish(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let id = "20260729-1432-drain-race-1a2b"
        do {
            try makeRunningTask(ws, id: id, pid: 4242)
            try ws.appendNormalized(AgentMessage.text("端口 7890 没在听"), taskID: id)

            // 第三步:另一个终端的扫描抢先一步(FakeLiveness 默认全死 = 子进程确实已经退出了)。
            let marked = try ws.scanForOrphans(liveness: FakeLiveness())
            report.check(marked == [id] && (try? ws.readMeta(taskID: id))?.state == .orphaned,
                         "孤儿纠正:先复现 drain 期间被扫描抢标的时序(任务此刻是 orphaned)")

            // 第四步:run 进程拿着一手证据收尾 —— 必须成功。
            var threw = false
            do { try ws.finish(taskID: id, state: .completed, exitCode: 0, finalText: "端口 7890 没在听") }
            catch { threw = true }
            report.check(!threw,
                         "孤儿纠正:被抢标 orphaned 后 run 进程的 finish 不再抛错(一手证据不该被推测挡住)")

            let meta = try ws.readMeta(taskID: id)
            report.check(meta.state == .completed,
                         "孤儿纠正:纠正后 meta 的最终状态是 completed 而不是 orphaned(成功的任务不该被记成孤儿)")
            report.check(meta.exitCode == 0 && meta.finishedAt != nil,
                         "孤儿纠正:纠正的同时把 exit_code 与 finished_at 补齐(扫描当初刻意没填 finished_at)")
            report.check((fs.contents(at: ws.reportPath(for: id)) ?? "").contains("端口 7890 没在听"),
                         "孤儿纠正:纠正后报告被补出来了(被记成孤儿的旧行为下这份报告永远缺失)")

            // 四条出边逐条走一遍(每条一份新工作区,互不干扰)。
            for (state, label) in [(AgentTaskState.completed, "completed"), (.failed, "failed"),
                                   (.cancelled, "cancelled"), (.timeout, "timeout")] {
                let (w, _, _) = makeWorkspace()
                let tid = "20260729-1432-orphan-to-\(label)-9f9f"
                try makeRunningTask(w, id: tid, pid: 4242)
                _ = try w.scanForOrphans(liveness: FakeLiveness())
                try w.finish(taskID: tid, state: state, exitCode: 0, finalText: nil)
                report.check((try? w.readMeta(taskID: tid))?.state == state,
                             "孤儿纠正:orphaned 经 finish 迁到 \(label) 成功落盘")
            }

            // 反向:证据终态绝不能被后来的扫描退回 orphaned(单向)。
            var revived = false
            do { try ws.updateMeta(taskID: id) { $0.state = .orphaned } } catch { revived = true }
            report.check(revived,
                         "孤儿纠正:已收好的 completed 再被标 orphaned 一律抛错(证据不可被推测覆盖)")
        } catch {
            report.check(false, "孤儿纠正用例意外抛错 \(error)")
        }
    }

    // MARK: - ⑦c finish 同态幂等 + 报告自愈

    private static func testFinishIsIdempotentAndSelfHeals(_ report: inout AgentTestReport) {
        let (ws, fs, clock) = makeWorkspace()
        let id = "20260729-1432-idempotent-finish-7b8c"
        do {
            try ws.create(taskID: id, prompt: "idempotent", agent: "claude", initiator: "cli")
            try ws.updateMeta(taskID: id) { $0.state = .running }

            let clockBefore = clock.callCount()
            try ws.finish(taskID: id, state: .completed, exitCode: 0, finalText: "done")
            report.check(clock.callCount() - clockBefore == 1,
                         "工作区:一次 finish 只取一次现在(finished_at 与报告页脚是同一个时刻,不制造两个现在)")

            let metaAfterFirst = fs.contents(at: ws.metaPath(for: id))
            let metaWrites = fs.writeCount(at: ws.metaPath(for: id))

            var threw = false
            do { try ws.finish(taskID: id, state: .completed, exitCode: 0, finalText: "done") } catch { threw = true }
            report.check(!threw,
                         "工作区:finish 同态幂等 —— 同一个终态再 finish 一次不抛(不撞终态冻结)")
            report.check(fs.writeCount(at: ws.metaPath(for: id)) == metaWrites
                            && fs.contents(at: ws.metaPath(for: id)) == metaAfterFirst,
                         "工作区:同态幂等的第二次 finish 不增加 meta.json 写入次数、内容一字未改")

            // 自愈:上一次 meta 写成功但报告没写成(或写完 meta 就崩了)——重调同值 finish 应当把报告补出来。
            fs.removeFile(at: ws.reportPath(for: id))
            try ws.finish(taskID: id, state: .completed, exitCode: 0, finalText: "done")
            report.check((fs.contents(at: ws.reportPath(for: id)) ?? "").contains("done"),
                         "工作区:report.html 缺失时重调同值 finish 把报告补了出来(meta 写成功但报告写失败的自愈路径)")
            report.check(fs.writeCount(at: ws.metaPath(for: id)) == metaWrites,
                         "工作区:自愈补报告时仍然一次都不写 meta.json(终态元数据保持冻结)")

            // 幂等只对**同一个**终态成立:换一个终态仍按严格路径拦下(冻结逻辑一字未动)。
            var threwOther = false
            do { try ws.finish(taskID: id, state: .failed, exitCode: 1, finalText: nil) } catch { threwOther = true }
            report.check(threwOther,
                         "工作区:同态幂等只认同一个终态,换成别的终态再 finish 一律抛错(终态不是可反复改写的字段)")
        } catch {
            report.check(false, "工作区:finish 幂等用例意外抛错 \(error)")
        }
    }

    // MARK: - ⑦d finish 的 error 与终态一次写盘

    private static func testFinishWritesErrorInOneShot(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let failed = "20260729-1432-failed-with-error-2d3e"
        let ok = "20260729-1432-succeeded-clean-4f5a"
        do {
            try ws.create(taskID: failed, prompt: "boom", agent: "codex", initiator: "cli")
            try ws.updateMeta(taskID: failed) { $0.state = .running }
            let writesBefore = fs.writeCount(at: ws.metaPath(for: failed))
            // 调用方一般把 AgentTerminalStatus.reason 原样传进来(原生串保真)。
            let reason = AgentTerminalStatus(outcome: .failed, reason: "model not found: gpt-5-turbo").reason
            try ws.finish(taskID: failed, state: .failed, exitCode: 1, finalText: nil, error: reason)

            let meta = try ws.readMeta(taskID: failed)
            report.check(meta.error == "model not found: gpt-5-turbo" && meta.state == .failed,
                         "工作区:finish 的 error 参数落进 meta 的 error 字段(失败理由不必再补一次写盘)")
            report.check(fs.writeCount(at: ws.metaPath(for: failed)) == writesBefore + 1,
                         "工作区:error 与 state 与 finished_at 与 exit_code 一次写盘(不留下 error 已填但仍是 running 的半截现场)")
            report.check((fs.contents(at: ws.metaPath(for: failed)) ?? "").contains("\"error\" : \"model not found"),
                         "工作区:失败任务的 error 逐字落进 meta.json(原生串保真)")

            try ws.create(taskID: ok, prompt: "fine", agent: "claude", initiator: "cli")
            try ws.updateMeta(taskID: ok) { $0.state = .running }
            try ws.finish(taskID: ok, state: .completed, exitCode: 0, finalText: "ok")
            report.check(!(fs.contents(at: ws.metaPath(for: ok)) ?? "").contains("\"error\""),
                         "工作区:成功任务的 error 为 nil 时整键省略,meta.json 不产 error 噪音键")
        } catch {
            report.check(false, "工作区:finish 写 error 用例意外抛错 \(error)")
        }
    }

    // MARK: - ⑦e finalText 缺失时退回 normalized 的最后一条 text(Codex 侧的唯一来源)

    /// `AgentTerminalStatus` 与 `CodexAdapter` 两处文件头都白纸黑字写着「Codex 的 finalText 恒 nil,
    /// **04 退回取最后一条 `.text` 消息**」——这条断言就是那句承诺的落点。
    /// 只读 normalized(提案 §2:一切下游只消费 normalized,排障才碰 raw)。
    private static func testFinalTextFallsBackToLastNormalizedText(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let id = "20260729-1432-codex-final-text-6b7c"
        do {
            try ws.create(taskID: id, prompt: "codex run", agent: "codex", initiator: "cli")
            try ws.updateMeta(taskID: id) { $0.state = .running }
            try ws.appendNormalized(AgentMessage.status(.sessionStarted), taskID: id)
            try ws.appendNormalized(AgentMessage.text("过程文本:先看了一眼配置"), taskID: id)
            try ws.appendNormalized(AgentMessage.toolUse(callID: "item_1", tool: "shell", input: nil), taskID: id)
            try ws.appendNormalized(AgentMessage.text("结论:mixed-port 没在监听"), taskID: id)
            try ws.appendNormalized(AgentMessage.status(.turnCompleted), taskID: id)
            try ws.appendRaw(#"{"type":"item.completed","item":{"text":"raw 里的原话不该被报告读到"}}"#, taskID: id)

            // Codex 的终态 finalText 恒为 nil:这一路必须自己去 normalized 里取。
            try ws.finish(taskID: id, state: .completed, exitCode: 0, finalText: nil)
            let html = fs.contents(at: ws.reportPath(for: id)) ?? ""
            report.check(html.contains("结论:mixed-port 没在监听"),
                         "报告兜底:finalText 为 nil 时退回 normalized 里最后一条 text 消息(Codex 侧的唯一来源)")
            report.check(!html.contains("过程文本"),
                         "报告兜底:取的是最后一条 text 而不是第一条(后面的文本是对前面的收敛)")
            report.check(!html.contains("raw 里的原话"),
                         "报告兜底:只读 normalized.ndjson,绝不去 raw.ndjson 里取最终文本(提案 §2 的红线)")
            report.check(html.contains("<pre class=\"final-text\">"),
                         "报告兜底:退回来的最终文本仍走正文 pre 块(与 finalText 直给时同一套渲染)")

            // 一条 text 都没有的任务:如实说没有,不硬造、也不抛。
            let (ws2, fs2, _) = makeWorkspace()
            let silent = "20260729-1432-no-text-at-all-8d9e"
            try ws2.create(taskID: silent, prompt: "silent", agent: "codex", initiator: "cli")
            try ws2.updateMeta(taskID: silent) { $0.state = .running }
            try ws2.appendNormalized(AgentMessage.status(.turnCompleted), taskID: silent)
            try ws2.finish(taskID: silent, state: .completed, exitCode: 0, finalText: nil)
            let silentHTML = fs2.contents(at: ws2.reportPath(for: silent)) ?? ""
            report.check(silentHTML.contains("没有留下最终文本") && silentHTML.contains("logs/raw.ndjson"),
                         "报告兜底:normalized 里一条 text 都没有时如实说没有最终文本(不硬造内容)")

            // 日志文件被删了 / 读不出来:兜底路径尽力而为,绝不因此把一次成功的 finish 掀翻。
            let (ws3, fs3, _) = makeWorkspace()
            let broken = "20260729-1432-log-unreadable-0a1b"
            try ws3.create(taskID: broken, prompt: "broken", agent: "codex", initiator: "cli")
            try ws3.updateMeta(taskID: broken) { $0.state = .running }
            fs3.removeFile(at: ws3.normalizedLogPath(for: broken))
            var threw = false
            do { try ws3.finish(taskID: broken, state: .completed, exitCode: 0, finalText: nil) } catch { threw = true }
            report.check(!threw && (fs3.contents(at: ws3.reportPath(for: broken)) ?? "").contains("没有留下最终文本"),
                         "报告兜底:normalized.ndjson 读不出来时退回 nil 而不是抛错(兜底是尽力而为,不掀翻已写定的终态)")
        } catch {
            report.check(false, "报告兜底:最终文本退回路径意外抛错 \(error)")
        }
    }

    // MARK: - ⑧ HTML 报告

    private static func testReportFallback(_ report: inout AgentTestReport) {
        // escape 顺序是承重的:& 必须最先转,否则 &lt; 会被二次转义成 &amp;lt;。
        let escaped = AgentTaskReport.escapeHTML("a & b < c")
        report.check(escaped == "a &amp; b &lt; c",
                     "HTML 报告:先转 amp 再转其余 —— a and b less-than c 得到 amp 与 lt 各一次")
        report.check(!escaped.contains("&amp;lt;"),
                     "HTML 报告:绝不出现二次转义的 amp-lt(escape 顺序不可颠倒)")
        report.check(AgentTaskReport.escapeHTML("&<>\"'") == "&amp;&lt;&gt;&quot;&#39;",
                     "HTML 报告:五个危险字符逐个转义为 amp/lt/gt/quot/#39")

        let (ws, fs, _) = makeWorkspace()
        let fallbackID = "20260729-1432-fallback-report-d1e2"
        do {
            try ws.create(taskID: fallbackID, prompt: "report", agent: "claude", initiator: "cli")
            try ws.updateMeta(taskID: fallbackID) { $0.state = .running }
            try ws.finish(taskID: fallbackID, state: .completed, exitCode: 0, finalText: "a & b < c")

            let html = fs.contents(at: ws.reportPath(for: fallbackID)) ?? ""
            report.check(html.contains(AgentTaskReport.fallbackMarker),
                         "HTML 报告:缺 report.html 时兜底生成,且页脚显式标注由文本兜底生成")
            report.check(html.contains("a &amp; b &lt; c"),
                         "HTML 报告:兜底页正文是 escape 后的最终文本")
            report.check(!html.contains("http://") && !html.contains("https://") && !html.contains("<script"),
                         "HTML 报告:兜底页自包含,零外链零脚本")
            let meta = try ws.readMeta(taskID: fallbackID)
            report.check(meta.state == .completed && meta.exitCode == 0 && meta.finishedAt != nil,
                         "HTML 报告:finish 同时把终态与 exit_code 与 finished_at 落进 meta")
        } catch {
            report.check(false, "HTML 报告:兜底路径意外抛错 \(error)")
        }

        // 主路径:agent 自产的 report.html 原样保留,绝不覆盖。
        let (ws2, fs2, _) = makeWorkspace()
        let agentID = "20260729-1432-agent-report-f3a4"
        let agentHTML = "<!DOCTYPE html><html><body>AGENT WROTE THIS</body></html>"
        do {
            try ws2.create(taskID: agentID, prompt: "report", agent: "claude", initiator: "cli")
            try ws2.updateMeta(taskID: agentID) { $0.state = .running }
            try fs2.write(agentHTML, to: ws2.reportPath(for: agentID))   // 模拟 agent 自己写下报告
            try ws2.finish(taskID: agentID, state: .completed, exitCode: 0, finalText: "ignored fallback text")

            report.check(fs2.contents(at: ws2.reportPath(for: agentID)) == agentHTML,
                         "HTML 报告:已有 agent 自产的 report.html 时原样保留,绝不覆盖")
            report.check(fs2.writeCount(at: ws2.reportPath(for: agentID)) == 1,
                         "HTML 报告:agent 自产报告只被写过一次(兜底没有再写一遍)")
            report.check(!(fs2.contents(at: ws2.reportPath(for: agentID)) ?? "").contains(AgentTaskReport.fallbackMarker),
                         "HTML 报告:agent 自产报告里不会被塞进兜底标注")
        } catch {
            report.check(false, "HTML 报告:自产报告路径意外抛错 \(error)")
        }

        // finalText 缺失时如实说没有,并把人指向排障真相源。
        let empty = AgentTaskReport.fallbackHTML(taskID: "t", state: .failed, finalText: nil, generatedAt: "2026-07-29T15:00:00Z")
        report.check(empty.contains("logs/raw.ndjson") && empty.contains(AgentTaskReport.fallbackMarker),
                     "HTML 报告:没有最终文本时如实说明并指向 raw.ndjson,不硬造内容")
    }

    // MARK: - ⑨ prune 永不删 running / pending

    private static func testPruneNeverDeletesLiveTasks(_ report: inout AgentTestReport) {
        let (ws, fs, _) = makeWorkspace()
        let done = "task-a-completed"
        let kept = "task-b-failed"
        let running = "task-c-running"
        let pending = "task-d-pending"
        do {
            try ws.create(taskID: done, prompt: "done", agent: "claude", initiator: "cli")
            try ws.updateMeta(taskID: done) { $0.state = .running }
            try ws.finish(taskID: done, state: .completed, exitCode: 0, finalText: "ok")

            try ws.create(taskID: kept, prompt: "kept", agent: "claude", initiator: "cli")
            try ws.updateMeta(taskID: kept) { $0.state = .running }
            try ws.finish(taskID: kept, state: .failed, exitCode: 1, finalText: nil)

            try makeRunningTask(ws, id: running, pid: 555)
            try ws.appendRaw(#"{"type":"assistant"}"#, taskID: running)
            try ws.create(taskID: pending, prompt: "pending", agent: "codex", initiator: "cli")

            let listedBefore = try ws.list()
            report.check(listedBefore == [done, kept, running, pending].sorted(),
                         "prune:list 只把含 meta.json 的条目当任务,四个任务全在")

            // 点名保留 kept;其余三个都是「点名要删」——但 running/pending 必须被跳过。
            let result = try ws.prune(keepIDs: [kept])
            report.check(result.removed == [done],
                         "prune:终态任务目录被删除")
            report.check(result.skipped == [running, pending].sorted(),
                         "prune:running 与 pending 哪怕被点名要删也跳过,并如实出现在 skipped")
            let listedAfter = try ws.list()
            report.check(listedAfter == [kept, running, pending].sorted(),
                         "prune:删除后 list 里不再有该任务,其余三个原封不动")
            report.check(fs.contents(at: ws.rawLogPath(for: done)) == nil
                            && fs.contents(at: ws.metaPath(for: done)) == nil,
                         "prune:被删任务的整棵目录树都清掉了(递归删除)")
            report.check(fs.contents(at: ws.rawLogPath(for: running)) != nil,
                         "prune:被跳过的 running 任务的日志证据一字未动")
            report.check(fs.contents(at: ws.metaPath(for: kept)) != nil,
                         "prune:keepIDs 点名保留的终态任务不删")
        } catch {
            report.check(false, "prune 用例意外抛错 \(error)")
        }
    }

    // MARK: - ⑩ 读侧容忍未知字段

    private static func testUnknownFieldTolerance(_ report: inout AgentTestReport) {
        let fs = FakeFileSystem()
        let ws = AgentTaskWorkspace(root: root, fs: fs, clock: makeClock())
        let id = "20260729-1432-future-schema-b7c8"
        // 一份「未来版本」写下的 meta.json:多了两个本版本不认识的键,model 是显式 null。
        let futureMeta = """
        {
          "schema_version": 1,
          "task_id": "\(id)",
          "state": "running",
          "agent": "codex",
          "model": null,
          "workdir": "/fake/elsewhere",
          "initiator": "plugin",
          "created_at": "2026-07-29T14:32:00Z",
          "pid": 777,
          "future_key": 1,
          "another_future_block": {"nested": [1, 2, 3]}
        }
        """
        do {
            try fs.createDirectory(at: ws.directory(for: id))
            try fs.write(futureMeta, to: ws.metaPath(for: id))

            let meta = try ws.readMeta(taskID: id)
            report.check(meta.taskID == id && meta.state == .running,
                         "读侧容忍:meta.json 多出未知键时仍能正常解出、不抛(演进规则 只增不改义)")
            report.check(meta.pid == 777 && meta.initiator == "plugin" && meta.agent == "codex",
                         "读侧容忍:未知键不影响已知字段取值")
            report.check(meta.model == nil,
                         "读侧容忍:显式为 null 的可选字段解为 nil,不因 null 抛错")

            // 未知键**不该被我们悄悄剥掉**:updateMeta 是读-改-写,写侧丢了未知键,
            //   就等于旧版本单方面把新版本刚写下的字段(如 retry_count)抹掉 —— 那不是「向后兼容」。
            try ws.updateMeta(taskID: id) { $0.sessionID = "sess-future" }
            report.check((try? ws.readMeta(taskID: id))?.sessionID == "sess-future",
                         "读侧容忍:解出未来版本 meta 后仍能正常续写本版本认识的字段")

            let rewritten = fs.contents(at: ws.metaPath(for: id)) ?? ""
            report.check(rewritten.contains("\"future_key\""),
                         "写侧保留:updateMeta 读改写之后未知键 future_key 仍在 meta.json 里(不静默剥掉别人的字段)")
            report.check(rewritten.contains("\"another_future_block\"") && rewritten.contains("\"nested\""),
                         "写侧保留:未知的嵌套对象 another_future_block 连同其内部结构一并原样写回")
            report.check(rewritten.contains("\"session_id\" : \"sess-future\"")
                            && rewritten.contains("\"state\" : \"running\""),
                         "写侧保留:保住未知键的同时本版本自己的字段照常更新(两件事互不牵连)")

            // round-trip:本版本自己写下的 meta 再读回来必须全等。
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let roundTripped = try JSONDecoder().decode(AgentTaskMeta.self, from: try encoder.encode(meta))
            report.check(roundTripped == meta,
                         "读侧容忍:meta 经编码解码 round-trip 后全等")
        } catch {
            report.check(false, "读侧容忍用例意外抛错 \(error)")
        }
    }
}
