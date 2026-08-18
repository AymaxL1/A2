# launchd 子进程生命周期：mihomo 作为 a2 daemon 直接子进程的死亡语义

> 调研日期：2026-08-18（对应票：`.scratch/mihomo-embedded/issues/03-launchd-child-lifecycle.md`）
> 背景：项目决定把 mihomo 从独立 launchd unit 改为 a2 daemon 的直接子进程；a2 daemon 本身是 launchd user agent `com.a2.kernel`（KeepAlive.Crashed + RunAtLoad）。目标不变量：**「a2 死 mihomo 也死、不留孤儿、不双跑」**。
> 资料原则：一手信源 = 本机 man page（`launchd.plist(5)`、`launchctl(1)`，macOS 15 / Darwin 24.6.0）、Apple TN2083《Daemons and Agents》、Daemons and Services Programming Guide、Apple 历史 launchd 源码（launchd-842.92.1，10.9.5——**launchd 自 10.10 起闭源，源码只证历史行为，凡引必标**）、XNU 源码；全部关键论断另做本机实验佐证。实验用一次性 label `com.a2research.*` + 无害命令（`/bin/sleep`、trap 脚本）模拟子进程，结束后已全部 bootout + 清理并验证无孤儿；全程未触碰 `com.a2.*` 与用户自装的 `io.metacubex.mihomo`（pid 553）。

## 0. 结论摘要

1. **launchd 给每个 job 一个独立进程组**（实测七次 spawn，pgid 一律 == 主进程 pid，ppid=1；历史源码 `job_setup_attributes()` 里 `setpgid(0,0)`/`setsid()` 佐证）。job 死亡时——**四种死法（正常 exit 0 / SIGSEGV / SIGKILL / `launchctl bootout`）全部实测**——launchd 默认对该进程组做垃圾回收。`AbandonProcessGroup` 默认 false = 默认回收；置 true 才放过。
2. **但回收手段是可捕获的 SIGTERM，不是必杀。** TN2083 原文："*when a launchd daemon or agent quits, launchd will send a SIGTERM to the associated process group*"，且措辞是尽力而为（"works to garbage collect"）；历史源码 `job_reap()` 即 `killpg2(j->p, SIGTERM)`。**本机实测证实现代行为一致**：忽略 SIGTERM 的同组子进程在父进程被 SIGKILL 后**存活**；不处理 SIGTERM 的子进程（如 /bin/sleep）四种死法下全部被清。
3. 因此 **「a2 死 mihomo 也死」在 mihomo 行为正常时由 launchd 免费保证**——mihomo 上游收 SIGTERM 即优雅退出（main.go，无 daemonize/fork/单实例锁）；Bun.spawn 无 detached/进程组口子（02 票 spike，`kernel/src/plugin/spawn.ts` 纪律③），子进程天然在组内。**保证的洞在「卡死的 mihomo」**：若它 hang 到不处理信号，SIGTERM 收尸对它无效 → 必须靠 pid 落盘 + 启动认尸（§5 层4）补成硬保证。
4. **孤儿/双跑的产生路径就两条：子进程脱组（setsid / AbandonProcessGroup=true），或子进程无视 SIGTERM。** 实测：脱组子进程四种死法下全部存活、reparent 到 pid 1（XNU `kern_exit.c` 的 `REAP_REPARENTED_TO_INIT` 佐证）；KeepAlive 重拉的新实例有全新进程组，旧孤儿永远无人再管——**双跑实锤**。反之同组、不抗拒 SIGTERM 的子进程实测无一存活，且清理先于重拉，无双跑。
5. **KeepAlive.Crashed 有洞：SIGKILL 不算 crash，不重拉。** 实测 SIGSEGV 后约 30 秒重拉；SIGKILL 后 job 停在 `state = not running`（`launchctl list` 记 `-9`），4 分钟以上无动作。man 对 Crashed 的定义只覆盖 "*a signal which is typically associated with a crash (SIGILL, SIGSEGV, etc.)*"；历史源码的崩溃信号清单为 SIGILL/SIGABRT/SIGFPE/SIGBUS/SIGSEGV/SIGSYS/SIGTRAP，明确不含 SIGKILL。内存压力（jetsam）杀进程用的正是 SIGKILL——当前 `com.a2.kernel` 配置下 a2 被 `kill -9` 后**不会自愈**。实测 `KeepAlive={SuccessfulExit:false}` 可补此洞（SIGKILL 后约 30 秒重拉）。
6. 编排建议（详见 §5）：plist 保持默认组回收 + KeepAlive 加 `SuccessfulExit:false`；spawn 用 Bun.spawn 默认（同组）；SIGTERM 退出钩子里先优雅收 mihomo、超时 SIGKILL；mihomo pid+启动时间落盘、新 daemon 启动时认尸——四层合起来把三条不变量从「通常成立」补成「硬成立」。

