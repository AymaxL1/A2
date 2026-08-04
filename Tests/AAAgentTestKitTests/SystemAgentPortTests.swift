// 17 票:从 `AAAgentTestKit.SystemAgentPortTests` 迁到 swift-testing
//   (迁移口径见 Tests/AAHostTestKitTests/RegistryConformanceTests.swift 头注)。
//
// `SystemAgentPort` 真实现的一致性测试(agent-delegation 06 票)。
//
// ⚠️⚠️ **本套件与 Tests/ 下其它套件都不同:它碰真进程、真管道、真信号。**
//   被测进程一律是系统命令(/bin/sh、sleep、cat、head、yes),不需要真 agent、不需要 Xcode。
//   被测的 sleep 一律用**唯一时长 87137 秒** —— 门禁靠 `pgrep -f "sleep 87137"` 核验零残留,不会误伤用户机上别的 sleep。
//
//   **裸跑 `swift test` 没有清场网 —— 详见 Tests/README.md。**
//   `Scripts/check.sh` 里的 `bootstrap.sh` 装了 `trap cleanup EXIT`,cleanup 会 `pkill -f "sleep 87137"`,
//   于是经门禁跑的这套用例即使中途崩了也不会给用户留孤儿进程。**直接手敲 `swift test` 时那层网不存在**:
//   如果用例在 terminate 之前被 Ctrl-C / 崩溃打断,`sleep 87137` 会留在你的机器上(24 小时后才自己退)。
//   手工排查时请用 `bash Scripts/check.sh`,或自己在跑完后执行:`pkill -f "sleep 87137"`。
//
// 两条纪律(与旧实现一字不改):
//   1. **测试卫生**:每条用例都在 defer 里 terminate + reclaim,绝不把 `sleep` 留在用户机器上;
//      另有一条逐用例看门狗(`withWatchdog`):任何一处读流意外阻塞都会打印 FAIL 并 `exit(9)`,
//      让门禁**失败**而不是挂死(exit 会触发端口的 atexit 反孤儿钩子,残留进程随之被 SIGKILL)。
//      旧实现是**整套件**一个 120 秒看门狗(`run()` 里起、`markFinished()` 收);swift-testing 下用例是独立单元,
//      没有「整套件跑完」这个时刻,故改为**逐用例 60 秒**——更早暴露,语义(挂死即失败而非挂起)不变。
//   2. **只对自己 fork 出来的进程组发信号**:所有断言都用具体的 pid / pgid(kill(pid,0)、kill(-pgid,0)),
//      绝不出现宽泛的 pkill 模式。

import Foundation
import Darwin
import Testing
import AAAgentCore
import AAAgentSystem

@Suite("agent 06 真进程组与反孤儿 —— SYSTEMPORT_TESTS passed=(逐条 @Test)")
struct SystemAgentPortTests {

    /// 被测 sleep 的唯一时长:check.sh 用 `pgrep -f "sleep 87137"` 核验零残留而不误伤用户进程。
    private static let markerSleep = "87137"
    /// 子进程环境(刻意只给最小 PATH:证明端口如实传 spec.environment、不隐式继承宿主环境)。
    private static let childPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    // ============ ① 拉起并逐行读 ============

    @Test("SystemAgentPort:真子进程 stdout 逐行读出,EOF 后 nextEvent 恒为 nil(不重放、不阻塞)")
    func launchAndReadLines() throws {
        try Self.withWatchdog("①逐行读") {
            let port = SystemAgentPort()
            let h = try Self.launch(port, "echo a; echo b", "①逐行读")
            defer { port.terminate(h); port.reclaim(h) }
            #expect(port.nextEvent(h) == "a", "SystemAgentPort:真子进程 stdout 逐行读出第 1 行 a")
            #expect(port.nextEvent(h) == "b", "SystemAgentPort:真子进程 stdout 逐行读出第 2 行 b")
            #expect(port.nextEvent(h) == nil, "SystemAgentPort:stdout 到达 EOF 后 nextEvent 返回 nil")
            #expect(port.nextEvent(h) == nil, "SystemAgentPort:EOF 之后再读恒为 nil(不重放、不阻塞)")
        }
    }

