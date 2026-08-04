---
status: accepted
date: 2026-08-04
---

# 插件：exec 一次一调协议、装载期打包成单文件、装载零闸调用层仲裁

插件北极星是「**agent 现场写插件**」（[ADR 0010](0010-ts-kernel-bun-runtime.md)）：agent 当场写一个 `.ts` 文件，`a2 plugin add` 当场装上、立即可调。2026-08-04 用户裁定三件强耦合的细活——**协议 = exec 一次一调（`describe`/`call`）**、**依赖 = 装载期 install+bundle、运行期全员单文件**、**装载零闸、dangerous 仲裁只在调用层**。

## Context

- 两条接口必须分开看：**agent → 内核**维持纯 CLI（[ADR 0005](0005-agent-first-interaction.md) 既有立场：Bash 起子进程 `a2 … --json` 读 stdout，零协议零配置）；**内核 → 插件**才是本 ADR 要定的那条。
- 业界形态调研的分野：命令面扩展走 exec 流（git / kubectl / cargo / gh），能力面扩展走常驻协议流（LSP / Terraform / MCP），agent 生态在收敛到 MCP。用户在两轮调研后**推翻了「直接采 MCP」的推荐**——MCP 要配置、agent 反而要现学，与北极星「现场写、当场用」相冲。
- 本机实测（`docs/research/ts-kernel-runtime-bun.md`，**未入库**）：`BUN_BE_BUN=1` + `process.execPath` 可把外部 `.ts` 当真子进程拉起（独立 PID / stdout / 可信号控制）；Bun 冷启动约 8ms，撑得住「一次调用一次进程」。但插件 `import` npm 包**严格要求 `node_modules` 在场**，运行时不会现场联网装包。
- 决策原文：`.scratch/kernel-bin-recharter/issues/13-plugin-protocol-loading.md`（含 04 票的进程模型前置）——**本机决策记录，未入库**；本 ADR 正文已自足。

## Decision

- **协议 = exec 一次一调**：内核经自带运行时（`BUN_BE_BUN`）把插件拉起为子进程；`plugin describe` 输出工具清单 + 输入/输出 schema + dangerous 声明（JSON）；`plugin call <tool>` 参数 stdin JSON 进、结果 stdout JSON 出，**退出码即成败**。内核把 describe 出的清单统一暴露到自己的能力面上（[ADR 0004](0004-capability-registry-sole-call-surface.md) 的唯一调用面不变），agent 用 `a2 plugin …` 系列命令像用内置能力一样用插件。
- **MCP 不进 V1**：将来若需对外，可用 adapter 包装 exec 插件；**继续挂起、不排期**，真实需求出现再立效fort。
- **依赖 = 装载期 install + bundle，运行期全员单文件**：零依赖单文件 `.ts` 直接登记（北极星主形态，Bun 内置 API 覆盖面大）；带依赖的目录插件（含 `package.json`）在 `a2 plugin add` 时由内核临时 `bun install` + `bun build --target=bun` 打成**单文件工件**登记，`node_modules` 用完即弃。打不进的怪包（native addon `.node`、动态 require、外带资源）**拒绝 + 指引**，不做半吊子兼容。`bun install` 默认不跑依赖的 lifecycle scripts（供应链缓解）。
- **装载零闸、调用层唯一仲裁**：`a2 plugin add` 即时生效——登记 + 推送审计事件（确认器可见、入日志），**不设装载审批闸**；dangerous 仲裁只发生在 **tool 调用层**，走 [ADR 0005](0005-agent-first-interaction.md) 修订后的三层模型。依据是同 UID 威胁模型：agent 本就能在用户身份下直接执行任意代码，装载闸不新增任何防御，只给北极星加摩擦（Linux 无确认器时，每装一个插件都要人工转告一次）。
- **红线**：**插件 = 进程外子进程，能力只经协议白名单**。这是旧红线「插件不得 import Host\*」在新架构下的等价物，也是 [ADR 0007](0007-mihomo-subprocess-gpl-compliance.md) 「独立子进程、永不进程内链接」红线的泛化——一切插件（不只是 mihomo 壳）都在进程外。

## 与 ADR 0003 的关系

[ADR 0003](0003-build-time-trusted-plugins.md)（构建时可信插件）的**范围部分被本 ADR 取代**——这正是 ADR 0003 自己 Consequences 里预留的路径（「开放第三方插件是显式的将来决定，届时须补进程隔离……并以新 ADR supersede 本条的范围部分」）：

- **被取代**：「插件是 monorepo 内构建时集成的包、不存在运行时装载面」→ 现在有运行时装载面（`a2 plugin add`）；「强逻辑隔离、不做一插件一进程」→ 现在**就是**一插件一进程（且是一次调用一进程）。
- **继续有效**：插件市场、面向不受信任第三方的分发与审核**继续暂缓**（本 ADR 覆盖的是「本机用户/agent 自己写的插件」，威胁模型是同 UID，不是陌生作者）；能力契约要素（稳定 ID、schema、风险分级、结构化错误）继续由 [ADR 0004](0004-capability-registry-sole-call-surface.md) 承载。

## Consequences

- **V1 插件无事件面、无常驻态**（显式的已知限制）：插件不能主动推送事件、不能跨调用保持内存状态。壳所需的事件全部源自内核自身状态，故这条限制在 V1 恰好不疼。
- **每次调用一次冷启动**（约 8ms 量级）：换来的是零常驻资源、崩溃天然隔离、插件升级即换文件。
- **实施首步 spike（未实测项）**：「在 `BUN_BE_BUN` 环境下执行 `bun build` / `bun install`」是高置信**推断**而非实测。它是依赖流的成立条件，须排为实施第一批票；若翻车，回退到运行时层面复议（[ADR 0010](0010-ts-kernel-bun-runtime.md) 的翻车条款），**装载协议本身不受影响**。
- **供应链面诚实记账**：装载期会联网 `bun install`，缓解手段是「不跑 lifecycle scripts + 运行期单文件（无 `node_modules` 残留）」，不是消除风险。
