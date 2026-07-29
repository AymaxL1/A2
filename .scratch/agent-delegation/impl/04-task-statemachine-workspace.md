# 04 — 任务状态机 + 工作区落盘(经 Fake Port)

**What to build:** 平台能把一次委托当作有生命周期的任务来管:创建任务工作区目录、驱动状态机 pending→running→终态、把统一消息流全量落盘、产出 HTML 报告、崩溃残留可识别。全部经 Fake Port 纯逻辑测,零真实 agent。这是 03 票工作区结构提案的代码化。

**Blocked by:** 01(需消息模型 + AgentPort);消费 02/03 产出的统一消息流,但对「统一消息」编程而非绑具体 adapter,故不 blocked by 02/03。

**Status:** ready-for-agent
**验证环:** vfsoverlay 可验(经 Fake FileSystem/Clock Port,静态断言落盘结构)。

- [ ] `AAContracts.AAPaths` 加 `agentTasksRoot`(`~/.aa/agent-tasks/`)静态常量作单一来源(与 `socketPath` 同款)。
- [ ] task-id 生成 `<YYYYMMDD-HHmm>-<slug>-<hex4>`(时间经 ClockPort 注入可测,slug 从 prompt 首句,hex4 随机)。
- [ ] 任务状态机:`pending/running/completed/failed/cancelled/timeout/orphaned` 的合法迁移;终态由消费的统一消息终态驱动。
- [ ] 工作区落盘(经 FileSystemPort):`meta.json`(单写者、`schema_version`、拿到 session id 即写)+ `prompt.md`(委托快照)+ `logs/{raw.ndjson, normalized.ndjson, stderr.log}`(**raw 与 normalized 永不互写**)+ `report.html` + 有副作用任务的 `changes.md`。
- [ ] HTML 报告:主路径认 agent 产出的自包含 `report.html`;缺失时兜底把最终文本 escape 套极简内置模板(**不做 md 渲染器**)。
- [ ] 崩溃残留:`state=running` 且 pid 已死 → 读操作扫到标 `orphaned`,不删证据。
- [ ] 测试经 Fake Port:喂一段预置统一消息流,断言状态迁移序列 + 落盘后的目录结构/meta 字段/raw≠normalized;orphaned 判定一条;HTML 兜底一条。

**约束(03 票 CR 回填的实测事实,状态机不得违背)**:
- **Codex 的 `item.*` 事件不保证被 turn 边界包住** —— exec6 样本里 `item.completed`(type=error,model 元数据缺失警告)出现在 `turn.started` **之前**;exec7 里 item error 又夹在回合中段的重连噪音之间。故状态机/看门狗**不得**假设「item 事件必在 turn.started 之后、终态行之前」,更不得拿 turn 边界当消息闸门丢弃 pre-turn 的 item(会丢诊断信息)。
- **Codex 中断/硬超时时事件流里没有终态行**(exec3/exec5 实证),adapter 会诚实交回 `terminal == nil`。此时 job 终态**必须**由进程退出码 + 是否收到取消意图决定(负退出码=被信号杀 → cancelled),绝不能因为「adapter 没给终态」就把任务挂在 running。
