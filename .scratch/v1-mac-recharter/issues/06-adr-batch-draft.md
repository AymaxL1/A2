# 06 — 起草 V1 ADR 批次

Type: task
Status: resolved
Blocked by: 03

## Question

把本图已落定的决定写成 `docs/adr/` 下的正式 ADR（格式循 `.agents/skills/domain-modeling/ADR-FORMAT.md`；本仓库尚无 `docs/adr/`，创建之）：

1. **Mac-only / Mac-first 平台边界**（推翻原调研文档的三端承诺；将来重开的条件）
2. **技术栈：Swift 原生**（理由、接受的成本、回退候选——直接取材「技术栈决定」票的 Answer）
3. **构建时可信插件**（沿用原文档 §2/§5，正式成文）
4. **capability 注册表为唯一业务调用面**（沿用原文档 §4，正式成文）
5. **agent-first 交互方向**：V1 不内嵌 Codex、CLI 为主交互面、dangerous 能力最终确认落宿主 GUI（03/05 票）。含 AgentRuntime seam 的处置——草稿中给出建议（默认：不预留抽象，YAGNI，呼应原文档 7.3 对过度抽象的告诫），由用户过目时确认。
6. **local-first、无云**（沿用，正式成文）

代理插件相关 ADR（GPL 合规姿态、内核锁版等）待「代理插件 V1 范围」解决后视需要补充，不在本票。

AFK 可做：从已解决票与三份调研文档提炼草稿，完成后列出要点请用户过目；用户确认前 ADR 标 proposed。

## Answer

已创建 `docs/adr/`（此前不存在），写入 6 份 ADR，全部 `status: proposed`（待用户过目后方可转 accepted）：

1. `docs/adr/0001-mac-only-platform-boundary.md` — 平台承诺收缩为 Mac-only / Mac-first，推翻原调研文档三端承诺；Windows/Web 仅在真实需求出现时按新效fort重画目的地重开，接受含核心代码的重写。
2. `docs/adr/0002-swift-native-stack.md` — V1 技术栈为 Swift 原生（SwiftUI + AppKit 兜底、SPM 多包 monorepo）；Electron 废弃、Tauri 退出候选；回退候选 Electron+TS（触发判据细化归 08 票）；含 03 票的 5 条理由与用户明确接受的四项成本。
3. `docs/adr/0003-build-time-trusted-plugins.md` — 插件为 monorepo 内构建时集成的可信独立包（开发时热加载）；V1 无运行时第三方插件、无市场；强逻辑隔离不做进程隔离，宿主对象不泄漏给插件。
4. `docs/adr/0004-capability-registry-sole-call-surface.md` — capability 注册表为唯一业务调用面：GUI/CLI/agent 共用同一契约，插件间不 import 实现，宿主实现包在 Host Port 深模块后；契约要素沿 §5.2，transport-neutral。
5. `docs/adr/0005-agent-first-interaction.md` — V1 不内嵌 Codex（原 §7 整体撤出）；CLI 升为主交互面、永不交互阻塞；GUI 为能力面上的薄壳；dangerous 能力最终确认必须落宿主 GUI；MCP adapter 于 registry 稳定后补；AgentRuntime seam 建议不预留抽象（YAGNI，标注待用户确认）。
6. `docs/adr/0006-local-first-no-cloud.md` — local-first、单用户：V1 无账号、无云后端、无跨设备同步；云/账号/同步继续暂缓，重开须新 ADR supersede。

**需要用户过目的判断点：**

- **ADR 0005 第 6 条（seam 处置，票内要求的确认项）**：草稿建议「不预留抽象」——原 §7.2 AgentRuntime/adapter 随 §7 整体撤出，V1 不保留其接口、不为将来回归预留 seam（YAGNI，呼应 §7.3「第二个真实 adapter 出现前不冻结过度抽象」；V1 连第一个内嵌 adapter 都没有）。已在 ADR 内标「草稿建议，待用户确认」。
- **ADR 0001 重开条件的措辞**：源材料只有「真实需求出现时重开、新效fort重画目的地、接受重写（含核心）」；草稿明确写了「不预设更具体的触发判据（待定）」，并补了直接推论「现有架构与代码不承诺可移植性、不为跨端预留兼容抽象」——如嫌过强可删。
- **ADR 0006 边界说明**：自行补了一句澄清「无云 ≠ 应用不联网」（更新检查、代理内核订阅下载不在禁止之列）——源文档未明说，但与 02 调研和 Sparkle 更新方向一致；不要可删。
- **栈无关化改写**：ADR 0003 略去原 §5.1 manifest 的「支持平台 macos|windows|web」字段（Mac-only 下失效，增删归 07 票）；ADR 0003/0004 把「插件不能 import Electron」「Worker/utility process」等 Electron 词汇改述为「不 import 宿主实现」「进程级隔离（机制待定）」，原生词汇映射归 07 票。
- **数字口径**：ADR 0002 语料密度用 03 票 Answer 的「SO 2025：Swift 5.4% vs TS 43.6%」（01 票为 vs JS 66%，取直接素材源 03 票口径）。

代理插件相关 ADR（GPL 合规姿态、内核锁版等）按票内约定未在本批，待 04 票解决后视需要补充。
