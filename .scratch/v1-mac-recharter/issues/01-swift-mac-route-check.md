# 01 — Swift Mac 原生路线核查

Type: research
Status: resolved

## Question

在 Mac-only / Mac-first 前提下，用 Swift/SwiftUI 构建本平台的技术路线到底有多顺？逐项对照官方文档与一手资料核实，产出「技术栈决定」票所需的事实：

1. **关键窗口能力**：菜单栏常驻（SwiftUI `MenuBarExtra` 的能力与限制，何时必须退回 AppKit `NSStatusItem`）；宠物悬浮窗所需的透明、置顶、点击穿透、跨 Space/全屏可见（`NSWindow` 的 `ignoresMouseEvents`、`collectionBehavior`、level 等）；这些与调研文档中 Electron `BrowserWindow` 方案的对照。
2. **常驻应用工程面**：登录项/开机自启（`SMAppService`）、系统通知（UserNotifications 及非 MAS 应用的授权行为）、非 App Store 分发的签名/公证要求、Sparkle 等更新方案的现状。
3. **Codex 集成成本**：官方 TypeScript SDK 要求 Node；Swift 下直接对 `codex app-server`（JSON-RPC over stdio）裸写协议的可行性与成本，schema 生成物对 Swift 的可用性，降级路径 `codex exec --json` 从 Swift 驱动的可行性。这是 Swift 路线最大的逆风项之一，需要一手确认而不是推断。
4. **系统代理设置**（与代理插件相关）：从 Swift 设置 macOS 系统代理的官方途径（SystemConfiguration / `networksetup`）各自需要什么权限，是否绕得开特权助手——只需回答到「V1 仅系统代理」所需的深度。
5. **工程与测试**：SPM monorepo 多包边界能否承载调研文档第 4.1 节那样的分层（contracts / host / plugins）；swift-testing、XCTest、XCUITest 的现状；**UI 自动化对「项目主要由 AI 开发、用户基本不会 Swift」这一前提的现实支撑程度**——AI 驱动的写-测-验闭环在 Swift 桌面开发里比 TS/Playwright 弱多少，有什么兜底手段。
6. **AI 代写 Swift 的风险面**：语言/框架年度变动（SwiftUI API 演进）、社区资料密度对 AI 产出质量的影响，用户无法人工兜底时靠什么护栏。

结论写入 `docs/research/swift-mac-route.md`（中文，每条结论附一手来源引用），并按 tracker 约定解决本票。

## Answer

- 窗口能力（透明/置顶/点击穿透/跨 Space/全屏可见）全是 `NSWindow` 一手原语，Electron 在 macOS 上就是包装它们——Mac-only 下窗口层 Swift 无缺口且去掉中间层；`MenuBarExtra` 有已知 API 空洞（无法编程开合、拿不到 NSStatusItem），复杂交互退回 `NSStatusItem`（能力完整）。
- 常驻工程面官方 API 齐：`SMAppService`（macOS 13+）、UserNotifications（但未签名 dev build 会崩，开发期即需签名）、Developer ID+公证为平台级要求（Electron 同样要做）、Sparkle 2 活跃且支持 SPM/沙箱。
- Codex 是最大逆风：官方 SDK 仅 TS（Node 18+）/Python，无 Swift；`codex app-server` 为 JSON-RPC 2.0 over stdio + 官方 JSON Schema 导出，Swift 裸写可行但类型面要自建自养（协议仍在演进、部分 API experimental）；降级路径 `codex exec --json`（JSONL）对 Swift 与 Node 完全等价。
- 系统代理 V1 深度内绕得开特权助手：admin 用户直接 `networksetup` 零弹窗；`SCPreferencesCreateWithAuthorization` 有 30 秒授权时效会反复弹窗（DTS 确认）；零弹窗完全体走 `SMAppService.daemon` 一次审批，无需老式 SMJobBless。
- 测试闭环：SPM 多包分层 + swift-testing（`swift test` 纯 CLI）在单元/集成层与 TS 同级；UI 自动化明显弱一档（swift-testing 不覆盖 UI，XCUITest 需 Xcode 工程+GUI 会话，SPM 无 UI 测试 target），兜底=薄 UI+快照测试+诊断 CLI+少量 XCUITest 冒烟；SwiftUI 年度演进大、语料密度低（SO 2025：Swift 5.4% vs JS 66%），护栏靠编译器+产物化验证。
- 详见 [docs/research/swift-mac-route.md](../../../docs/research/swift-mac-route.md)（含逐条一手来源；最终裁决留给技术栈决定票）。
