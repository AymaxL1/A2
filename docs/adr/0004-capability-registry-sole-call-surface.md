---
status: accepted
date: 2026-07-28
---

# capability 注册表为唯一业务调用面

所有稳定、用户有意义的领域能力都经宿主的版本化 capability 注册表暴露，GUI、CLI、外部 agent 与未来协议适配器共用同一契约；插件之间不直接 import 实现；宿主实现包在 Host Port 深模块之后。此原则自原调研文档 §4 沿用（确认不在重开范围内），本 ADR 正式成文。

## Context

- 出自 [platform-framework-research.md](../research/platform-framework-research.md) §4（「能力契约只有一个事实来源」与分层架构）与 §5.2（capability contract 要素）；[03 票](../../.scratch/v1-mac-recharter/issues/03-tech-stack-decision.md) Answer 处置清单将其列为栈无关保留部分。
- agent-first 反转（[ADR 0005](0005-agent-first-interaction.md)）强化了本原则的地位：能力面从「多个交互面共用的后端」升为第一交互面（[05 票](../../.scratch/v1-mac-recharter/issues/05-agent-first-interface.md)；[agent-first-interface.md](../research/agent-first-interface.md) §3.3 核实 `list/describe/call` 形态与 MCP 工具模型同构）。

## Decision

- **能力契约只有一个事实来源**：
  - GUI 不直接调用插件实现，CLI 不重写业务逻辑，外部 agent 没有私有超级接口——一律经 capability 注册表调用；
  - 插件之间不直接 import 实现，通过版本化 capability 协作（如 reminder 请求 `notification.presenter` 能力，而不是 import pet）；
  - 宿主实现（系统 API、存储、调度、能力注册、进程管理）包在 **Host Port 深模块**之后，插件只依赖公开契约、不 import 宿主实现（原文档语境为「业务插件不能 import Electron」，Swift 栈下的对应包边界归 [07 票](../../.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md)）。
- **capability contract 要素**（沿原文档 §5.2）：稳定 ID 与版本；输入/输出 JSON Schema；query/command 之分；风险等级 safe / normal / dangerous；所需权限；幂等键与重试语义；超时、取消与结构化错误；可逆性与补偿；用户可读摘要与 agent 可读短描述；成功/校验失败/权限拒绝/幂等/补偿的测试样例。
- **只有领域能力上注册表**：`reminder.create` 是能力，`database.execute` 和 `pet.setFrame` 不是。
- 契约保持 **transport-neutral**：未来 MCP 等适配器是薄翻译层，协议类型不得进入领域核心（原文档 §6.2，经 05 票强化）。

## Consequences

- 每个新能力都要付契约成本（schema、风险级、幂等、测试样例）——有意的门槛，换来 GUI/CLI/agent/未来 MCP adapter 一次定义、处处一致（05 票核实该形状可被机械翻译为 MCP 工具面）。
- 测试面受益：Fake host + conformance 套件可在纯 swift-testing 层验证契约（栈无关思想保留，落地归 07/08 票）。
- safe / normal / dangerous 三级风险分级是 agent 路径安全模型的地基（见 ADR 0005）。
