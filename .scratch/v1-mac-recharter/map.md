# 地图：V1 重梳 — Mac-first 技术栈与首批插件（含代理）

Labels: wayfinder:map
创建：2026-07-27
**到达：2026-07-28** —— 八张票全部解决，Destination 产出齐备（ADR 0001–0007 proposed、原文档处置清单、`docs/v1-roadmap.md`）。后续实施（Phase 0 起）按新效fort开图。

## Destination

一套锁定的 V1 基础决定集，取代 2026-07-16 调研文档（`docs/research/platform-framework-research.md`）中被推翻的部分：在 **Mac-only / Mac-first** 前提下选定技术栈（Electron+TS 还是 Swift 原生），把**代理插件（mihomo 壳，V1 仅系统代理模式）**纳入首批插件，并确立 **agent-first 交互方向**（V1 不内嵌 Codex，先以 CLI 让外部 Codex 调用本应用），形成可以开工 Phase 0 的更新版决策基础——包括 ADR 方向、调研文档的处置（哪些章节保留/废弃）和修订后的阶段路线。

## Notes

- **领域**：桌面插件能力平台。V1 首批插件：宠物、提醒、**代理（mihomo 壳，本效fort新增）**；内嵌桌面 Agent（Codex）已撤出 V1（见前提 4）。local-first、无云、构建时可信插件、能力注册表为唯一业务调用面——这些原则不在重开范围内。
- **本效fort的前提（2026-07-27 开图时用户确认，替代原调研文档第 2 节的对应边界）**：
  1. 平台承诺为 **Mac-only / Mac-first**；Windows/Web 将来若有真实需求，接受届时重写（含核心）。
  2. 代理插件 V1 **仅系统代理模式**，不做 TUN、不引入特权助手；TUN 只记录「将来的门长什么样」。
  3. 用户 **基本不会 Swift**（读写审都依赖 AI）；对 TS/JS 有一定阅读能力（原调研文档以此为前提）。
  4. **Agent 交互方向反转（2026-07-28 用户确认）**：V1 不做内嵌 Codex 的 Agent 插件（原调研文档第 7 节整体撤出 V1）；改为先提供 CLI，让外部 Codex 调用本应用（示例场景：Codex 调用本应用设置 mihomo 代理）。插件交互层尽量 agent-first——能力面是第一交互面，GUI 是其上的壳。原文档第 6 节的 CLI 由「官方适配器之一」升为 V1 主交互面。
- **技能**：决定类票用 `/grilling` + `/domain-modeling`；调研票用 `/research`（结论落 `docs/research/`，本仓库无 git，直接写文件、不建分支）；范围讨论若需要可用 `/prototype` 提高保真度。
- **tracker 约定**：见 `docs/agents/issue-tracker.md`。票在 `issues/NN-<slug>.md`，解决时在票内追加 `## Answer`、置 `Status: resolved`，并向本文件 Decisions so far 追加一行（追加前先重读本文件，避免覆盖并发修改）。
- **文档语言**：中文。

## Decisions so far