    // ============ ① EOF 前没有换行的尾行 ============

    /// agent 被杀在半行上时,那半截就是唯一现场:实现承诺「EOF 时把剩余不完整尾行(若非空)返回一次」。
    @Test("SystemAgentPort:EOF 前没有换行的尾行被交回一次(半截行是唯一现场,不许吞掉)")
    func unterminatedTailLine() throws {
        try Self.withWatchdog("①尾行") {
            let port = SystemAgentPort()
            let h = try Self.launch(port, "printf x", "①尾行")
            defer { port.terminate(h); port.reclaim(h) }
            #expect(port.nextEvent(h) == "x",
                    "SystemAgentPort:EOF 前没有换行的尾行被交回一次(半截行是唯一现场,不许吞掉)")
            #expect(port.nextEvent(h) == nil,
                    "SystemAgentPort:不完整尾行只交回一次,之后恒为 nil(不重放)")
        }
    }

    // ============ ① 进程中途自退被感知 ============

    @Test("SystemAgentPort:进程中途自退后 isAlive 为假(探活基于真 pid,不靠猜)")
    func selfExitDetected() throws {
        try Self.withWatchdog("①自退") {
            let port = SystemAgentPort()
            let h = try Self.launch(port, "exit 0", "①自退")
            defer { port.reclaim(h) }
            #expect(port.nextEvent(h) == nil, "SystemAgentPort:自退进程无输出时 nextEvent 读到 EOF 返回 nil")
            #expect(Self.waitUntil(5) { !port.isAlive(h) },
                    "SystemAgentPort:进程中途自退后 isAlive 为假(探活基于真 pid,不靠猜)")
            port.terminate(h)
            #expect(port.exitCode(h) == 0, "SystemAgentPort:正常退出的进程收尸后退出码为 0")
        }
    }

    // ============ ② nextEvent 阻塞语义(01 票 CR 的硬要求)============

    @Test("SystemAgentPort:进程活着但暂无输出时 nextEvent 阻塞到有整行(绝不返回 nil)")
    func blockingSemantics() throws {
        try Self.withWatchdog("②阻塞语义") {
            let port = SystemAgentPort()
            let h = try Self.launch(port, "sleep 1; echo late", "②阻塞语义")
            defer { port.terminate(h); port.reclaim(h) }
            let t0 = Date()
            let first = port.nextEvent(h)
            let elapsed = Date().timeIntervalSince(t0)
            #expect(first == "late",
                    "SystemAgentPort:进程活着但暂无输出时 nextEvent 阻塞到有整行(第一次调用就拿到 late,绝不返回 nil)")
            #expect(elapsed >= 0.5,
                    "SystemAgentPort:该次 nextEvent 确实阻塞等待了(耗时不小于 0.5 秒,不是恰好碰上有数据)")
            #expect(port.nextEvent(h) == nil, "SystemAgentPort:阻塞读出末行后进程退出,再读为 nil(EOF 才是 nil)")
        }
    }

    // ============ ③ terminate 连带杀子进程树(票面最核心)============

    @Test("SystemAgentPort:terminate 后整个进程组零残留(kill(-pgid,0) 得 ESRCH)")
    func terminateKillsProcessGroup() throws {
        try Self.withWatchdog("③进程组") {
            let port = SystemAgentPort()
            // 脚本:先后台派生一个孙进程(打印其 pid),再打印自己的 pid,最后自己也挂在一个长 sleep 上。
            let script = "sleep \(Self.markerSleep) & echo $!; echo $$; sleep \(Self.markerSleep)"
            let h = try Self.launch(port, script, "③进程组")
            defer { port.terminate(h); port.reclaim(h) }

            guard let bgLine = port.nextEvent(h), let shLine = port.nextEvent(h),
                  let grandchild = pid_t(bgLine), let leaderPID = pid_t(shLine) else {
                Issue.record("SystemAgentPort:③用例应能读到孙进程 pid 与子进程自身 pid"); return
            }
            let pgid = port.processGroupIdentifier(h) ?? 0

            // 进程组本身必须真建起来 —— 否则 kill(-pgid, …) 会把宿主自己一起杀掉。
            #expect(port.ownsProcessGroup(h),
                    "SystemAgentPort:子进程自成进程组组长(POSIX_SPAWN_SETPGROUP 真生效,不是继承宿主的组)")
            #expect(pgid == leaderPID,
                    "SystemAgentPort:进程组 id 等于子进程自己的 pid(组长就是它,kill(-pgid) 够得着整棵子树)")
            #expect(pgid != getpgrp(),
                    "SystemAgentPort:子进程组绝不等于宿主进程组(若相等,按组发信号会把宿主自己杀掉)")
            #expect(getpgid(grandchild) == pgid,
                    "SystemAgentPort:agent 派生的孙进程与它同组(所以一刀能连带收拾)")
            // 反证:杀之前它们确实活着,下面那条断言不是空跑。
            #expect(!Self.pidGone(grandchild), "SystemAgentPort:terminate 之前派生的孙进程确实活着(反证下一条不是空跑)")
            #expect(port.isAlive(h), "SystemAgentPort:terminate 之前 isAlive 为真")

            port.terminate(h)

            #expect(Self.waitUntil(5) { Self.pidGone(grandchild) },
                    "SystemAgentPort:terminate 连带杀掉 agent 派生的孙进程(进程组终止,不留孤儿)")
            #expect(Self.waitUntil(5) { Self.processGroupGone(pgid) },
                    "SystemAgentPort:terminate 后整个进程组零残留(kill(-pgid,0) 得 ESRCH)")
            #expect(!port.isAlive(h), "SystemAgentPort:terminate 后 isAlive 为假")
            #expect((port.exitCode(h) ?? 0) < 0,
                    "SystemAgentPort:被信号终止的进程退出码为负(与 04 票『负值即被信号杀』口径一致)")
            // 取消之后仍能把管道读到底(Claude 被中断后会先补 [Request interrupted] 再落终态才退出)。
            #expect(port.nextEvent(h) == nil,
                    "SystemAgentPort:terminate 之后管道仍可读到底再 EOF(取消后 drain 的前提)")
        }
    }

    // ============ ③b 并发收尸不得把「被信号杀」篡改成「成功」 ============

    /// 记账层(纯内存,不碰进程):ECHILD 分支必须交 nil 而不是初值 0,且首写生效。
    @Test("SystemAgentPort:收尸记账 ECHILD 时退出码保持 nil(fail-closed,取消绝不被记成成功)")
    func reapAccounting() {
        let p = SystemAgentPort.reapAccountingProbe()
        #expect(p.echild == nil,
                "SystemAgentPort:收尸拿不到状态(ECHILD)时退出码保持 nil 而不是 0(fail-closed,取消绝不被记成成功)")
        #expect(p.real == -Int32(SIGTERM) && p.afterNil == p.real,
                "SystemAgentPort:已收尸的记账再次 markReaped(nil) 不改写已有退出状态(首写生效,后到的 nil 抹不掉 -15)")
    }

    /// 端到端:两个线程同时 terminate 同一个句柄。无论谁先抢到收尸,退出码都**绝不能是 0**。
    @Test("SystemAgentPort:并发 terminate 后退出码绝不是 0(负值或 nil,一次取消不会被篡改成成功)")
    func concurrentTerminateExitCode() throws {
        try Self.withWatchdog("③b并发取消") {
            let port = SystemAgentPort()
            let h = try Self.launch(port, "sleep \(Self.markerSleep)", "③b并发取消")
            defer { port.reclaim(h) }
            let lock = NSLock()
            nonisolated(unsafe) var finished = 0
            for _ in 0..<2 {
                let t = Thread {
                    port.terminate(h)
                    lock.lock(); finished += 1; lock.unlock()
                }
                t.name = "SystemAgentPortTests.concurrent-terminate"
                t.start()
            }
            let bothDone = Self.waitUntil(20) { lock.lock(); let f = finished; lock.unlock(); return f == 2 }
            #expect(bothDone, "SystemAgentPort:两个线程并发 terminate 同一句柄都能返回(不自锁、不互相挡死)")
            let code = port.exitCode(h)
            #expect(code == nil || code! < 0,
                    "SystemAgentPort:并发 terminate 后退出码绝不是 0(负值或 nil,一次取消不会被篡改成成功)")
            #expect(Self.waitUntil(5) { Self.processGroupGone(port.processGroupIdentifier(h) ?? 0) },
                    "SystemAgentPort:并发 terminate 之后进程组同样零残留")
        }
    }

    // ============ ④ stdin 两种处置 ============

    @Test("SystemAgentPort:stdin 两种处置(devNull 立刻 EOF / writeThenKeepOpen 后显式 closeStdin 收尾)")
    func stdinDispositions() throws {
        try Self.withWatchdog("④stdin") {
            let port = SystemAgentPort()

            // (a) devNull:Codex exec 若不给 stdin 会静默挂起(02 spike 实证)。cat 必须立刻收到 EOF。
            let h = try Self.launch(port, "cat; echo done", "④devNull", stdin: .devNull)
            do {
                defer { port.terminate(h); port.reclaim(h) }
                #expect(port.nextEvent(h) == "done",
                        "SystemAgentPort:stdin 接 /dev/null 时 cat 立刻读到 EOF 不挂起(读出 done)")
            }

            // (b) writeThenKeepOpen:写一行后**保持写端打开**,进程不自退;由适配层显式 closeStdin 收尾。
            let h2 = try Self.launch(port, "cat", "④keepOpen", stdin: .writeThenKeepOpen("hello"))
            defer { port.terminate(h2); port.reclaim(h2) }
            #expect(port.nextEvent(h2) == "hello",
                    "SystemAgentPort:writeThenKeepOpen 写入的一行被子进程读到并回显(hello)")
            #expect(port.isAlive(h2),
                    "SystemAgentPort:写完后 stdin 写端保持打开,子进程不自退(Claude stream-json 形态)")
            port.closeStdin(h2)
            #expect(port.nextEvent(h2) == nil,
                    "SystemAgentPort:显式 closeStdin 后子进程收到 EOF 退出,读流随之 EOF(收尾路径可用)")
            #expect(Self.waitUntil(5) { !port.isAlive(h2) },
                    "SystemAgentPort:closeStdin 之后进程确实退出(两种 stdin 处置行为相反,都被覆盖)")
        }
    }

    // ============ ⑤ 幂等与错误路径 ============

    @Test("SystemAgentPort:terminate / reclaim 幂等,未知句柄安全 no-op,launch 失败抛错不崩")
    func idempotenceAndFailures() throws {
        try Self.withWatchdog("⑤幂等") {
            let port = SystemAgentPort()

            // terminate 幂等:同一句柄两次。
            let h = try Self.launch(port, "sleep \(Self.markerSleep)", "⑤幂等")
            let pgid = port.processGroupIdentifier(h) ?? 0
            port.terminate(h)
            port.terminate(h)
            #expect(Bool(true), "SystemAgentPort:同一句柄 terminate 两次不崩不抛(幂等)")
            #expect(!port.isAlive(h), "SystemAgentPort:两次 terminate 之后 isAlive 仍为假")
            #expect(Self.waitUntil(5) { Self.processGroupGone(pgid) },
                    "SystemAgentPort:重复 terminate 之后进程组依然零残留")
            port.reclaim(h)
            #expect(!port.isAlive(h), "SystemAgentPort:reclaim 之后句柄语义不变(isAlive 为假)")
            #expect(port.nextEvent(h) == nil, "SystemAgentPort:reclaim 之后 nextEvent 为 nil(不阻塞)")

            // 未知句柄:三个方法都安全 no-op。
            let unknown = AgentProcessHandle(id: 999_999_999)
            port.terminate(unknown)
            #expect(Bool(true), "SystemAgentPort:未知句柄 terminate 为 no-op(不崩不抛)")
            #expect(port.nextEvent(unknown) == nil, "SystemAgentPort:未知句柄 nextEvent 返回 nil(不阻塞、不崩)")
            #expect(!port.isAlive(unknown), "SystemAgentPort:未知句柄 isAlive 为假")

            // launch 失败:可执行不存在 → 抛错(不是崩)。
            var threw = false
            do {
                _ = try port.launch(Self.spec("/nonexistent/aa-agent-no-such-binary", ["-c", "echo x"]))
            } catch { threw = true }
            #expect(threw, "SystemAgentPort:可执行路径不存在时 launch 抛错(不崩、不返回坏句柄)")

            // launch 失败:工作目录不存在 → 抛错(绝不静默拉起到别的目录去干活)。
            var threwCWD = false
            do {
                _ = try port.launch(Self.spec("/bin/sh", ["-c", "echo x"], cwd: "/nonexistent/aa-agent-no-such-dir"))
            } catch { threwCWD = true }
            #expect(threwCWD, "SystemAgentPort:工作目录不存在时 launch 抛错(绝不静默换个目录干活)")
        }
    }

    // ============ ⑥ 启动规格如实生效 + stderr 不阻塞 ============

    @Test("SystemAgentPort:spec.environment / spec.workingDirectory 如实生效(每任务独立 CODEX_HOME 的前提)")
    func specFidelity() {
        Self.withWatchdog("⑥spec") {
            let port = SystemAgentPort()
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
                environment: ["PATH": Self.childPATH, "AA_AGENT_PROBE": "probe-value"],
                workingDirectory: dir,
                stdin: .devNull
            )
            if let h = try? port.launch(s) {
                defer { port.terminate(h); port.reclaim(h) }
                #expect(port.nextEvent(h) == "probe-value",
                        "SystemAgentPort:spec.environment 如实传给子进程(每任务独立 CODEX_HOME 的前提)")
                #expect(port.nextEvent(h) == resolved,
                        "SystemAgentPort:spec.workingDirectory 生效(子进程 pwd 即委托指定的工作目录)")
            } else {
                Issue.record("SystemAgentPort:⑥用例应能拉起 /bin/sh")
            }
        }
    }

    @Test("SystemAgentPort:子进程向 stderr 灌 100KB 以上也不被管道缓冲卡死(stderr 由专线排干)")
    func stderrIsDrained() throws {
        try Self.withWatchdog("⑥stderr") {
            let port = SystemAgentPort()
            let h = try Self.launch(port, "yes aa-stderr-noise | head -n 10000 >&2; echo ok", "⑥stderr")
            defer { port.terminate(h); port.reclaim(h) }
            #expect(port.nextEvent(h) == "ok",
                    "SystemAgentPort:子进程向 stderr 灌 100KB 以上也不被管道缓冲卡死(stderr 由专线排干)")
            #expect(Self.waitUntil(5) { port.drainedStderr(h).contains("aa-stderr-noise") },
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

    /// 拉起一段 shell 脚本;失败时抛出(绝不让后续断言在坏句柄上空跑)。
    private static func launch(_ port: SystemAgentPort, _ script: String, _ tag: String,
                               stdin: AgentStdinDisposition = .devNull,
                               sourceLocation: SourceLocation = #_sourceLocation) throws -> AgentProcessHandle {
        do { return try port.launch(spec("/bin/sh", ["-c", script], stdin: stdin)) }
        catch {
            Issue.record("SystemAgentPort:\(tag) 用例应能拉起 /bin/sh(实际抛错:\(error))", sourceLocation: sourceLocation)
            throw error
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

    // ---- 逐用例看门狗:任何一处读流意外阻塞都让门禁**失败**而不是挂死 ----

    private final class FinishedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func markDone() { lock.lock(); value = true; lock.unlock() }
    }

    private static func withWatchdog<T>(_ tag: String, _ seconds: Double = 60,
                                        _ body: () throws -> T) rethrows -> T {
        let box = FinishedBox()
        let t = Thread {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if box.isDone { return }
                usleep(200_000)
            }
            if !box.isDone {
                print("FAIL: SystemAgentPort 用例「\(tag)」超时(\(Int(seconds)) 秒)—— 某处读流阻塞未解")
                print("SYSTEMPORT_TESTS passed=0 failed=1")
                fflush(stdout)
                // exit 会触发端口的 atexit 反孤儿钩子,自己拉起的进程组随之被 SIGKILL,不留给用户机器。
                exit(9)
            }
        }
        t.name = "SystemAgentPortTests.watchdog"
        t.start()
        defer { box.markDone() }
        return try body()
    }
}
