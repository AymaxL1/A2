// AAAgentTestKit —— `SystemAgentPort` 真实现的一致性测试(agent-delegation 06 票)。
// 依赖边:AAAgentTestKit → AAAgentSystem、AAAgentCore、AAContracts(+ Foundation/Darwin)。
//
// **本套件与前五张票的所有套件都不同:它碰真进程、真管道、真信号。**
// 被测进程一律是系统命令(/bin/sh、sleep、cat、head、yes),不需要真 agent、不需要 Xcode。
// 因此有两条纪律,写在最前面:
//   1. **测试卫生**:每条用例都在 defer 里 terminate + reclaim,绝不把 `sleep` 留在用户机器上;
//      另有一条 120 秒的整体看门狗(startWatchdog):任何一处读流意外阻塞都会打印 FAIL 并 exit,
//      让门禁失败而不是挂死(exit 会触发端口的 atexit 反孤儿钩子,残留进程随之被 SIGKILL)。
//   2. **只对自己 fork 出来的进程组发信号**:所有断言都用具体的 pid / pgid(kill(pid,0)、kill(-pgid,0)),
//      绝不出现宽泛的 pkill 模式。被测的 sleep 一律用**唯一时长** 87137 秒(check.sh 的残留核验按此定长串 grep,
//      不会误伤用户机上别的 sleep)。
//
// 断言分组:
//   ① 拉起并逐行读 / 中途自退被 isAlive 感知 / EOF 前没有换行的尾行被交回一次
//   ② **nextEvent 阻塞语义**(01 票 CR 的回归护栏:活着但暂无输出必须阻塞,不能返回 nil)
//   ③ **terminate 连带杀 agent 派生的子进程树、整组零残留**(票面最核心的一条)
//   ③b **并发 terminate 的退出码不被篡改**(CR 🔴:ECHILD 分支若沿用初值 0,一次取消会被误报成成功)
//   ④ stdin 两种处置(devNull / writeThenKeepOpen + 显式 closeStdin 收尾)
//   ⑤ 幂等与错误路径(terminate 两次 / 未知句柄 / launch 失败)
//   ⑥ 启动规格如实生效(environment / workingDirectory)与 stderr 不阻塞
//
// 说明:各 PASS 描述串是 check.sh 阶段 B assert_contains 的定长子串目标,**不得随意改字**
//   (改则同步改 check.sh 断言组 1h)。

import Foundation
import Darwin
import AAAgentCore
import AAAgentSystem

/// `SystemAgentPort`(真进程 + 进程组 + 反孤儿)一致性测试。
public enum SystemAgentPortTests {

    /// 被测 sleep 的唯一时长:check.sh 用 `pgrep -f "sleep 87137"` 核验零残留而不误伤用户进程。
    private static let markerSleep = "87137"
    /// 子进程环境(刻意只给最小 PATH:证明端口如实传 spec.environment、不隐式继承宿主环境)。
    private static let childPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func run() -> AgentTestReport {
        startWatchdog(120)
        var report = AgentTestReport()
        testLaunchAndReadLines(&report)
        testUnterminatedTailLine(&report)
        testSelfExitDetected(&report)
        testBlockingSemantics(&report)
        testTerminateKillsProcessGroup(&report)
        testReapAccounting(&report)
        testConcurrentTerminateExitCode(&report)
        testStdinDispositions(&report)
        testIdempotenceAndFailures(&report)
        testSpecFidelityAndStderr(&report)
        markFinished()
        return report
    }

    // ============ ① 拉起并逐行读 ============

    private static func testLaunchAndReadLines(_ report: inout AgentTestReport) {
        let port = SystemAgentPort()
        guard let h = launch(port, "echo a; echo b", &report, "①逐行读") else { return }
        defer { port.terminate(h); port.reclaim(h) }
        report.check(port.nextEvent(h) == "a", "SystemAgentPort:真子进程 stdout 逐行读出第 1 行 a")
        report.check(port.nextEvent(h) == "b", "SystemAgentPort:真子进程 stdout 逐行读出第 2 行 b")
        report.check(port.nextEvent(h) == nil, "SystemAgentPort:stdout 到达 EOF 后 nextEvent 返回 nil")
        report.check(port.nextEvent(h) == nil, "SystemAgentPort:EOF 之后再读恒为 nil(不重放、不阻塞)")
    }

