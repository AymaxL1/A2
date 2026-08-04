---
status: superseded by ADR-0009
date: 2026-07-28
superseded: 2026-08-04
---

# 平台边界：Mac-only / Mac-first

> **2026-08-04 废止**：本 ADR 已由 [ADR 0009](0009-kernel-platform-scope.md)（内核承诺 macOS + Linux、Windows 远景不设预留、UI 仅 Mac）取代。触发原因是架构反转（[ADR 0008](0008-kernel-bin-ui-optional.md)）——需要跨端的是无头内核的 CLI 面，不是 UI，本 ADR「三端 UI 成本过高」的论证前提随之消失。以下正文保留为历史记录。

原调研文档曾承诺 macOS、Windows 为完整宿主、Web 为能力子集；本次 V1 重梳开图时（2026-07-27）用户确认将平台承诺收缩为 **Mac-only / Mac-first**，V1 只做 macOS。Windows/Web 将来若有真实需求，按新效fort重画目的地，接受届时重写（含核心代码）。

## Context

- 三端承诺出自 [docs/research/platform-framework-research.md](../research/platform-framework-research.md) §2（「macOS、Windows 为完整宿主；Web 是能力子集」），并连带产生 host-web、跨宿主一致性、Web E2E 等架构与测试负担。
- 收缩为 Mac-only 是本次重梳的前提 1（[地图](../../.scratch/v1-mac-recharter/map.md) Notes，2026-07-27 用户确认），也是技术栈重议的起点：「Swift 核心跨端、UI 多端」并不成立（Swift on Windows 无生产级 UI 方案，SwiftWasm 不可用于生产），而维持三端承诺实际上把技术栈锁在 Electron 系，为尚无真实需求的跨端能力持续付成本（[03 票](../../.scratch/v1-mac-recharter/issues/03-tech-stack-decision.md)）。

## Decision

- 平台承诺为 **Mac-only / Mac-first**：V1 只构建、只测试、只发布 macOS 版本。
- 推翻原调研文档的三端承诺；其全部 Web 宿主（host-web）、Web E2E 与跨宿主一致性内容废弃（逐节处置清单见 03 票 Answer）。
- **重开条件**：Windows/Web 仅在**真实需求出现**时重开——本批决定不预设更具体的触发判据（待定，届时判断）；重开是**重画目的地的新效fort**，不是现有规划的延伸；届时**接受重写，包括核心代码**——现有架构与代码不承诺可移植性。

## Consequences

- 技术栈裁决摆脱跨端约束：Electron 的核心卖点（跨平台一致 + Web 复用）失效，见 [ADR 0002](0002-swift-native-stack.md)。
- 系统显著变小：无 host-web、无跨宿主抽象、无多平台 CI 矩阵。
- 接受的代价：将来重开 Windows/Web 没有移植捷径，是含核心代码的重写；本批决定也不为未来跨端预留任何兼容抽象。