- [Swift Mac 原生路线核查](issues/01-swift-mac-route-check.md) — Mac-only 下 Swift 路线成立：窗口/常驻/系统代理（V1 深度免特权助手）均为一手官方 API 且无缺口；两大实逆风是 Codex 无官方 Swift SDK（app-server 裸写可行但类型面自养，`codex exec --json` 降级等价）与 UI 自动化闭环弱于 TS/Playwright 一档（兜底=薄 UI+快照+诊断 CLI）；详见 `docs/research/swift-mac-route.md`，裁决留给技术栈决定票。
- [mihomo 集成面与合规调研](issues/02-mihomo-integration-survey.md) — 不做 TUN 时系统代理可零特权助手（`networksetup` 只需管理员账户，Clash Verge Rev 无助手为证，需留标准账户降级路径）；mihomo 为 GPL-3.0，子进程+CLI+REST 属 FSF "separate programs"，宿主可不开源（中高确定性；义务=附 GPL 文本+内核源码途径，红线=禁止进程内链接）；控制面 100% 官方 REST/WS 覆盖，内核单架构 ~41.4 MiB 仅 ad-hoc 签名须自行重签+公证、建议随应用锁版；Electron 与 Swift 集成难度无实质差异（各有壳先例）；详见 `docs/research/mihomo-integration.md`。
- [Agent-first 接入面调研](issues/05-agent-first-interface.md) — CLI 先行成立（官方无钦点唯一路径：MCP 是「repo 之外外部工具」正门、AGENTS.md/skills 零配置合法、plugin 可打包分发，registry 稳定后补薄 MCP adapter）；Codex 侧 `prefix_rule` 可一次性信任本 CLI 但可被用户整体关审批，故 dangerous 能力最终确认必须落宿主 GUI；MCP Swift SDK 官方但 Tier 3 实验级（TS 为 Tier 1），可 sidecar 化解、不左右技术栈裁决，且反转移除了 Swift 路线的 V1 Codex SDK 逆风；最关键 spike：workspace-write 沙箱是否拦截 CLI↔宿主本地 IPC；详见 `docs/research/agent-first-interface.md`。
- [技术栈决定：Electron 还是 Swift（Mac-only 前提）](issues/03-tech-stack-decision.md) — 裁决 **Swift 原生**（SwiftUI+AppKit 兜底、SPM monorepo——包结构后由 07 票细化为单包多 target、Mac-only；Electron 废弃、Tauri 退出候选，回退候选为 Electron+TS）；剩余逆风以薄 UI+快照/产物化验证+编译器护栏+SDK pin 纪律补偿，用户明确接受失去自读兜底；原调研文档栈相关章节废弃、栈无关部分（能力契约/插件模型/CLI/测试分层思想）保留——处置清单见票内 Answer。
- [代理插件 V1 范围](issues/04-proxy-plugin-v1-scope.md) — 菜单栏轻壳（ClashX Meta 对标，完整操作面走 CLI/capability）；退出即还原+崩溃自愈；能力分级 读=safe/改状态=normal/改信任面=dangerous（开关代理、切节点 normal 零打断，换订阅源 dangerous 落宿主 GUI 确认——平台 dangerous 模型首个真实用例）；内核随应用锁版、子进程红线、宿主闭源+履行 GPL 附文义务。in/out 两栏清单见票内 Answer。
- [起草 V1 ADR 批次](issues/06-adr-batch-draft.md) — `docs/adr/` 已建，0001–0006 六份 ADR 落盘（Mac-only 边界、Swift 原生栈、构建时可信插件、注册表唯一调用面、agent-first 交互、local-first 无云），全部 proposed 待用户过目；AgentRuntime seam 草稿建议「不预留抽象（YAGNI）」等判断点清单见票内 Answer。
- [Swift 架构映射与工程形态](issues/07-swift-architecture-mapping.md) — 单 SPM 包多 target（Contracts/SDK/Runtime/HostMacOS/TestKit/UISystem/各插件/aa CLI，插件不得 import Host*）；app 壳用 XcodeGen（yml 入库、xcodeproj 不入库）；CLI=独立 `aa` 可执行+UDS 薄客户端（沙箱放行与否是 Phase 0 spike）；agent-first 双层命令面+`aa docs agents-md`；mihomo=插件私有资源+宿主 ProcessPort；测试=swift-testing 纯包主体+快照+XCUITest 冒烟+CLI 即 E2E，门禁先落本地脚本（无 git）。
- [阶段路线与 spike 清单修订](issues/08-roadmap-spike-revision.md) — 定稿 `docs/v1-roadmap.md`（取代原文档 §10/§11）：Phase 0 三 spike（宠物窗、capability 纵切含 CLI+UDS、Codex 沙箱实测）+最小签名仪式，收尾按三条硬门对 Electron 回退裁决一次；Phase 1=平台最小核+代理插件首发（验收=旗舰场景）；Phase 2=宠物+提醒（§8 保留/改写/删除三栏清点）；Phase 3=发布工程完整链；并补 ADR 0007（mihomo 合规）完成收图检查——**本图到达目的地**。

## Not yet specified

（空——本图已到达目的地（2026-07-28），全部雾已清。实施期新问题归 Phase 0 起的新效fort，不回写本图。）

## Out of scope

- **实施本身**：本图产出的是决定与更新后的规划基础；Phase 0 及之后的搭建是后续效fort。
- **TUN 模式**：V1 范围外（前提 2）；mihomo 调研票只记录将来需要的门（特权助手/签名等），不展开设计。
- **内嵌 Codex / 应用内 Agent 聊天（原文档第 7 节）**：2026-07-28 用户反转（前提 4），撤出 V1；将来若回归，按重画目的地的新效fort处理，不在本图延伸。
- **Windows / Web 版本**：Mac-only 决定生效；若将来重开是重画目的地的新效fort，不是本图的延伸。
- **原调研文档第 12 节的暂缓清单**：运行时第三方插件、市场、云账号/同步、App Store 发布、静默自动更新等，继续暂缓，本效fort不触碰。