    // ============ ① EOF 前没有换行的尾行 ============

    /// agent 被杀在半行上时,那半截就是唯一现场:实现承诺「EOF 时把剩余不完整尾行(若非空)返回一次」,
    /// 但此前无用例覆盖。被测进程 `printf 'x'` 刻意不带 \n。
    private static func testUnterminatedTailLine(_ report: inout AgentTestReport) {
        let port = SystemAgentPort()
        guard let h = launch(port, "printf x", &report, "①尾行") else { return }
        defer { port.terminate(h); port.reclaim(h) }
        report.check(port.nextEvent(h) == "x",
                     "SystemAgentPort:EOF 前没有换行的尾行被交回一次(半截行是唯一现场,不许吞掉)")
        report.check(port.nextEvent(h) == nil,
                     "SystemAgentPort:不完整尾行只交回一次,之后恒为 nil(不重放)")
    }

    // ============ ① 进程中途自退被感知 ============

    private static func testSelfExitDetected(_ report: inout AgentTestReport) {
        let port = SystemAgentPort()
        guard let h = launch(port, "exit 0", &report, "①自退") else { return }
        defer { port.reclaim(h) }
        report.check(port.nextEvent(h) == nil, "SystemAgentPort:自退进程无输出时 nextEvent 读到 EOF 返回 nil")
        report.check(waitUntil(5) { !port.isAlive(h) },
                     "SystemAgentPort:进程中途自退后 isAlive 为假(探活基于真 pid,不靠猜)")
        port.terminate(h)
        report.check(port.exitCode(h) == 0, "SystemAgentPort:正常退出的进程收尸后退出码为 0")
    }

    // ============ ② nextEvent 阻塞语义(01 票 CR 的硬要求)============

    private static func testBlockingSemantics(_ report: inout AgentTestReport) {
        let port = SystemAgentPort()
        guard let h = launch(port, "sleep 1; echo late", &report, "②阻塞语义") else { return }
        defer { port.terminate(h); port.reclaim(h) }
        let t0 = Date()
        let first = port.nextEvent(h)
        let elapsed = Date().timeIntervalSince(t0)
        report.check(first == "late",
                     "SystemAgentPort:进程活着但暂无输出时 nextEvent 阻塞到有整行(第一次调用就拿到 late,绝不返回 nil)")
        report.check(elapsed >= 0.5,
                     "SystemAgentPort:该次 nextEvent 确实阻塞等待了(耗时不小于 0.5 秒,不是恰好碰上有数据)")
        report.check(port.nextEvent(h) == nil, "SystemAgentPort:阻塞读出末行后进程退出,再读为 nil(EOF 才是 nil)")
    }

    // ============ ③ terminate 连带杀子进程树(票面最核心)============

