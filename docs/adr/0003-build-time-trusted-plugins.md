---
status: accepted
date: 2026-07-28
---

# 插件模型：构建时可信插件，V1 无运行时第三方插件与市场

插件是 monorepo 内的可信独立包，构建时集成、开发时热加载；V1 不开放运行时第三方插件安装，也不做插件市场。此原则自原调研文档沿用（2026-07-27 重梳时确认不在重开范围内），本 ADR 正式成文。

## Context

- 原则出自 [platform-framework-research.md](../research/platform-framework-research.md) §2（产品边界）与 §5（插件模型：manifest / capability contract / 隔离策略）；[03 票](../../.scratch/v1-mac-recharter/issues/03-tech-stack-decision.md) Answer 的处置清单将其列为栈无关保留部分。
- [地图](../../.scratch/v1-mac-recharter/map.md) Notes 确认此原则不在本次重开范围；运行时第三方插件与市场属原文档 §12 暂缓清单，继续暂缓。
- V1 首批插件：宠物、提醒、代理（mihomo 壳）（地图；原文档首批中的桌面 Agent 插件已撤出 V1，见 [ADR 0005](0005-agent-first-interaction.md)）。

## Decision

- 插件是 **monorepo 内的可信独立包**：构建时集成进应用，开发时支持热加载；不存在运行时插件安装面。
- **V1 无运行时第三方插件、无插件市场**（继续暂缓，非本效fort议题）。
- 每个插件声明 manifest：id、显示名 i18n key、版本、所需 Plugin API 范围、生命周期与后台任务、请求的宿主权限、提供/消费的 capability、数据 schema 版本与 migration、Agent/CLI 可发现的能力摘要、设置页与可选展示 surface（要素沿原文档 §5.1；原清单中「支持平台」字段在 Mac-only 下如何增删，连同承载形式一并归 [07 票](../../.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md)）。
- **隔离姿态：强逻辑隔离，不做一插件一进程**（沿原文档 §5.3）：UI 错误边界；后台任务超时、取消、重试与熔断；插件启用失败后安全禁用；插件独立存储命名空间与 migration；能力调用异常不得穿透宿主；故障注入测试覆盖超时、坏数据、缺失 capability 等。
- 宿主 API 不把宿主实现对象（系统框架对象、数据库句柄等）泄漏给插件，为将来收紧隔离保留升级空间。
- 将来若开放不受信任的第三方插件，再引入进程级隔离、签名与资源配额；具体机制届时按 Swift 栈另定（待定——原文档以 Electron 词汇描述这部分，原生对应词汇归 07 票清点）。

## Consequences

- 信任模型简单：无签名校验、无市场审核、无运行时权限协商；工程投入集中在能力契约而非插件分发。
- 接受的代价：插件与宿主同进程，插件缺陷理论上可拖垮宿主——以上述逻辑隔离与故障注入测试兜底。
- 开放第三方插件是显式的将来决定，届时须补进程隔离/签名/配额，并以新 ADR supersede 本条的范围部分。
