# 07 — 试驾 CLI(aa-agent)收口 + 两家启动参数组装 + 端到端

**What to build:** 一个能真用的委托入口 `aa-agent`:`run` 组装委托(prompt/agent/model/workdir)、按 agent 选 adapter、经 SystemAgentPort 真拉起、落盘、判终态、出 HTML 报告;`status/cancel/list/prune` 管理任务。把前六票拼成端到端可跑的一刀,并真拉起 claude/codex 各跑一个最小任务做冒烟。这是本模块的旗舰验收面。

**Blocked by:** 02, 03, 04, 05, 06(要归一化 + 状态机 + 看门狗/取消 + 真 Port 全部就位)。

**Status:** ready-for-agent
**验证环:** CLI 解析/参数组装 vfsoverlay 可验;端到端冒烟需真 claude/codex(手动,非日常门禁)。

- [ ] `aa-agent` executable target(依赖 AAAgentCore + SystemAgentPort;**不碰现有 `aa`/AAHostMacOS**),`run|status|cancel|list|prune` 子命令 + 退出码复用 `AAContracts.AAExitCode`。
- [ ] Claude 启动参数组装:`-p --output-format stream-json --input-format stream-json` + **`--permission-mode bypassPermissions`(blocked-args 不可覆盖)** + 能力面收紧(`--strict-mcp-config` + 工具白名单) + `--model` 透传 + stdin 保持打开显式收尾。
- [ ] Codex 启动参数组装:`exec --json` + stdin `/dev/null` + `-s/--sandbox` 或 `-c sandbox_mode=` + **每任务独立 `$CODEX_HOME`(只拷 `auth.json` 不拷 `config.toml`,用完即弃)** + model 透传。
- [ ] `run` 完整链路:建工作区 → 拉起 → 归一化落盘 → 看门狗/可取消 → 终态 → report.html → 完成信息指向报告路径。
- [ ] `prune` 只删终态、永不删 running;`list` 显示条数 + 磁盘占用。
- [ ] CLI 解析与参数组装的 vfsoverlay 可验断言(不拉真进程);端到端冒烟脚本:真跑 claude 一个只读诊断任务 + codex 一个最小任务,断言终态与 report.html 产出(手动,标注真实配额消耗)。
- [ ] 旗舰验收辞点验(手动 ready-for-human):委托一次经 `aa demo.note.set` 的可逆改动零打断、一次经 `aa demo.wipe` 的 dangerous 改动触发宿主确认且拒绝分支能挡住。

**接线契约(04/05 票 CR 回填,拿不到这三条就会接错)**:
- [ ] **中断时 meta 必须保持 `running`,drain 完了才一次 `finish`**。若在发信号那一刻就把 meta 落成 `timeout`/`cancelled`,04 的终态冻结会让随后「drain 回读到 succeeded」的 `finish(.completed)` 抛 `illegalTransition` —— 05 那条「agent 恰好在信号落地前正常完成就报 completed」的豁免在盘上**永远兑现不了**。自洽的接线只有一种:meta 留在 `running`,drain 结束后用 `AgentInterruptPolicy.resolveIncludingTimeout` 算出终态、**一次** `finish`(`running → 任何终态`皆合法;中途崩溃留下的 `running` 由 04 的孤儿扫描 + 证据纠正边兜住)。
- [ ] **`timedOut` 旗标的语义是「`timeOut()` 真的执行过」,不是「verdict 曾判过 stalled」**。若在收尾时拿「当下 verdict」当 timedOut,用户取消后 drain 较慢的场景会把一次真实的用户取消误记成 timeout。
- [ ] **两套反孤儿钩子的合流是本票的硬前置(06 票 CR 定的归属)**:`AAHostMacOS.SystemProcessPort` 与 `AAAgentSystem.SystemAgentPort` 各自装 SIGTERM/SIGINT/SIGHUP handler,**后装的顶掉先装的**。06 已做单侧缓解(保存前手 + 链式调用),但 SystemProcessPort 那侧是**裸 `signal()` 不链式** —— 一旦本票让两者进同一进程且 SystemProcessPort **后**初始化,它杀完自己的 pid 就 `SIG_DFL + raise`,**agent 进程组整组漏杀**;而死于信号不跑 atexit,没有第二道网。这正是反孤儿铁律的破口。正解:给 SystemProcessPort 补对称的 save+chain(需并行红线解冻);**靠「保证谁先初始化」是最脆的纪律,不接受**。今天没有任何可执行同时链接两个 target(registry-tests 链 AAAgentSystem 不链 AAHostMacOS,aahost 反之),故 06 留债合理。
- [ ] **句柄生命周期顺序不可乱(06 票 CR 回填,这是正确性依赖不是卫生习惯)**:`drain 到 EOF` → **`terminate`(即使进程已自然退出也必须调)** → 取 `exitCode` → `reclaim`。理由:`terminate` 是**唯一的 waitpid 收尸处**,`exitCode` 只有收尸后才有值;漏掉它,Codex 那条「terminal 缺失时靠退出码分辨失败 vs 中断」的判据就退化成 fail-closed 的 `.failed`。`isAlive` 用 `waitid(WNOWAIT)` **故意不收尸**——没收尸的僵尸 leader 会把 pgid 钉死在内核里,防止 `kill(-pgid,…)` 落到被复用的别人组上。**先 `reclaim` 后 `terminate` 会把僵尸永久漏掉**(记账已删,terminate 变 no-op)。另:阻塞式 `nextEvent` 意味着读流与看门狗/取消必须是两个执行流;`drainToEOF` 在降级单杀或子进程 setsid 逃组时可能永不到 EOF,**drain 外层必须有界**。
- [ ] **别拿 Claude 的 exit 143 去凑「负值=被信号杀」的口径**:Claude 是**捕获** SIGTERM 后自 exit 143(正值,01 spike 第 6 题),不走负值分支;它靠的是 drain 回读的终态 + 取消记账。「负值=被信号杀」实际只对 Codex(无 SIGTERM handler)成立。
- [ ] **看门狗的现场信息必须落进 `meta.error`**:`stalled` 带的 `silentSeconds` / `toolInFlight` 是「为什么判它卡死」的唯一证据,目前没有专门的 meta 字段承载,不显式写就只活在内存里,用户看 `status` 只会看到一个光秃秃的 `timeout`。同理,被信号杀但非本平台发起时(OOM/外部 pkill),状态按 04 语义记 `cancelled`,但 `meta.error` 要如实记下「被信号 N 终止,非本平台发起」——**判定面收敛,诊断面如实**。