    private static func testTerminateKillsProcessGroup(_ report: inout AgentTestReport) {
        let port = SystemAgentPort()
        // 脚本:先后台派生一个孙进程(打印其 pid),再打印自己的 pid,最后自己也挂在一个长 sleep 上。
        let script = "sleep \(markerSleep) & echo $!; echo $$; sleep \(markerSleep)"
        guard let h = launch(port, script, &report, "③进程组") else { return }
        defer { port.terminate(h); port.reclaim(h) }

        guard let bgLine = port.nextEvent(h), let shLine = port.nextEvent(h),
              let grandchild = pid_t(bgLine), let leaderPID = pid_t(shLine) else {
            report.check(false, "SystemAgentPort:③用例应能读到孙进程 pid 与子进程自身 pid"); return
        }
        let pgid = port.processGroupIdentifier(h) ?? 0

        // 进程组本身必须真建起来 —— 否则 kill(-pgid, …) 会把宿主自己一起杀掉,连带杀子树根本无从谈起。
        report.check(port.ownsProcessGroup(h),
                     "SystemAgentPort:子进程自成进程组组长(POSIX_SPAWN_SETPGROUP 真生效,不是继承宿主的组)")
        report.check(pgid == leaderPID,
                     "SystemAgentPort:进程组 id 等于子进程自己的 pid(组长就是它,kill(-pgid) 够得着整棵子树)")
        report.check(pgid != getpgrp(),
                     "SystemAgentPort:子进程组绝不等于宿主进程组(若相等,按组发信号会把宿主自己杀掉)")
        report.check(getpgid(grandchild) == pgid,
                     "SystemAgentPort:agent 派生的孙进程与它同组(所以一刀能连带收拾)")
        // 反证:杀之前它们确实活着,下面那条断言不是空跑。
        report.check(!pidGone(grandchild), "SystemAgentPort:terminate 之前派生的孙进程确实活着(反证下一条不是空跑)")
        report.check(port.isAlive(h), "SystemAgentPort:terminate 之前 isAlive 为真")

        port.terminate(h)

        report.check(waitUntil(5) { pidGone(grandchild) },
                     "SystemAgentPort:terminate 连带杀掉 agent 派生的孙进程(进程组终止,不留孤儿)")
        report.check(waitUntil(5) { processGroupGone(pgid) },
                     "SystemAgentPort:terminate 后整个进程组零残留(kill(-pgid,0) 得 ESRCH)")
        report.check(!port.isAlive(h), "SystemAgentPort:terminate 后 isAlive 为假")
        report.check((port.exitCode(h) ?? 0) < 0,
                     "SystemAgentPort:被信号终止的进程退出码为负(与 04 票『负值即被信号杀』口径一致)")
        // 取消之后仍能把管道读到底(Claude 被中断后会先补 [Request interrupted] 再落终态才退出)。
        report.check(port.nextEvent(h) == nil,
                     "SystemAgentPort:terminate 之后管道仍可读到底再 EOF(取消后 drain 的前提)")
    }

    // ============ ③b 并发收尸不得把「被信号杀」篡改成「成功」 ============

    /// 记账层(纯内存,不碰进程):ECHILD 分支必须交 nil 而不是初值 0,且首写生效。
    /// 这条 🔴 的危害面:`exitCode` 返回 0 → 04 票 `resolve` 判 completed → **一次取消被记成成功**,
    /// 正是「宁可把成功误报为失败,绝不把失败误报为成功」所禁止的方向。
    private static func testReapAccounting(_ report: inout AgentTestReport) {
        let p = SystemAgentPort.reapAccountingProbe()
        report.check(p.echild == nil,
                     "SystemAgentPort:收尸拿不到状态(ECHILD)时退出码保持 nil 而不是 0(fail-closed,取消绝不被记成成功)")
        report.check(p.real == -Int32(SIGTERM) && p.afterNil == p.real,
                     "SystemAgentPort:已收尸的记账再次 markReaped(nil) 不改写已有退出状态(首写生效,后到的 nil 抹不掉 -15)")
    }

    /// 端到端:两个线程同时 terminate 同一个句柄(测试 defer + 05 看门狗取消 + 07 清理的现实并发)。
    /// 无论谁先抢到收尸,退出码都**绝不能是 0** —— 要么是负值(真被信号杀),要么是 nil(状态未知,fail-closed)。
    private static func testConcurrentTerminateExitCode(_ report: inout AgentTestReport) {
        let port = SystemAgentPort()
        guard let h = launch(port, "sleep \(markerSleep)", &report, "③b并发取消") else { return }
        defer { port.reclaim(h) }
        let lock = NSLock()
        var finished = 0
        for _ in 0..<2 {
            let t = Thread {
                port.terminate(h)
                lock.lock(); finished += 1; lock.unlock()
            }
            t.name = "SystemAgentPortTests.concurrent-terminate"
            t.start()
        }
        let bothDone = waitUntil(20) { lock.lock(); let f = finished; lock.unlock(); return f == 2 }
        report.check(bothDone, "SystemAgentPort:两个线程并发 terminate 同一句柄都能返回(不自锁、不互相挡死)")
        let code = port.exitCode(h)
        report.check(code == nil || code! < 0,
                     "SystemAgentPort:并发 terminate 后退出码绝不是 0(负值或 nil,一次取消不会被篡改成成功)")
        report.check(waitUntil(5) { processGroupGone(port.processGroupIdentifier(h) ?? 0) },
                     "SystemAgentPort:并发 terminate 之后进程组同样零残留")
    }

    // ============ ④ stdin 两种处置 ============