## 1. 问题一：四种死法下子进程的命运（实测矩阵）

实验形态：launchd job 主进程为 bash 脚本，spawn 两只 `/bin/sleep 600`——一只留在 job 进程组（模拟 Bun.spawn 直接子进程 = mihomo），一只经 perl `POSIX::setsid()` 脱组（模拟最坏情况孤儿）。另做一只 `trap "" TERM` 的同组子进程验证清理信号性质。逐场景记录 pid/pgid/ppid，触发死法、验尸。

| 死法 | job 主进程 | 同组子进程（默认信号处置） | 同组但忽略 SIGTERM | 脱组子进程 | job 之后 |
|---|---|---|---|---|---|
| `launchctl bootout` | 死（SIGTERM 路径） | **被清** | （未测该组合） | **存活**，ppid→1 | 卸载，无重拉 |
| SIGSEGV（崩溃） | 死 | **被清** | — | **存活** | `Crashed:true` → 约 30s 重拉 |
| SIGKILL | 死 | **被清** | **存活**，ppid→1 | **存活** | `Crashed:true` → **不重拉**；`SuccessfulExit:false` → 约 30s 重拉 |
| 正常 `exit 0` | 死 | **被清** | — | 存活（前提 setsid 已完成，见下注） | `Crashed:true` → 不重拉（符合语义） |

- 「被清」的机制：对进程组发**可捕获的 SIGTERM**（见 §2）。/bin/sleep 对 SIGTERM 是默认处置（终止），故死；trap 掉 SIGTERM 的子进程活。
- 竞态注脚：主进程 spawn 完立刻 `exit 0` 的变体里，perl 还没来得及执行 setsid 就被组回收扫掉（state 文件里它仍在原组）；延迟 1 秒再退出，脱组完成后即存活。说明回收在 job 死亡瞬间执行、窗口极小，但 setsid 完成之后 fork 的进程确实逃得掉。

关键原始数据（压缩）：

```
bootout 场景:
  spawn:  PID 32476 PGID 32476 PPID 1  bash parent.sh   ← pgid==pid,launchd 给了独立进程组
          PID 32481 PGID 32476          sleep(同组)
          PID 32482 PGID 32482          sleep(setsid 后)
  bootout 后 1s:  32476 无 32481 无(组回收);32482 PPID 1 存活(脱组孤儿)

trap SIGTERM 场景:
  spawn:  PID 33704 PGID 33704 PPID 1  parent2.sh
          PID 33709 PGID 33704          bash -c 'trap "" TERM; while :; do sleep 300; done'
  kill -9 33704 后 3s:  33709 PGID 33704 PPID 1 存活   ← 同组也没死:清理信号是 SIGTERM
```

## 2. 问题二：launchd 是否清理进程组 / `AbandonProcessGroup`

- **清理，且这是默认行为；但手段是 SIGTERM。** 三级证据链：
  - 本机 `man launchd.plist`（launchd.plist(5)）原文（未提信号种类）：
    > *AbandonProcessGroup \<boolean\>*
    > *When a job dies, launchd kills any remaining processes with the same process group ID as the job. Setting this key to true disables that behavior.*
  - TN2083《Daemons and Agents》"Careful With That Fork, Eugene" 一节（Apple 官方，点名信号）：*"Starting in Mac OS X 10.5 launchd works to garbage collect any child processes of a launchd daemon or agent process when that process quits. Specifically, when a launchd daemon or agent quits, launchd will send a SIGTERM to the associated process group."*
  - 历史源码（launchd-842.92.1，`core.c` `job_reap()`，**仅证历史**）：注释 *"The job is dead. While the PID/PGID is still known to be valid, try to kill abandoned descendant processes."* → `if (!j->abandon_pg) killpg2(j->p, SIGTERM)`——在**每一条**收尸路径上执行，与死法无关。
  - 本机实测（§1 trap 场景）证实 **macOS 15 仍是 SIGTERM**：忽略 SIGTERM 的同组子进程存活。
