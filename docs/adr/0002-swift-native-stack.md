---
status: superseded by ADR-0010
date: 2026-07-28
superseded: 2026-08-04
---

# 技术栈：Swift 原生（SwiftUI + AppKit 兜底，SPM 单包多 target）

> **2026-08-04 废止**：本 ADR 已由 [ADR 0010](0010-ts-kernel-bun-runtime.md)（TS 内核 + Bun compile 单 bin，Mac 壳留 Swift）取代。触发原因是架构反转与跨端承诺（[ADR 0008](0008-kernel-bin-ui-optional.md)、[ADR 0009](0009-kernel-platform-scope.md)）——本 ADR 的前提「Mac-only + UI 是必需品」不再成立。**注意重立的是内核语言，不是 UI 路线**：Mac 菜单栏壳与全套 UI 资产继续用 Swift（见 ADR 0010），文末 electron-recon 重评结论（不回 Electron）依然有效。以下正文保留为历史记录。

Mac-only 前提下（[ADR 0001](0001-mac-only-platform-boundary.md)），V1 技术栈裁决为 **Swift 原生**（2026-07-28 用户裁决）：Swift/SwiftUI，AppKit 兜底，SPM 单包多 target monorepo（包结构粒度经 [07 票](../../.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md)细化裁决）。Electron 方案废弃，Tauri 退出候选；回退候选为 Electron+TS。

## Context

- 裁决全文见 [03 票](../../.scratch/v1-mac-recharter/issues/03-tech-stack-decision.md)（Answer）；事实输入来自三份调研：[swift-mac-route.md](../research/swift-mac-route.md)（[01 票](../../.scratch/v1-mac-recharter/issues/01-swift-mac-route-check.md)）、[mihomo-integration.md](../research/mihomo-integration.md)（[02 票](../../.scratch/v1-mac-recharter/issues/02-mihomo-integration-survey.md)）、[agent-first-interface.md](../research/agent-first-interface.md)（[05 票](../../.scratch/v1-mac-recharter/issues/05-agent-first-interface.md)）。
- 本 ADR 推翻 [platform-framework-research.md](../research/platform-framework-research.md) §1/§3 推荐 Electron 的结论；该文档栈无关部分（能力契约、插件模型、CLI 设计、测试分层思想）继续有效——逐节处置清单见 03 票 Answer。
- 关键前提：用户基本不会 Swift（读、写、审都依赖 AI）。这曾是 Swift 路线最大顾虑，最终连同下列成本被用户明确接受。

## Decision

V1 采用 **Swift 原生路线**：Swift/SwiftUI，AppKit 兜底（`NSStatusItem`、宠物窗 `NSPanel` + `NSHostingView`），SPM 单包多 target monorepo（编译期边界与多包等价，将来需独立发版再拆包——07 票裁决），Mac-only。Electron 方案废弃；Tauri 退出候选。

理由（沿 03 票 Answer）：

1. Mac-only（前提 1）拆掉了 Electron 的核心卖点（跨平台一致 + Web 复用）；其成本（常驻内存、8 周 major + Chromium 安全流水线、原生感隔层）成为无补偿支出。
2. 产品形态（24/7 菜单栏常驻 + 桌宠悬浮窗 + 代理壳）天然原生：所需窗口能力是同组 `NSWindow` 原语的本体（Electron 是其封装），`SMAppService`/UserNotifications/Sparkle/签名公证皆第一方路径；系统代理在 V1 深度（仅系统代理模式）零特权助手（01、02 票）。
3. agent-first 反转（[ADR 0005](0005-agent-first-interaction.md)）移除了 TS 侧最大结构优势（官方 Codex SDK）；CLI 交互面栈中立；MCP Swift SDK 虽 Tier 3 但属远期项、可 sidecar 化解（05 票）。
4. mihomo 集成两栈无实质差异（02 票）。
5. 剩余逆风均有结构性补偿：UI 自动化弱一档 → 薄 UI + 状态下沉 swift-testing 纯包 + 快照/产物化验证 + 少量 XCUITest 冒烟；语料密度差距（SO 2025：Swift 5.4% vs TS 43.6%）→ 所需 API 集中于第一方框架 + 编译器护栏（强类型、渐进 Swift 6 并发检查）；SwiftUI 年度演进 → WWDC 后 pin SDK、计划内批量升级。

## Considered Options

- **Electron + TypeScript**：原调研文档的推荐结论，废弃；保留为**回退候选**——若 spike 阶段暴露不可接受问题，原调研文档结论仍可执行。回退触发判据的细化归 [08 票](../../.scratch/v1-mac-recharter/issues/08-roadmap-spike-revision.md)，本 ADR 只记方向。
- **Tauri 2**：原 Plan B，退出候选——重开动机不主要是内存，且用户不熟 Rust。

## Consequences

用户明确接受的成本（03 票 Answer）：

- **彻底失去自读兜底**：对代码的信任挂在编译器 + 产物化验证 + AI 诊断上；
- **XCUITest 分钟级闭环**：UI 自动化比 TS/Playwright 弱一档；
- **语料密度差距**：AI 产出质量风险靠第一方 API 集中度与编译器护栏压制；
- **年度 SDK 升级纪律**：WWDC 后 pin SDK、计划内批量升级。

后续工作：包边界与架构映射归 [07 票](../../.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md)；测试策略与 spike 清单重排（候选：宠物悬浮窗、capability 纵切含 CLI、Sparkle 签名公证更新链、Codex↔CLI 沙箱实测）归 08 票。

## 重评记录

- **2026-07-28(electron-recon):维持原判,V1 内封栈。** Phase 0 三 spike 全过、三条回退硬门均未触发之后,用户以硬门之外的新动机(进度/工具链/通用性)发起一次性重评(七张 AFK 票 + E1 本机冒烟,材料见 [docs/research/electron-recon/](../research/electron-recon/README.md));终裁不翻案。「回退候选 Electron+TS」条款经本次重评**行使并了结**——V1 期内技术栈问题不再受理。要点:堵点定性为一次性环境阻塞(接受装 Xcode,挂 Phase 0 基建前置)而非原则拒绝苹果工具链;「宠物窗压全屏之上」定为硬需求(S1 已验 vs Electron 多年 wontfix);Windows 诉求存在但重新确认 [ADR 0001](0001-mac-only-platform-boundary.md)「届时含核心重写」。裁决全文:[09 票](../../.scratch/electron-recon/issues/09-final-ruling.md)。
