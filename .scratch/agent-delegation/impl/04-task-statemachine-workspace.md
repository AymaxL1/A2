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
