# 06 — SystemAgentPort 真实现(真进程 + 进程组 + 反孤儿)

**What to build:** AgentPort 的生产实现:真的用 Process 拉起一个子进程、逐行读取其 stdout 事件流、按处置管理 stdin、取消时进程组 SIGTERM→宽限→SIGKILL 连带杀子进程树、宿主异常退出兜底反孤儿。用普通 shell 命令(echo/sleep/自 fork 的脚本)验证进程组行为,不需要真 agent 也不需要 Xcode。

**Blocked by:** 01(AgentPort 协议)。

**Status:** ready-for-agent
**验证环:** vfsoverlay 可验(被测进程用 `/bin/sh`/`sleep` 等系统命令,验证进程组信号语义;非门禁的真 agent 冒烟留 07)。

- [ ] `SystemAgentPort` 实现 `AgentPort`:基于 `Process` 拉起,配置进程组(`setpgid` 等价),逐行读 stdout 成事件流;探活基于 pid。
- [ ] stdin 处置:支持「写入一行后保持打开由适配层显式关闭」(Claude stream-json)与「立即 `/dev/null`」(Codex exec)两种模式。
- [ ] 终止:进程组 SIGTERM → 宽限期 → SIGKILL,连带杀派生子进程树;样板 `SystemProcessPort` 的 atexit/SIGTERM/SIGINT/SIGHUP 反孤儿钩子,保证宿主退出必清子进程。
- [ ] 放哪归实施:随试驾 CLI target 或一薄桥接 target(碰 Process,不进 AAAgentCore 纯逻辑核;不碰 AAHostMacOS 守并行红线)。
- [ ] **`nextEvent` 阻塞语义必须钉死**(01 票 CR 备注):真实现里「进程活着但暂无输出」应**阻塞到有行或 EOF**,不能返回 nil——否则 05 票看门狗会把「暂无输出」误读为流终止。仅在 EOF/进程已死时返回 nil。协议 doc 已注「无更多/EOF/已死→nil」,真实现要落实"无更多≠暂无"。
- [ ] 测试:用 shell 命令当被测进程——拉起并读若干行输出一条、terminate 后 `ps` 无残留(含派生孙进程)一条、进程中途自退被 isAlive 感知一条。