    private static func testStdinDispositions(_ report: inout AgentTestReport) {
        let port = SystemAgentPort()

        // (a) devNull:Codex exec 若不给 stdin 会静默挂起(02 spike 实证)。cat 必须立刻收到 EOF。
        if let h = launch(port, "cat; echo done", &report, "④devNull", stdin: .devNull) {
            defer { port.terminate(h); port.reclaim(h) }
            report.check(port.nextEvent(h) == "done",
                         "SystemAgentPort:stdin 接 /dev/null 时 cat 立刻读到 EOF 不挂起(读出 done)")
        }

        // (b) writeThenKeepOpen:写一行后**保持写端打开**,进程不自退;由适配层显式 closeStdin 收尾
        //     (Claude stream-json 形态)。用 cat 当被测进程:回显即证明写进去了,不退出即证明写端还开着。
        if let h = launch(port, "cat", &report, "④keepOpen", stdin: .writeThenKeepOpen("hello")) {
            defer { port.terminate(h); port.reclaim(h) }
            report.check(port.nextEvent(h) == "hello",
                         "SystemAgentPort:writeThenKeepOpen 写入的一行被子进程读到并回显(hello)")
            report.check(port.isAlive(h),
                         "SystemAgentPort:写完后 stdin 写端保持打开,子进程不自退(Claude stream-json 形态)")
            port.closeStdin(h)
            report.check(port.nextEvent(h) == nil,
                         "SystemAgentPort:显式 closeStdin 后子进程收到 EOF 退出,读流随之 EOF(收尾路径可用)")
            report.check(waitUntil(5) { !port.isAlive(h) },
                         "SystemAgentPort:closeStdin 之后进程确实退出(两种 stdin 处置行为相反,都被覆盖)")
        }
    }

    // ============ ⑤ 幂等与错误路径 ============

    private static func testIdempotenceAndFailures(_ report: inout AgentTestReport) {
        let port = SystemAgentPort()

        // terminate 幂等:同一句柄两次。
        if let h = launch(port, "sleep \(markerSleep)", &report, "⑤幂等") {
            let pgid = port.processGroupIdentifier(h) ?? 0
            port.terminate(h)
            port.terminate(h)
            report.check(true, "SystemAgentPort:同一句柄 terminate 两次不崩不抛(幂等)")
            report.check(!port.isAlive(h), "SystemAgentPort:两次 terminate 之后 isAlive 仍为假")
            report.check(waitUntil(5) { processGroupGone(pgid) },
                         "SystemAgentPort:重复 terminate 之后进程组依然零残留")
            port.reclaim(h)
            report.check(!port.isAlive(h), "SystemAgentPort:reclaim 之后句柄语义不变(isAlive 为假)")
            report.check(port.nextEvent(h) == nil, "SystemAgentPort:reclaim 之后 nextEvent 为 nil(不阻塞)")
        }

        // 未知句柄:三个方法都安全 no-op。
        let unknown = AgentProcessHandle(id: 999_999_999)
        port.terminate(unknown)
        report.check(true, "SystemAgentPort:未知句柄 terminate 为 no-op(不崩不抛)")
        report.check(port.nextEvent(unknown) == nil, "SystemAgentPort:未知句柄 nextEvent 返回 nil(不阻塞、不崩)")
        report.check(!port.isAlive(unknown), "SystemAgentPort:未知句柄 isAlive 为假")

        // launch 失败:可执行不存在 → 抛错(不是崩)。
        var threw = false
        do {
            _ = try port.launch(spec("/nonexistent/aa-agent-no-such-binary", ["-c", "echo x"]))
        } catch { threw = true }
        report.check(threw, "SystemAgentPort:可执行路径不存在时 launch 抛错(不崩、不返回坏句柄)")

        // launch 失败:工作目录不存在 → 抛错(绝不静默拉起到别的目录去干活)。
        var threwCWD = false
        do {
            _ = try port.launch(spec("/bin/sh", ["-c", "echo x"], cwd: "/nonexistent/aa-agent-no-such-dir"))
        } catch { threwCWD = true }
        report.check(threwCWD, "SystemAgentPort:工作目录不存在时 launch 抛错(绝不静默换个目录干活)")
    }

