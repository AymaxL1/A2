---
status: accepted
date: 2026-07-28
---

# agent-first 交互方向：V1 不内嵌 Codex，CLI 为主交互面，dangerous 确认落宿主 GUI

2026-07-28 用户反转 agent 交互方向：V1 不做内嵌 Codex 的 Agent 插件（原调研文档 §7 整体撤出 V1），改为**先提供 CLI，让外部 agent（如 Codex）调用本应用**；GUI 是能力面之上的薄壳；dangerous 能力的最终确认必须发生在宿主 GUI。

## Context

- 方向反转是本效fort前提 4（[地图](../../.scratch/v1-mac-recharter/map.md) Notes，2026-07-28 用户确认）；示例场景：Codex 调用本应用设置 mihomo 代理。
- 事实基础见 [agent-first-interface.md](../research/agent-first-interface.md)（[05 票](../../.scratch/v1-mac-recharter/issues/05-agent-first-interface.md)）：官方无钦点唯一路径——CLI + AGENTS.md/skills 是零配置合法路径，MCP 是「repo 之外外部工具」的标准正门，plugin 可打包分发；Codex 侧审批可被用户配置整体关闭。
- 原调研文档 [platform-framework-research.md](../research/platform-framework-research.md)：§6（CLI 设计、CLI-vs-MCP 判断）保留并经 05 票强化，其中 CLI 由「官方适配器之一」升为 V1 主交互面；§7（内嵌 Codex：App Server/SDK 选型、AgentRuntime 设计）整体撤出 V1；§7.3 对过度抽象的告诫仍适用（见 Decision 第 6 条）。
- 撤出的连带影响：Swift 路线原最大逆风（官方 Codex SDK 无 Swift）从 V1 关键路径移除（[03 票](../../.scratch/v1-mac-recharter/issues/03-tech-stack-decision.md)、[ADR 0002](0002-swift-native-stack.md)）。

## Decision

1. **V1 不内嵌 Codex**：无应用内 agent 聊天/会话 UI；原文档 §7 整体撤出。将来若回归，按重画目的地的新效fort处理，不在现有规划内延伸（地图 Out of scope）。
2. **CLI 升为 V1 主交互面**：外部 agent 与脚本经 CLI 调用本应用的 capability（`list / describe / call` 形态沿原 §6.1，并按 05 票补强——describe 直接输出 JSON Schema、错误带稳定 code 与可执行下一步以利 agent 自纠、文档化 exit code；具体设计归 [07 票](../../.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md)）。**GUI 是同一能力面之上的薄壳**，不拥有能力面之外的私有业务入口（[ADR 0004](0004-capability-registry-sole-call-surface.md)）。
3. **CLI 永不交互阻塞**：无 TTY 时不等待 stdin；确认语义只能是显式 flag 或宿主 GUI 的 out-of-band 确认（agent 在沙箱内非交互执行命令，交互等待会挂死调用方）。
4. **dangerous 能力的最终确认必须落在宿主 GUI**（out-of-band，带超时与明确拒绝语义；CLI 返回结构化 `confirmation_denied` / `confirmation_timeout`）。理由（05 票）：Codex 层审批（sandbox/approval/rules）可被用户配置整体关闭（`approval_policy="never"`、`danger-full-access`、allow 规则）；`--yes` 类 flag 会被 agent 自己传上，等于不设防；MCP 规范明言注解只是 hint。故 Codex 层审批只作加分、不作依赖。safe（只读）直通；normal（可逆写）依赖 Codex 层审批 + 幂等键/receipt 兜底。（风险分级承载于 [ADR 0004](0004-capability-registry-sole-call-surface.md) 的契约；代理插件各能力的具体分级归 [04 票](../../.scratch/v1-mac-recharter/issues/04-proxy-plugin-v1-scope.md)。）
5. **MCP adapter 后补**：capability registry 稳定后补薄 MCP adapter（方向沿原 §6.2；05 票新增两个理由：per-tool 审批与 destructive 注解联动、plugin 目录分发面）。具体时点待定，归 [08 票](../../.scratch/v1-mac-recharter/issues/08-roadmap-spike-revision.md)。
6. **AgentRuntime seam 处置（2026-07-28 用户确认）**：**不预留抽象**。原 §7.2 的 `AgentRuntime` / adapter 分层随 §7 一并撤出，V1 不保留其接口、不为「将来内嵌 agent 回归」预留 seam——YAGNI，呼应原 §7.3 的告诫（「第二个真实 adapter 出现前不冻结过度抽象」；V1 连第一个内嵌 adapter 都不存在，预留的抽象没有真实消费方）。将来若内嵌 agent 回归，按届时效fort重新设计，不受今日预设形状约束。

## Consequences

- CLI 从「官方适配器之一」变为必交付物；agent 可用性（可发现、可自纠、可脚本化）成为能力设计的验收维度。
- 宿主 GUI 新增职责：dangerous 确认弹窗，须展示动作的真实参数、防「agent 替用户点确认」的社工话术（05 票引 MCP 客户端指引）。
- 随产品分发 agent 指引物（AGENTS.md 片段 / skill / rules 建议片段）成为产品动作而非用户作业（05 票建议；落地归 07/08 票）。
- 已知风险状态：workspace-write 沙箱拦截本地 IPC 已被 S3 spike **证实**（2026-07-28，UDS/localhost 全拦；对策 = `prefix_rule` 提权信任，见 [07 票](../../.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md)回写与 `Spikes/S3CodexSandbox/README.md`）；CLI vs MCP 的实际发现质量仍待实测。
- 接受的代价：V1 没有应用内 agent 体验（会话 UI、流式过程展示）；agent 场景依赖用户已安装的外部 agent（如 Codex）。
