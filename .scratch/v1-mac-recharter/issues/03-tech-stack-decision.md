# 03 — 技术栈决定：Electron 还是 Swift（Mac-only 前提）

Type: grilling
Status: resolved
Blocked by: 01, 02, 05

## Question

在已确认的前提下（Mac-only / Mac-first、代理插件 V1 仅系统代理、V1 不内嵌 Codex 而是 agent-first 反转、用户基本不会 Swift、项目主要由 AI 开发），V1 技术栈选 Electron+TypeScript（维持原调研结论）还是 Swift/SwiftUI 原生？

开图时已摆上桌的论点（2026-07-27 会话）：

- 「Swift 核心跨端、UI 多端」不成立：Swift on Windows 无生产级 UI 方案，Web 方向 SwiftWasm 不可用于生产。选 Swift 的诚实表述是「现在做最好的 Mac 原生版，将来跨端接受重写」。Mac-only 前提下这不再是反对票。
- Mac-only 使 Swift 成为更好的**产品**答案：菜单栏、宠物悬浮窗、常驻内存、无 Chromium 更新税，且可整体砍掉 host-web/conformance 层，系统更小。
- Swift 的主要逆风：用户无法人工兜底审查（全靠 AI + 测试闭环）；Codex 官方 SDK 是 TS-only，Swift 需裸写 app-server 协议；原测试策略（Playwright/Web 生态）需按 XCUITest 重建，AI 驱动的 E2E 闭环变弱。
- Electron 的主要逆风：常驻几百 MB 对 24/7 代理场景更显眼；每 8 周 major + Chromium 安全流水线的长期维护税；为不再兑现的跨端能力持续付成本。
- Tauri 维持 Plan B，不升格（重开动机不主要是内存，且用户不熟 Rust）。

更新（2026-07-28，Agent 交互方向反转——见地图前提 4）：「Swift 需裸写 Codex app-server 协议」这条逆风基本退场——V1 只需对外暴露本应用 CLI，栈中立；「Swift Mac 原生路线核查」中关于 app-server 的结论降为远期参考。随之新增的栈考量：将来加 MCP server 时各语言 SDK 生态（TS 最成熟，Swift 现状以「Agent-first 接入面调研」的结论为准）。

决定时机：待「Swift Mac 原生路线核查」「mihomo 集成面与合规调研」「Agent-first 接入面调研」三票落地后，用 `/grilling` 把事实压上去做最终裁决。

解决本票时须一并给出：

1. 栈决定本身与主要理由（写成可直接转 ADR 的形式）。
2. 调研文档 `docs/research/platform-framework-research.md` 的处置：哪些章节保留（能力契约、插件模型、测试分层等栈无关部分）、哪些废弃（框架对比结论、Web 宿主、包边界细节）。
3. 测试策略与 spike 清单在选定栈上的重排方向（细化留给后续票/fog）。

## Answer

**决定（2026-07-28，用户裁决）：V1 采用 Swift 原生路线**——Swift/SwiftUI，AppKit 兜底（`NSStatusItem`、宠物窗 `NSPanel`+`NSHostingView`），SPM 多包 monorepo，Mac-only。Electron 方案废弃；Tauri 退出候选。若 spike 阶段暴露不可接受问题，回退候选是 Electron+TS（原调研文档结论仍可执行）。

**理由（可直接转 ADR）：**

1. Mac-only（地图前提 1）拆掉了 Electron 的核心卖点（跨平台一致 + Web 复用）；其成本（常驻内存、8 周 major + Chromium 安全流水线、原生感隔层）成为无补偿支出。
2. 产品形态（24/7 菜单栏常驻 + 桌宠悬浮窗 + 代理壳）天然原生：窗口能力是同组 `NSWindow` 原语的本体（Electron 是其封装），`SMAppService`/UserNotifications/Sparkle/签名公证皆第一方路径；系统代理 V1 深度零特权助手（01、02 票）。
3. agent-first 反转（地图前提 4）移除了 TS 侧最大结构优势（官方 Codex SDK）；CLI 交互面栈中立；MCP Swift SDK 虽 Tier 3 但远期可 sidecar 化解（05 票）。
4. mihomo 集成两栈无实质差异（02 票）。
5. 剩余逆风均有结构性补偿：UI 自动化弱一档 → 薄 UI + 状态下沉 swift-testing 纯包 + 快照/产物化验证 + 少量 XCUITest 冒烟；语料密度（SO 2025：Swift 5.4% vs TS 43.6%）→ 所需 API 集中于第一方框架 + 编译器护栏（强类型、渐进 Swift 6 并发检查）；SwiftUI 年度演进 → WWDC 后 pin SDK、计划内批量升级。

**用户明确接受的成本：** 彻底失去自读兜底（信任挂在编译器 + 产物化验证 + AI 诊断上）；XCUITest 分钟级闭环；语料密度差距；年度 SDK 升级纪律。

**原调研文档（`docs/research/platform-framework-research.md`）处置：**

- **废弃**：§1（Electron 推荐结论）、§3/§3.1（框架对比结论与 Electron 风险控制）、§4.1（pnpm 包边界）、全部 Web 宿主/host-web/Web E2E 内容、§7（内嵌 Codex——已由前提 4 撤出）、§11（阶段路线，由 08 票重写）。
- **保留（栈无关，继续有效）**：§2 其余产品边界（local-first、构建时可信插件、能力注册表唯一调用面）、§4 分层思想（Host Port 深模块、插件不 import 宿主实现）、§5 插件模型（manifest / capability contract / 隔离策略）、§6 CLI 设计与 CLI-vs-MCP 判断（经 05 票强化）、§8 纵向设计的领域部分（表现层换原生词汇，归 08 票清点）、§9 测试分层思想（层次保留，Web 层删除、E2E 载体重定）、§10 spike 思想（清单重排归 08 票）。

**测试与 spike 方向（细化归 07/08 票）：** 测试金字塔主体 = swift-testing 纯包层（领域/契约/host conformance，Fake host 概念保留）；快照测试为视图层的「可 diff 的眼睛」；XCUITest 仅少量冒烟；诊断 CLI 为端到端机器验证口。Spike 候选：宠物悬浮窗、capability 纵切（含 CLI）、Sparkle 签名公证更新链、Codex↔CLI 沙箱实测（05 票遗留的最关键项）。
