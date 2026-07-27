---
status: accepted
date: 2026-07-28
---

# local-first：V1 无账号、无云后端、无跨设备同步

本平台是 local-first 的单用户桌面应用：V1 无账号体系、无云后端、无跨设备同步，数据全部驻留本机。此原则自原调研文档 §2 沿用（2026-07-27 重梳时确认不在重开范围内），本 ADR 正式成文。

## Context

- 出自 [platform-framework-research.md](../research/platform-framework-research.md) §2（「local-first；V1 无账号、无云后端、无跨设备同步」）；§7.3 亦以「local-first、单用户、无后端」为既定前提排除了 Multica 的云侧设计。
- [地图](../../.scratch/v1-mac-recharter/map.md) Notes 确认此原则不在本次重开范围；云账号/同步与 App Store 发布、静默自动更新等同属原文档 §12 暂缓清单，继续暂缓（地图 Out of scope）。

## Decision

- **local-first、单用户**：插件数据、配置、能力调用记录（receipt/审计）全部驻留本机；能力调用面（GUI/CLI/agent）走本机当前用户范围的本地 IPC，无远程 API。
- **V1 无账号、无云后端、无跨设备同步**。
- 边界说明：「无云」指本产品不设自有云服务作为功能后端；应用自身的更新检查与插件功能固有的对外网络行为（如代理内核的订阅下载）不在此列。

## Consequences

- 无服务端成本、运维与数据合规面；隐私姿态简单——用户数据不出本机。
- 接受的代价：不支持跨设备场景与云备份；数据备份/迁移是本机文件级问题，由插件独立存储命名空间与 schema migration 承担（[ADR 0003](0003-build-time-trusted-plugins.md)）。
- 将来引入账号/云/同步是显式的新决定，须以新 ADR supersede 本条。