    // ============ ⑥ 启动规格如实生效 + stderr 不阻塞 ============

    private static func testSpecFidelityAndStderr(_ report: inout AgentTestReport) {
        let port = SystemAgentPort()

        // (a) environment / workingDirectory 如实生效。
        let dir = NSTemporaryDirectory() + "aa-agent-06-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // 用 realpath 取物理路径:临时目录在 /var/folders/…,而 /var 是 /private/var 的软链,
        // 子进程的 pwd(getcwd)交回的是物理路径 —— Foundation 的 resolvingSymlinksInPath 恰好不做这一步,不能用。
        var pathBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(dir, &pathBuf).map { String(cString: $0) } ?? dir
        let s = AgentLaunchSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo $AA_AGENT_PROBE; pwd"],
            environment: ["PATH": childPATH, "AA_AGENT_PROBE": "probe-value"],
            workingDirectory: dir,
            stdin: .devNull
        )
        if let h = try? port.launch(s) {
            defer { port.terminate(h); port.reclaim(h) }
            report.check(port.nextEvent(h) == "probe-value",
                         "SystemAgentPort:spec.environment 如实传给子进程(每任务独立 CODEX_HOME 的前提)")
            report.check(port.nextEvent(h) == resolved,
                         "SystemAgentPort:spec.workingDirectory 生效(子进程 pwd 即委托指定的工作目录)")
        } else {
            report.check(false, "SystemAgentPort:⑥用例应能拉起 /bin/sh")
        }

        // (b) stderr 必须有人排干:子进程往 stderr 灌 100KB+ 仍不把自己卡死,且内容进了记账(07 票落 stderr.log 的来源)。
        if let h = launch(port, "yes aa-stderr-noise | head -n 10000 >&2; echo ok", &report, "⑥stderr") {
            defer { port.terminate(h); port.reclaim(h) }
            report.check(port.nextEvent(h) == "ok",
                         "SystemAgentPort:子进程向 stderr 灌 100KB 以上也不被管道缓冲卡死(stderr 由专线排干)")
            report.check(waitUntil(5) { port.drainedStderr(h).contains("aa-stderr-noise") },
                         "SystemAgentPort:stderr 内容被排干进记账(07 票 logs/stderr.log 的来源)")
        }
    }

    // ============ helpers ============

    /// 造一个跑 /bin/sh -c 的启动规格。
    private static func spec(_ exe: String, _ args: [String], cwd: String = "/tmp",
                             stdin: AgentStdinDisposition = .devNull) -> AgentLaunchSpec {
        AgentLaunchSpec(executablePath: exe, arguments: args,
                        environment: ["PATH": childPATH], workingDirectory: cwd, stdin: stdin)
    }

    /// 拉起一段 shell 脚本;失败时记一条 FAIL 并返回 nil(绝不让后续断言在坏句柄上空跑)。
    private static func launch(_ port: SystemAgentPort, _ script: String,
                               _ report: inout AgentTestReport, _ tag: String,
                               stdin: AgentStdinDisposition = .devNull) -> AgentProcessHandle? {
        do { return try port.launch(spec("/bin/sh", ["-c", script], stdin: stdin)) }
        catch {
            report.check(false, "SystemAgentPort:\(tag) 用例应能拉起 /bin/sh(实际抛错:\(error))")
            return nil
        }
    }

    /// 有界轮询等待条件成立(测试里一切等待都必须有上界,否则门禁会挂死)。
    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            usleep(50_000)
        } while Date() < end
        return condition()
    }

    /// 指定 pid 是否已彻底消失(僵尸仍算存在,故这里等的是「连僵尸都被回收」)。
    private static func pidGone(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return false }
        return errno == ESRCH
    }

    /// 指定进程组是否已空(整组零残留的判据;只对自己 fork 出来的 pgid 用)。
    private static func processGroupGone(_ pgid: pid_t) -> Bool {
        guard pgid > 0 else { return true }
        if kill(-pgid, 0) == 0 { return false }
        return errno == ESRCH
    }

    // ---- 整体看门狗:任何一处读流意外阻塞都让门禁**失败**而不是挂死 ----

    private static let finishLock = NSLock()
    private static var finished = false

    private static func markFinished() {
        finishLock.lock(); finished = true; finishLock.unlock()
    }

    private static func startWatchdog(_ seconds: Double) {
        let t = Thread {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                finishLock.lock(); let done = finished; finishLock.unlock()
                if done { return }
                usleep(200_000)
            }
            finishLock.lock(); let done = finished; finishLock.unlock()
            if !done {
                print("FAIL: SystemAgentPort 测试整体超时(\(Int(seconds)) 秒)—— 某处读流阻塞未解")
                print("SYSTEMPORT_TESTS passed=0 failed=1")
                fflush(stdout)
                // exit 会触发端口的 atexit 反孤儿钩子,自己拉起的进程组随之被 SIGKILL,不留给用户机器。
                exit(9)
            }
        }
        t.name = "SystemAgentPortTests.watchdog"
        t.start()
    }
}

