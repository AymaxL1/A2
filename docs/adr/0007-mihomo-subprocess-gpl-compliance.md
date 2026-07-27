---
status: accepted
date: 2026-07-28
---

# mihomo 集成：子进程隔离、随应用锁版、宿主闭源 + GPL 义务

代理插件把 GPL-3.0 的 mihomo 内核作为私有资源随应用打包。集成红线：内核只以独立子进程运行，控制面只走其外部接口（REST API / 配置文件），**永不进程内链接**（含 c-archive/cgo 静态链接）——这使宿主与内核构成 FSF 意义上的 separate programs / mere aggregation，宿主与插件代码得以保持闭源（中高确定性；ClashX Meta 因静态链接被迫转 AGPL 是反例）。

## Decision

- **锁版**：mihomo 版本随应用发布锁定，升内核 = 发应用更新（走 Sparkle 链）；V1 不做应用内独立升内核。
- **义务**：发布物附 GPL-3.0 文本 + 所用内核版本与源码获取指引（关于页/发布说明）；在首个对外分发版本前落地（见 [v1-roadmap.md](../v1-roadmap.md) Phase 3）。
- **打包**：内核为 `PluginProxy` 私有资源；构建链统一重签（内核官方产物仅 ad-hoc 签名）并随 app 公证；子进程生命周期经宿主 ProcessPort（特权面归宿主、业务面归插件）。

## Consequences

- 换取：宿主闭源自由；锁版使「内核版本 = 可测的固定配套」；无需自建内核分发/验签通道。
- 代价：内核安全更新必须等应用发版；红线永久排除进程内集成的体积/性能优化路径。
- 依据：[02 票](../../.scratch/v1-mac-recharter/issues/02-mihomo-integration-survey.md)、[04 票](../../.scratch/v1-mac-recharter/issues/04-proxy-plugin-v1-scope.md)、[mihomo-integration.md](../research/mihomo-integration.md)。