- man 措辞 "when a job dies"、TN2083 措辞 "quits" 均不区分死法；实测四种死法全部触发回收。（外网流传「bootout 对组 SIGKILL、crash 不清组」之类说法无任何 Apple 一手信源支持，与本机实测也不符，弃。）
- **job 拥有独立进程组**：man EXPECTATIONS 一节把 `setsid(2)` 列为 "launchd can perform them on the process' behalf" 的初始化项；历史源码 `job_setup_attributes()`（仅证历史）：*"We'd like to call setsid() unconditionally … We'll settle for process-groups."* → `getppid() != 1 ? setpgid(0,0) : setsid()`；本机实测所有 spawn pgid == pid。打击面恰好是「job 主进程 + 未脱组子孙」，不波及别人。
- **停止（bootout）时对 job 主进程的信号序列**：`ExitTimeOut` 键（man）：*"The amount of time launchd waits between sending the SIGTERM signal and before sending a SIGKILL signal when the job is to be stopped. The default value is system-defined."*（历史源码默认 20s，`LAUNCHD_DEFAULT_EXIT_TIMEOUT`；现代默认值无一手信源，UNCONFIRMED）。注意两点：① 这条 SIGTERM→SIGKILL 升级只针对 **job 主进程 pid**，历史源码里超时 `job_kill()` 是 `kill2(j->p, SIGKILL)` 不打进程组——进程组只吃那记 SIGTERM；② `EnableTransactions` 段（man + Apple DTS Quinn 2024 论坛答复佐证）："*If the process is inactive, SIGKILL is sent immediately*"——但 a2 未 opt 进 XPC transactions，走普通 SIGTERM 路径（实测 bootout 时 bash 主进程收 SIGTERM 即死）。

## 3. 问题三：KeepAlive 重拉后的孤儿双跑

- **会，当且仅当旧子进程逃过了那记组 SIGTERM**（脱组，或无视 SIGTERM）。实测时间线（`KeepAlive={Crashed:true}`）：
  - 22:12:27 spawn（parent 32622，同组 sleep 32627，脱组 sleep 32628）
  - 22:12:29 对 parent 发 SIGSEGV → 32627 被清，**32628 存活**
  - 22:12:57 launchd 重拉（约 30 秒；man `ThrottleInterval` 称默认 "not … more than once every 10 seconds"，本机实测节流约 30s，以实测为准）→ 新 parent 32641 + 新子进程
  - 此刻 32628（旧）与新实例的对应子进程**并存**——若这是 mihomo，即端口抢占/双跑。
- 孤儿的归宿：reparent 到 pid 1（XNU `bsd/kern/kern_exit.c` 现行源码 `REAP_REPARENTED_TO_INIT` 注释佐证），对 launchd 只是匿名进程；新实例拿到全新 pid 和**全新进程组**，旧孤儿不在其中，之后任何一次收尸都不会再碰它——孤儿可无限期与新实例并跑。
- **同组、不抗拒 SIGTERM 的子进程不会双跑**：它在旧 job 死亡瞬间已被清，先于重拉。
- **KeepAlive.Crashed 的重拉边界**（man + 历史源码 + 实测）：SIGSEGV 重拉；SIGKILL **不**重拉（`launchctl list` 最后退出状态 `-9`、`state = not running`，观察 4 分钟无动作；历史源码崩溃清单 SIGILL/SIGABRT/SIGFPE/SIGBUS/SIGSEGV/SIGSYS/SIGTRAP 不含 SIGKILL，现代清单 UNCONFIRMED 但实测口径一致）；正常 exit 0 不重拉。`KeepAlive` 字典多键为 OR 语义（man："If multiple keys are provided, launchd ORs them"），实测补 `SuccessfulExit:false` 后 SIGKILL 也在约 30 秒内重拉（新 pid 33353）。

## 4. 对 a2 ← mihomo 形态的推演

把 §1–3 的事实套到真实栈上：