/// 反孤儿钩子的 E2E 探针(由 check.sh 生成的 runner 在 `AA_ORPHAN_PROBE` 模式下调用,**不返回**)。
///
/// 在进程内无法断言「宿主死后子进程被回收」——那需要宿主真的死一次。故把这一步做成探针:
/// 探针拉起一个自带孙进程的进程组、把 pgid 打给 check.sh,然后**不 terminate** 就让自己退出/被杀,
/// 由 check.sh 在外面核验整组已被钩子 SIGKILL 干净(见 check.sh 断言组 1h' 的两条反孤儿 E2E)。
///
/// **两条反证**(没有它们,空进程组会让「零残留」永远为真 —— 探针自欺):
///   * exit 模式:探针退出前自证 `kill(-pgid, 0) == 0` 并打印 `ORPHAN_PROBE_ALIVE=1`,check.sh assert 之;
///   * signal 模式:check.sh 在**发 SIGTERM 之前**另做一次 `pgrep -g <pgid>` 非空断言。
public enum SystemAgentPortOrphanProbe {
    /// 被测 sleep 的唯一时长(与套件内的 87137 分开,便于 check.sh 分别核验残留)。
    private static let markerSleep = "87139"

    /// mode = "exit":打印 pgid 后正常 exit(0) → 必须由 **atexit 钩子**回收整组。
    /// mode = "signal":打印 pgid 后挂着等 check.sh 发 SIGTERM → 必须由 **信号钩子**回收整组后重抛。
    public static func run(mode: String) -> Never {
        let port = SystemAgentPort()
        let s = AgentLaunchSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep \(markerSleep) & sleep \(markerSleep)"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/tmp",
            stdin: .devNull
        )
        guard let h = try? port.launch(s), let pgid = port.processGroupIdentifier(h), pgid > 0 else {
            print("ORPHAN_PROBE_LAUNCH_FAILED"); fflush(stdout); exit(4)
        }
        usleep(400_000)   // 等孙进程真起来,再自证下面那条「杀之前确实活着」

        // **反证(缺了它整条探针就能空跑通过)**:若两个 sleep 因任何原因没起来(或 sh 瞬死),
        // 进程组天然为空,check.sh 那条「退出后整组零残留」照样绿 —— 探针就在自欺。
        // 故这里先自证整组此刻确实活着:kill(-pgid, 0) == 0。exit 模式下 check.sh 断言 ORPHAN_PROBE_ALIVE=1;
        // signal 模式下 check.sh 另有一条**发 SIGTERM 之前**的 `pgrep -g "$PGID"` 非空断言(两侧互不替代)。
        let aliveBefore = (kill(-pgid, 0) == 0)
        print("ORPHAN_PROBE_PGID=\(pgid)")
        print("ORPHAN_PROBE_ALIVE=\(aliveBefore ? 1 : 0)")
        fflush(stdout)

        switch mode {
        case "exit":
            exit(0)                          // atexit 钩子必须在此把整组 SIGKILL 掉
        case "signal":
            let end = Date().addingTimeInterval(30)
            while Date() < end { usleep(100_000) }   // 等 SIGTERM;等不到就自曝失败(不静默通过)
            print("ORPHAN_PROBE_NO_SIGNAL"); fflush(stdout)
            exit(3)
        default:
            print("ORPHAN_PROBE_UNKNOWN_MODE=\(mode)"); fflush(stdout); exit(5)
        }
    }
}
