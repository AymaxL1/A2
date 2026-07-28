# 02 — Claude adapter:stream-json 归一化(喂 spike 黄金样本)

**What to build:** 平台能把 Claude Code headless 的原生 `stream-json` 事件流翻译成 6 型统一消息。这是一个纯函数 adapter,直接用 01 spike 落盘的真实 NDJSON 样本当测试向量断言归一化结果,并把 Claude 侧的终态判定与「操作被拒」信号收敛成平台统一形态。

**Blocked by:** 01(需 6 型消息模型)。

**Status:** ready-for-agent
**验证环:** vfsoverlay 可验(纯函数 + 静态样本,无需真 agent)。

- [ ] `ClaudeAdapter` 纯函数 `(原始行) -> [统一消息]`:处理 5 型顶层事件(`system/rate_limit_event/assistant/user/result`),把 `assistant.message.content[]` 子块(text/thinking/tool_use)与 **`type:"user"` 承载的 tool_result**(附 `tool_use_result`)各归一化到对应型;`tool_use.id` → 统一消息 `callID`。
- [ ] 终态判定:联合 `is_error`/`terminal_reason`/`api_error_status` 收敛为统一终态枚举(**不能只看 `subtype`**——model 错时 exit 1 但 subtype 仍 success)。
- [ ] 「操作被拒」:把 `is_error:true` 的 tool_result + `permission_denials[]` 归一化成统一的「操作被拒」status 消息。
- [ ] `control_request`:收到未知双向消息记日志不崩(V1 不实现应答,仅兜底)。
- [ ] 测试喂 `research/spike-claude-headless/*.stdout.ndjson` 真实样本:至少覆盖 baseline 只读、tool-use、越界写、中断、invalid-model 五个样本,断言消息序列与终态;三处不对称中 Claude 侧(被拒信号可识别、终态多字段)各配针对性断言。
