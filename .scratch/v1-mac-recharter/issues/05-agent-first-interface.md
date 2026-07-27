# 05 — Agent-first 接入面调研：外部 Codex 调用本应用

Type: research
Status: resolved

## Question

Agent 交互方向已反转（地图前提 4）：V1 不内嵌 Codex，改为先提供 CLI，让外部 Codex 调用本应用（示例：Codex 调用本应用设置 mihomo 代理），插件交互层尽量 agent-first。逐项对照一手来源核实这条路的事实基础，产出「技术栈决定」和「代理插件 V1 范围」两票所需的输入：

1. **Codex 侧接入路径盘点**：外部 Codex（CLI/IDE 形态）调用本机第三方应用的官方支持路径各是什么——shell 直调本地 CLI（配合 AGENTS.md 指引）的机制与限制；MCP server 配置（config.toml）与工具发现；若存在 plugins/skills/custom tools 等机制一并盘点。哪条是官方推荐给「本机第三方应用被 Codex 调用」的路径。
2. **审批与沙箱行为**：Codex 的 approval/sandbox 模型（网络、文件、命令白名单）如何影响它调用我们的 CLI——用户要预先配置什么、每次调用会弹什么、能否把特定 CLI 加入信任列表。以官方文档为准。
3. **agent-first CLI 设计的事实基础**：Codex 对 CLI 工具的发现与学习质量取决于什么（AGENTS.md、`--help`、JSON 输出、schema 描述）；agent-friendly CLI 的既有先例与约定（如 gh 等）；对照原调研文档 6.1 节的 `app capabilities list/describe/call --json` 设计，评估其对 agent 消费是否最优、要补什么。
4. **MCP 路线现状核查**：MCP 官方 SDK 各语言成熟度——尤其 TypeScript 与 Swift（Swift SDK 是否官方、维护状态如何），这是技术栈票的远期考量项；Codex 侧配置 MCP server 的用户成本；CLI vs MCP 对 Codex 工具发现质量的对比（原文档「仍需实测」项——文档层面能核到什么程度就核到什么程度，明确标注哪些必须留到 spike 实测）。
5. **dangerous 能力的 agent 路径**：Codex 通过 CLI 执行危险操作（如改系统代理）时，确认/审批应发生在哪一层（Codex 的 approval、我们 CLI 的二次确认、宿主 GUI 弹窗）——现有先例与官方指引；这对能力注册表的 safe/normal/dangerous 分级意味着什么。
6. **对首批插件的含义（分析性小结，标注为建议）**：宠物/提醒/代理在 agent-first 准则下的能力面样例（如 Codex 调 reminder.create、proxy.selectNode），供「代理插件 V1 范围」票与后续 spec 消费。

结论写入 `docs/research/agent-first-interface.md`（中文，每条结论附一手来源引用），并按 tracker 约定解决本票。

## Answer

- 官方无钦点唯一路径：MCP 是官方给「repo 之外外部工具/应用」的标准正门；CLI + AGENTS.md/skills 是零配置合法路径；plugin（ChatGPT/Codex 共用目录）可打包 skill+MCP 分发。CLI 先行成立，registry 稳定后补薄 MCP adapter（新增理由：per-tool 审批模式与 destructive 注解联动、plugin 分发面）。
- 审批双层：Codex 层 sandbox/approval/rules（`prefix_rule` 可一次性信任我们的 CLI，Smart approvals 会主动建议）；但其可被用户配置整体关闭，故 dangerous 能力最终确认必须落宿主 GUI（out-of-band），CLI 无 TTY 永不交互阻塞。
- MCP SDK 分层：TypeScript Tier 1（活跃）；Swift SDK 官方但 Tier 3「Experimental」（0.12.1，2026-05-07 后静默）——远期 adapter 语言差实质但可用 sidecar 化解，不左右 Electron-vs-Swift；方向反转本身反而移除了 Swift 路线的 V1 Codex SDK 逆风。
- 最关键 spike 项：workspace-write 沙箱是否拦截 CLI↔宿主本地 IPC（决定每次调用是否触发 escalation）；及 CLI vs MCP 实际发现质量。
- 详见 [docs/research/agent-first-interface.md](../../../docs/research/agent-first-interface.md)（含 6 项逐条事实/推断标注与 spike 清单）。
