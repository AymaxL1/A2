# 05 — 测试与 AI 闭环:切 Electron 找回什么

Type: research
Status: open

## Question

ADR 0002 里用户「明确接受的成本」四项(失去自读兜底、XCUITest 分钟级闭环、语料密度差距、年度 SDK 升级纪律)在 Electron+TS 上各自翻转成什么收益,具体到工具与 2026 现状:

1. **E2E**:Playwright 对 Electron 的支持现状(`_electron` API 维护状态)、WebdriverIO electron-service 现状;秒级闭环是否属实;对 Tray/原生菜单/系统弹窗这些「非 DOM 面」E2E 能不能测(这是宠物/菜单栏场景的关键短板核查)。
2. **单元/域层**:vitest + TS 纯域层(对标 swift-testing 纯包层)——原调研文档 §9 测试分层在 Electron 上的原样可用度。
3. **快照/视觉**:Playwright screenshot / Loki / storybook 类方案对透明悬浮窗的适用性。
4. **AI 闭环**:改-编-测循环在 TS 上的形变(无编译等待?tsc/vite 热载;但注意 S1 已实证 AI 在 Swift 也能自主循环——本票要诚实对比,不是单方面吹 TS)。
5. **自读兜底**:用户 TS 有一定阅读能力(旧图前提 3)——这条在 ADR 0002 里是「彻底失去」,切回 Electron 即恢复;把它的实际含义写具体(哪些层用户真的会去读:manifest?capability contract?域逻辑?)。
6. **语料密度**:SO 2025 数据(Swift 5.4% vs TS 43.6%)之外,Electron 特有 API 的语料/文档质量一句话评估。

## Context

- ADR 0002 Consequences 段是本票的靶子,逐条对应。
- `docs/research/platform-framework-research.md` §9(测试层级)/§9.2(CI 门禁)是当时为 Electron 设计的,直接检验其 2026 可用性即可,别重新发明。
- S1 README 里「AI 自主改-编-测循环实证」是 Swift 侧的正向证据,对比时如实引用。

## Output

`docs/research/electron-recon/testing-ai-loop.md`(中文;第 1 项的「非 DOM 面 E2E」核查结果单独成节——若这里也弱,Swift 的 XCUITest 弱项就不构成差异化理由,裁决权重会变)。