1. **Bun.spawn 直接子进程 = 同组子进程。** Bun.spawn 没有 detached/进程组参数（02 票 spike 实测、`kernel/src/plugin/spawn.ts` 纪律③写明），mihomo 必然留在 a2 daemon 的进程组里。
2. **mihomo 不会自己脱组，且对 SIGTERM 的处置正是我们要的。** 上游 main.go 无 daemonize/fork/setsid，前台运行，SIGINT/SIGTERM → 退出，无单实例锁（`docs/research/mihomo-integration.md` §2，一手来源 mihomo main.go）。TN2083/Daemons Guide 反复强调 launchd job 本身不得 daemonize——a2 已满足；这里的引申义是**也别给 mihomo 套任何 daemonize 包装**。
3. 于是三条不变量在「mihomo 行为正常」的世界里由 launchd 组 SIGTERM 直接成立。**剩下的洞全是异常世界的**：mihomo 卡死到不处理 SIGTERM（§1 trap 实验证明这种进程能活下来）、mihomo 将来引入自脱组行为（升级流程盯上游 changelog）、死亡瞬间竞态（窗口极小）。这些统一由 §5 层4（认尸）兜底。
4. 诚实备注：TN2083 对「daemon 带子进程」给的首选项其实是 *"run the 'child' via launchd — everything will Just Work™"*，即 mihomo 独立 unit——正是项目刚决定放弃的形态（放弃理由在票面：编排/装卸复杂度）。改为直接子进程后，Apple 语义下我们落在它的第二档（同组 + 默认回收），代价就是上面这几个要自己兜的洞。

## 5. 编排建议（答问题四）

四层防线，从「免费」到「兜底」：

1. **plist 层**：`com.a2.kernel` **不设** `AbandonProcessGroup`（默认 false 即组回收；也可显式写 `<false/>` 防将来手滑）。`KeepAlive` 从 `{Crashed:true}` 改为 `{Crashed:true, SuccessfulExit:false}`（OR 语义）：否则 a2 被 `kill -9`（含 jetsam）后躺平不自愈——本次实测抓到的现役配置真实缺口。注意 `SuccessfulExit:false` 下**非零退出也会被重拉**，daemon 的「主动停止」路径必须保证 exit 0（bootout 路径不受影响，unit 直接卸载）。
2. **spawn 层**：Bun.spawn 默认参数起 mihomo，**绝不**包 setsid/daemonize/shell 包装层。mihomo 死了 a2 收 `proc.exited` 自行重拉（daemon 内部监督），与 launchd 层职责正交——launchd 只管 a2，a2 只管 mihomo。
3. **退出钩子层**：daemon 监听 SIGTERM（bootout / 登出走这条路，§2）：先对 mihomo 发 SIGTERM（上游优雅退出语义）→ 短超时（建议 ≤3s，留在 launchd ExitTimeOut 预算内）→ 未退则 **SIGKILL**（launchd 自己不会对组升级到 SIGKILL，§2——这一步只有 a2 能做）→ 自己 exit 0。这是唯一能让 mihomo 优雅收尾的路径；SIGKILL/SIGSEGV 死法下钩子不会跑，落到 launchd 组 SIGTERM + 层4。
4. **pid 记录 + 启动认尸层**（把「通常不留孤儿」补成「硬不留」的那一层）：daemon 把 mihomo 的 `pid + 启动时间 + 二进制路径` 落盘（数据目录内，非全局）；每次启动（含 KeepAlive 重拉）先读档：pid 存在 → 校验进程身份（命令行/路径 + 启动时间比对，防 pid 复用误杀）→ 确认是自己拉的 mihomo 即 SIGKILL（对付的就是无视 SIGTERM 的卡死实例，别再客气），再起新实例。认尸失败的兜底信号：mihomo 固定监听端口 / `-ext-ctl-unix` socket 被占导致新实例起不来时，把「端口被占 + 占用者是 mihomo」翻译成明确诊断而不是裸报错。

三条不变量的闭合论证：**a2 死 mihomo 也死** = launchd 组 SIGTERM（层1/2 保证在组内 + mihomo 正常处置 SIGTERM）∪ SIGTERM 钩子（层3，优雅路径）∪ 认尸（层4，卡死路径）；**不留孤儿** = 同上；**不双跑** = 组清理先于重拉（实测）+ 层4 启动先认尸再 spawn。

## 6. 实验记录（可复现）

