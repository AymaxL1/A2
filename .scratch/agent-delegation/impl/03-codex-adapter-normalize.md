# 03 — Codex adapter:exec --json 归一化(喂 spike 黄金样本)

**What to build:** 平台能把 Codex `exec --json` 的扁平 NDJSON 事件流翻译成同一套 6 型统一消息,并抹平 Codex 与 Claude 在终态语义、被拒信号上的不对称。同样是纯函数 adapter,喂 02 spike 的真实样本断言。

**Blocked by:** 01(需 6 型消息模型)。

**Status:** ready-for-agent
**验证环:** vfsoverlay 可验(纯函数 + 静态样本,无需真 agent)。

- [ ] `CodexAdapter` 纯函数 `(原始行) -> [统一消息]`:处理 `thread.started/turn.started/item.started/item.completed/turn.completed/turn.failed` + 非终态 `error`;`item.*` 里的工具调用归一化并保留调用标识为 `callID`。
- [ ] session/thread id:从**首行 `thread.started.thread_id`** 提取并作为一等字段暴露给上层(供状态机写 meta)。
- [ ] 终态判定:成功 `turn.completed`(exit0)/失败 `turn.failed`(exit1,错因是**双层编码 JSON,需 parse 两层**)/中断(负信号号)收敛为统一终态枚举。
- [ ] 「操作被拒」的诚实处理:Codex 被拒调用连 `item.started` 都不出现(静默空气墙)——归一化层记录此限制,V1 不强行合成拒绝消息(spec 已承认此不对称)。
- [ ] stderr 噪音:`ERROR` 字样不作失败判据(alpha 构建旁路依赖噪音)。
- [ ] 测试喂 `research/spike-codex-exec/samples/*.stdout.jsonl` 真实样本:至少覆盖 baseline 只读、写尝试、read-only 越界、中断、invalid-model 五个样本,断言消息序列、session id 提取与终态;Codex 侧不对称(静默拒绝、双层编码错因)各配针对性断言。
