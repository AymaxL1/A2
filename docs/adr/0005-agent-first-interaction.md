---
status: accepted
date: 2026-07-28
amended: 2026-08-04
---

# agent-first 交互方向：V1 不内嵌 Codex，CLI 为主交互面，dangerous 确认走确认器三层仲裁

> **2026-08-04 修订**：第 4 条已整条替换为**三层仲裁模型**（默拒 / 拒绝即指引 / 确认器带外升级），第 5 条与 Consequences 有连带更新，第 3 条只作术语对齐（实质不变）；第 1/2/6 条不动。改动清单与理由见文末[修订记录](#修订记录2026-08-04)。

2026-07-28 用户反转 agent 交互方向：V1 不做内嵌 Codex 的 Agent 插件（原调研文档 §7 整体撤出 V1），改为**先提供 CLI，让外部 agent（如 Codex）调用本应用**；GUI 是能力面之上的薄壳；dangerous 能力的最终确认必须发生在带外的**确认器**（2026-08-04 修订前为「宿主 GUI」）。

## Context

- 方向反转是本效fort前提 4（[地图](../../.scratch/v1-mac-recharter/map.md) Notes，2026-07-28 用户确认）；示例场景：Codex 调用本应用设置 mihomo 代理。
- 事实基础见 [agent-first-interface.md](../research/agent-first-interface.md)（[05 票](../../.scratch/v1-mac-recharter/issues/05-agent-first-interface.md)）：官方无钦点唯一路径——CLI + AGENTS.md/skills 是零配置合法路径，MCP 是「repo 之外外部工具」的标准正门，plugin 可打包分发；Codex 侧审批可被用户配置整体关闭。
- 原调研文档 [platform-framework-research.md](../research/platform-framework-research.md)：§6（CLI 设计、CLI-vs-MCP 判断）保留并经 05 票强化，其中 CLI 由「官方适配器之一」升为 V1 主交互面；§7（内嵌 Codex：App Server/SDK 选型、AgentRuntime 设计）整体撤出 V1；§7.3 对过度抽象的告诫仍适用（见 Decision 第 6 条）。
- 撤出的连带影响：Swift 路线原最大逆风（官方 Codex SDK 无 Swift）从 V1 关键路径移除（[03 票](../../.scratch/v1-mac-recharter/issues/03-tech-stack-decision.md)、[ADR 0002](0002-swift-native-stack.md)）。

## Decision

1. **V1 不内嵌 Codex**：无应用内 agent 聊天/会话 UI；原文档 §7 整体撤出。将来若回归，按重画目的地的新效fort处理，不在现有规划内延伸（地图 Out of scope）。
2. **CLI 升为 V1 主交互面**：外部 agent 与脚本经 CLI 调用本应用的 capability（`list / describe / call` 形态沿原 §6.1，并按 05 票补强——describe 直接输出 JSON Schema、错误带稳定 code 与可执行下一步以利 agent 自纠、文档化 exit code；具体设计归 [07 票](../../.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md)）。**GUI 是同一能力面之上的薄壳**，不拥有能力面之外的私有业务入口（[ADR 0004](0004-capability-registry-sole-call-surface.md)）。
3. **CLI 永不交互阻塞**：无 TTY 时不等待 stdin；确认语义只能是显式 flag 或宿主 GUI 的 out-of-band 确认（agent 在沙箱内非交互执行命令，交互等待会挂死调用方）。（**2026-08-04 术语对齐**：本条实质不变；其中「宿主 GUI 的 out-of-band 确认」按第 4 条读作**确认器**的带外确认，「显式 flag」不含任何自批旁路——`--yes` 类 flag 永禁。）
4. **dangerous 能力走三层仲裁模型**（2026-08-04 替换原「最终确认必须落宿主 GUI」）。三层叠加，dangerous 的可用性随在场确认面分级，不一刀切：
   - **① 无确认器在场 → 结构化默拒，fail-closed**：内核返回 `confirmation_unavailable` 类结构化拒绝，不等待、不超时猜谜。无 GUI 是一等公民运行形态（[ADR 0008](0008-kernel-bin-ui-optional.md)），默拒是它的**设计行为**而非功能缺失。
   - **② 拒绝报文即指引**：拒绝中携带机器可读的「人类如何完成」精确命令——AI agent 只**转告**，人类自己执行。这是无 GUI 端的零基建默认路径（Linux V1 全靠这一层）。
   - **③ 有注册确认器 → 带外确认**：确认器在场时自动成为首选确认面（mac = 菜单栏壳 `a2-panel`，Touch ID / 点按），**确认信息永不过 AI agent 之手**；CLI 侧仍返回结构化 `confirmation_denied` / `confirmation_timeout`，永不阻塞。
   - **在场 = 长连接**：确认器经 UDS 注册 confirm-agent 角色并保持长连接——连接在即在场、断线即立刻降回第①层；无轮询、无心跳、无陈旧状态窗口；内核校验对端 UID（`getpeereid`/`SO_PEERCRED`）。
   - **`--yes` 类旁路永禁**；**TTY 交互确认禁止**——`isatty` 不构成人类证明（agent 可开伪终端仿冒），人在终端的场景由第②层覆盖。
   - **术语**：**确认器**（confirm agent）= 替人类出面呈现确认并安全回传批准的进程；它是「防 AI agent 自批」机制的执行者。（旧称「确认代理」与网络代理、AI agent 双双撞名，弃用。）
   - 理由不变（05 票）：Codex 层审批（sandbox/approval/rules）可被用户配置整体关闭（`approval_policy="never"`、`danger-full-access`、allow 规则）；`--yes` 类 flag 会被 agent 自己传上，等于不设防；MCP 规范明言注解只是 hint。故 Codex 层审批只作加分、不作依赖。技术底盘：同 UID 且无 GUI 时内核无法分辨「人敲的」与「agent 跑的」，故一切经 agent 之手的「确认」一律视同自批、不承认。safe（只读）直通；normal（可逆写）依赖 Codex 层审批 + 幂等键/receipt 兜底。（风险分级承载于 [ADR 0004](0004-capability-registry-sole-call-surface.md) 的契约；代理插件各能力的具体分级归 [04 票](../../.scratch/v1-mac-recharter/issues/04-proxy-plugin-v1-scope.md)。）
   - **跨端只定协议插槽**：确认器协议（角色注册 / 长连接即在场 / 对端 UID 校验 / 确认请求-响应报文）是跨端的，V1 唯一实现 = mac 菜单栏壳；带外通道（手机推送 + token 回填等）将来按同一协议接入。
5. **MCP adapter 后补**：capability registry 稳定后补薄 MCP adapter（方向沿原 §6.2；05 票新增两个理由：per-tool 审批与 destructive 注解联动、plugin 目录分发面）。（**2026-08-04 修订**：MCP 已裁定**不进 V1、继续挂起不排期**，将来可用 adapter 包装 exec 插件，真实需求出现再立效fort——见 [ADR 0011](0011-plugin-exec-protocol-loading.md)。）
6. **AgentRuntime seam 处置（2026-07-28 用户确认）**：**不预留抽象**。原 §7.2 的 `AgentRuntime` / adapter 分层随 §7 一并撤出，V1 不保留其接口、不为「将来内嵌 agent 回归」预留 seam——YAGNI，呼应原 §7.3 的告诫（「第二个真实 adapter 出现前不冻结过度抽象」；V1 连第一个内嵌 adapter 都不存在，预留的抽象没有真实消费方）。将来若内嵌 agent 回归，按届时效fort重新设计，不受今日预设形状约束。

## Consequences

- CLI 从「官方适配器之一」变为必交付物；agent 可用性（可发现、可自纠、可脚本化）成为能力设计的验收维度。（**2026-08-04**：CLI 进一步升为**唯一必需**交互面。）
- 确认器新增职责：dangerous 确认呈现，须展示动作的真实参数、防「agent 替用户点确认」的社工话术（05 票引 MCP 客户端指引）。（**2026-08-04**：该职责原记在「宿主 GUI」名下，现由可选的菜单栏壳以确认器角色承担；壳缺席时不降级为「无确认」，而是降级为**默拒**。）
- 随产品分发 agent 指引物（AGENTS.md 片段 / skill / rules 建议片段）成为产品动作而非用户作业（05 票建议；落地归 07/08 票）。
- 已知风险状态：workspace-write 沙箱拦截本地 IPC 已被 S3 spike **证实**（2026-07-28，UDS/localhost 全拦；对策 = `prefix_rule` 提权信任，见 [07 票](../../.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md)回写与 `Spikes/S3CodexSandbox/README.md`）；CLI vs MCP 的实际发现质量仍待实测。
- 接受的代价：V1 没有应用内 agent 体验（会话 UI、流式过程展示）；agent 场景依赖用户已安装的外部 agent（如 Codex）。

## 修订记录（2026-08-04）

架构反转（[ADR 0008](0008-kernel-bin-ui-optional.md)）把「宿主 GUI 一定在」这条隐含前提拆了，原第 4 条随之重设计。用户 2026-08-04 现场面试五问逐条拍板（决策原文：`.scratch/kernel-bin-recharter/issues/05-dangerous-confirm-redesign.md`，**本机决策记录，未入库**），改动如下：

1. **第 4 条整条替换**：「dangerous 最终确认必须落宿主 GUI」→ **三层仲裁模型**（默拒 fail-closed / 拒绝即指引 / 确认器带外升级）。触发事实：无 GUI 成为一等公民运行形态后，「必须落 GUI」等于「无 GUI 端 dangerous 不可用且无出路」；第②层「拒绝即指引」补上了那条出路，且不给 agent 任何自批的口子。
2. **新增「在场 = 长连接」判据**：确认器注册角色 + 保持长连接，断线即降级；不用心跳、不用轮询、不设陈旧状态窗口；内核校验对端 UID。
3. **新增 TTY 禁令**：原文只说「CLI 永不交互阻塞」（第 3 条，不动），本次显式补上「TTY 在场也不许交互确认」——`isatty` 不是人类证明。
4. **术语统一**：确认动作的承担者称**确认器**（confirm agent），不再称「宿主 GUI」或「确认代理」。
5. **第 5 条连带更新**：MCP adapter 的时点已裁——不进 V1、继续挂起不排期（[ADR 0011](0011-plugin-exec-protocol-loading.md)）。
6. **agent-delegation 连带**：委托执行器的审批**收敛到内核统一仲裁**（同三层、同确认器通道、同禁旁路、统一 audit），无确认器时「拒绝即指引」结构化回传发起方。修订指令已下达至 `.scratch/agent-delegation/spec.md` 文末。
7. **不变的**：第 1/2/3/6 条原样有效；`--yes` 类旁路永禁；safe/normal/dangerous 三档分级不变。

## 实施补记（2026-08-05）：在场机制的两条已知边界

第 4 条的「在场 = 长连接 + 内核校验对端 UID」在内核里落地时，暴露出两条**必须写明的边界**——它们不是缺陷，是这套机制**保护范围的边沿**。实现出处：`kernel/src/daemon/peer.ts`、`kernel/src/daemon/hub.ts`；威胁模型口径沿用 06 票（壳契约）的裁定（`.scratch/kernel-bin-recharter/issues/06-ui-shell-contract.md`，**本机决策记录，未入库**）。

1. **同 UID 冒充确认器 = 已知边界，V1 不设防**。角色注册报文里的身份声明（自报的名字，以及为将来预留的 cdhash / 团队 ID 两个插槽）**内核一律收下、不校验**——与内核同 UID 的任意本机进程都可以注册成 confirm-agent 并替人批准 dangerous。这是有意的：仲裁保护的是**受认可路径上的 AI agent 不能自批**，不对抗已经拿到该用户身份的任意本机代码——那样的攻击者可以直接替换 `a2` 这个二进制，任何协议层校验都拦不住。将来的强化路径是用 peer 凭据里的 pid 反查可执行文件并核对 cdhash / 团队 ID，插槽已在契约里留好（`RoleRegisterParams.identity`）。

2. **对端凭据问不出来时放行（fail-open），但绝不静默**。UID 校验是**纵深的第三道门**：前两道是 `<A2_HOME>/run` 目录 0700 与 socket 文件 0600，由操作系统强制，别的用户在 `connect()` 那一步就被拒了。若 `bun:ffi` 在某个平台上取不到 `getpeereid`/`SO_PEERCRED`（或运行时不再暴露 socket fd），内核**放行**而不是拒绝一切连接——后者是"零收益换不可用"。代价由留痕补偿：每一次都记一条 `peer_unverified` 审计事件（按原因去重 + 限频），且该连接在快照与审计里的 `uid` 字段**缺省**，不伪造一个值。**凭据问得出来但对不上 UID 的，一律拒**（`peer_rejected`）——那才是真信号。
