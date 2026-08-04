// AAAgentTestKit —— 反孤儿钩子的 E2E 探针(agent-delegation 06 票)。
//
// 17 票把 `SystemAgentPortTests` 的断言整体搬进了 `Tests/AAAgentTestKitTests/`(swift-testing),
//   **但这个探针留在 Sources/**:它不是断言,是 `registry-tests` 这个可执行的**唯一入口**,
//   由 `Scripts/check/agent-e2e.sh` 以 `AA_ORPHAN_PROBE=exit` / `=signal` 两种模式拉起。
//   SPM 的 executableTarget 不能依赖 testTarget,所以它必须住在库里 —— 这也是 `registry-tests` 与
//   `AAAgentTestKit` 两个 target 在 17 票之后仍然保留的全部理由。
//
// 在进程内无法断言「宿主死后子进程被回收」——那需要宿主真的死一次。故把这一步做成探针:
// 探针拉起一个自带孙进程的进程组、把 pgid 打给 check.sh,然后**不 terminate** 就让自己退出/被杀,
// 由 check.sh 在外面核验整组已被钩子 SIGKILL 干净(见 agent-e2e.sh 的两条反孤儿 E2E)。
//
// **两条反证**(没有它们,空进程组会让「零残留」永远为真 —— 探针自欺):
//   * exit 模式:探针退出前自证 `kill(-pgid, 0) == 0` 并打印 `ORPHAN_PROBE_ALIVE=1`,check.sh assert 之;
//   * signal 模式:check.sh 在**发 SIGTERM 之前**另做一次 `pgrep -g <pgid>` 非空断言。

import Foundation
import Darwin
import AAAgentCore
import AAAgentSystem

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