- 环境：macOS 15（Darwin 24.6.0），gui/501 域；`launchctl bootstrap gui/501 <plist>` 装载，`launchctl bootout gui/501/<label>` 卸载。
- job 形态：`/bin/bash parent.sh <scenario>`，spawn `sleep 600 &`（同组）+ `perl -e 'POSIX::setsid(); exec "/bin/sleep","600"' &`（脱组），随后 `wait`（或按场景 `exit 0`）；trap 场景为 `bash -c 'trap "" TERM; while :; do sleep 300; done' &`。
- 六个一次性 label 及其变量：
  - `com.a2research.bootout`：无 KeepAlive → 验 bootout 组回收。
  - `com.a2research.abandon`：`AbandonProcessGroup=true` → 验放弃回收（两只子进程全存活）。
  - `com.a2research.crash`：`KeepAlive={Crashed:true}` → 验 SIGSEGV 重拉约 30s、双跑、SIGKILL 不重拉（`launchctl list` 状态 `-9`）。
  - `com.a2research.exit0` / `exit0slow`：正常退出（立即/延迟 1s）→ 验 exit 0 组回收 + setsid 竞态窗口。
  - `com.a2research.sekill`：`KeepAlive={SuccessfulExit:false}` → 验 SIGKILL 后重拉（约 30s，新 pid 33353）。
  - `com.a2research.trapterm`：同组子进程 `trap "" TERM` → 验清理信号为可捕获 SIGTERM（父 SIGKILL 后子存活）。
- 清理证明（全部完成后）：`launchctl list | grep a2research` 空；`ps` 无残留 sleep/trap 进程；用户 mihomo `pid 553` 全程在跑未受影响；实验脚本与 plist 均在临时目录，未入库。

## 信源清单

| 论断 | 信源 |
|---|---|
| 组回收默认行为 / `AbandonProcessGroup` 语义 | 本机 `man launchd.plist`（launchd.plist(5)）AbandonProcessGroup 段原文（§2 引用，与 keith.github.io/xcode-man-pages 镜像逐字一致）；实测四死法矩阵（§1） |
| 回收信号 = 可捕获 SIGTERM | TN2083《Daemons and Agents》"Careful With That Fork, Eugene"（developer.apple.com/library/archive/technotes/tn2083/）原文（§2 引用）；历史源码 launchd-842.92.1 `core.c` `job_reap()` `killpg2(SIGTERM)`（github.com/apple-oss-distributions/launchd，**仅证历史**）；本机 trapterm 实验（§1） |
| job 独立进程组 | man EXPECTATIONS 段（setsid 由 launchd 代办）；历史源码 `job_setup_attributes()` setpgid/setsid（仅证历史）；实测 pgid==pid（§1） |
| SIGTERM→SIGKILL 停止序列只打主进程 | man `ExitTimeOut`、`EnableTransactions` 段（§2 引用）；历史源码 `job_kill()` `kill2(j->p, SIGKILL)`（仅证历史）；Apple DTS Quinn 2024（developer.apple.com/forums/thread/725418，Apple 员工答复，非正式文档） |
| job 本身不得 daemonize | Daemons and Services Programming Guide "Creating Launch Daemons and Agents"（developer.apple.com/library/archive/…/CreatingLaunchdJobs.html）："You must not daemonize your process…" |
| `KeepAlive.Crashed` 只覆盖崩溃信号 / 字典键 OR 语义 | man `KeepAlive` 段原文；历史源码崩溃信号清单（不含 SIGKILL，仅证历史）；实测 SIGSEGV 重拉、SIGKILL 不重拉（§3） |
| 孤儿 reparent 到 pid 1 | XNU 现行源码 `bsd/kern/kern_exit.c` `REAP_REPARENTED_TO_INIT`（github.com/apple-oss-distributions/xnu）；实测 ppid→1（§1） |
| 节流（重拉延迟） | man `ThrottleInterval`（称默认 10s）；本机实测约 30s，以实测为准（§3） |
| mihomo 不自 daemonize、SIGTERM 优雅退出、无单实例锁 | `docs/research/mihomo-integration.md` §2（一手：mihomo main.go） |
| Bun.spawn 无 detached/进程组口子 | 02 票 spike 实测口径，`kernel/src/plugin/spawn.ts` 头注纪律③ |
| UNCONFIRMED 项 | 现代（10.10+ 闭源）launchd 的:ExitTimeOut 系统默认值、Crashed 崩溃信号精确清单、setsid/setpgid 具体机制——均以本机实测口径为准 |
