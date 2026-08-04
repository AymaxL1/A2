---
status: accepted
date: 2026-08-04
---

# 架构反转：内核 bin 化，CLI 为唯一必需交互面，UI 降为可选壳

2026-08-04 用户裁定把架构整个反转过来：主逻辑从 GUI 宿主（`aahost`）搬进一个无头内核 bin（`a2`），**CLI 是唯一必需的交互面**，**无 GUI 是一等公民运行形态**（dangerous 在无确认器时结构化默拒），UI（Mac 菜单栏壳）降为**可选的对等客户端**。这是一次大重构，本 ADR 是该批决定的总纲。

## Context

- **反转前的现状**：`aahost`（GUI 常驻进程）持有全部主逻辑——capability 注册表、UDS server、插件宿主、mihomo 生命周期；`aa` 只是薄 CLI 客户端。UI 是必需品，agent 是客人。这与项目宗旨（agent-first）反向：[ADR 0005](0005-agent-first-interaction.md) 已把 CLI 定为主交互面，但主逻辑仍押在 GUI 进程上，无 GUI 形态根本跑不起来。
- **用户前提（2026-08-04 原话，经现场面试逐条钉死）**：①主逻辑完全不依赖 UI；②内核完全是 bin、经 CLI 使用；③agent first 是最高宗旨；④UI 不再是必须的，Mac 的 UI 先用 Swift，其他端先不做 UI；⑤定性为一次大重构。
- **决策原文**：本机决策记录 `.scratch/kernel-bin-recharter/`（13 张票，其中 01 票钉死前提与裁决序、04 票钉死进程模型、05 票钉死仲裁模型、06 票钉死壳契约、07 票钉死蓝图与命名、08 票收图）与实施 spec `.scratch/a2-kernel/spec.md`。这些文件不入库，本批 ADR 承担「读 docs 即可完整理解新架构」的职责。

## Decision

1. **主逻辑零 UI 依赖**：capability 注册表、运行时、UDS server、插件宿主、mihomo 监督、dangerous 仲裁、（将来的）agent 委托执行器，全部住在无头内核里；Swift 侧不留任何业务逻辑。
2. **CLI 是唯一必需交互面**：外部 agent 用 Bash 起子进程执行 `a2 <子命令> --json` 并从 stdout 读结构化结果——零协议、零配置、零 SDK。每条命令有稳定的机读输出 schema 与退出码语义；**CLI 永不交互阻塞**（[ADR 0005](0005-agent-first-interaction.md) 第 3 条不动）。
3. **无 GUI 是一等公民运行形态**：内核 + CLI 可独立分发、全功能可用（Linux 无头用户与 mac 终端用户走同一套命令面，不存在阉割版）。唯一的分级点是 dangerous：无确认器在场时结构化默拒（`confirmation_unavailable`，fail-closed），且拒绝报文自带机器可读的「人类如何完成」精确命令——agent 只转告，人类自己执行。详见 [ADR 0005](0005-agent-first-interaction.md) 修订后的第 4 条。
4. **裁决序（本项目通用）**：**安全底线 > 法律义务（GPL）> agent-first > 人类便利**。agent-first 压倒人类 UX（结构化输出、永不交互阻塞、GUI 只是内核的又一个客户端），但压不过「dangerous 需真人在场证明」与 GPL 义务履行；反过来，法律义务的**落点**必须 CLI 化，不得依赖 UI（见 [ADR 0007](0007-mihomo-subprocess-gpl-compliance.md) 修订）。
5. **UI = 可选的对等客户端**：Mac 菜单栏壳 `a2-panel`（.app 显示名「A2 Panel」）与其他客户端走同一条 UDS capability 面，**无特权通道**；确认器（confirm agent）与订阅者（subscriber）只是长连接上注册的**角色**。壳只做两件事——内核事件流的投影（全量快照 + 增量推送，零轮询）与确认器呈现；**`a2-panel` 不得含业务逻辑**（新架构下的结构红线）。壳缺席/崩溃时内核静默运行：事件入日志、CLI 可查、dangerous 自动降回默拒。**「退出即还原」语义废除**——系统代理还原等动作改挂内核显式命令，壳退出仅是客户端断连。
6. **常驻 = 显式安装 + 系统托管**：一个编译产物多模式（默认 CLI，`a2 daemon run` 进前台常驻）；`a2 service install|uninstall|status` 落 launchd user 域 plist / systemd user unit，开机自启与崩溃自愈全归系统 supervisor，应用层不造看门狗。未安装/未运行时 CLI **永不隐式拉起** daemon，返回含精确修复命令的结构化指引（与「拒绝即指引」同构）——系统状态永远不因 agent 的一次查询而被动改变。
7. **命名与路径统一 a2 系**（品牌级改名，原 `aa` 系全面退场）：bin `a2`、常驻 `a2 daemon run`、服务 `a2 service …`、壳 target `a2-panel`；路径 `~/.a2`（`A2_HOME` 可覆写）、socket `~/.a2/run/kernel.sock`、unit 命名空间 `com.a2.*`。中文概念名不变（「菜单栏壳」「确认器」）。

## Consequences

- **一次大重构**：`aahost` 职责全迁内核，`aa` 被整体接替，`aa-agent` 挂起；迁移按六步走，每步可合并、门禁绿——①契约与骨架 → ②控制面重建 → ③mihomo 监督面 → ④仲裁与确认器协议 → ⑤**壳原子切换**（唯一门禁切换点）→ ⑥插件宿主。**Phase 1 出口判据改为第⑤步完成**（见 [v1-roadmap.md](../v1-roadmap.md)）。
- **本批连带的 ADR 处置**：[ADR 0001](0001-mac-only-platform-boundary.md) 与 [ADR 0002](0002-swift-native-stack.md) 废止重立（→ [0009](0009-kernel-platform-scope.md) / [0010](0010-ts-kernel-bun-runtime.md)）；[ADR 0005](0005-agent-first-interaction.md) 第 4 条与 [ADR 0007](0007-mihomo-subprocess-gpl-compliance.md) 修订；新增 [ADR 0011](0011-plugin-exec-protocol-loading.md)（插件 exec 协议与装载）。[ADR 0004](0004-capability-registry-sole-call-surface.md)（能力面唯一事实源）与 [ADR 0006](0006-local-first-no-cloud.md)（local-first）不受影响，只是「唯一调用面」的实现从 Swift 宿主换成 TS 内核。
- **安全模型的结构性变化**：「防 agent 自批」不再依赖「GUI 一定在」，而是依赖**确认器在场与否的显式分级**——在场则带外确认，不在场则 fail-closed 默拒。这让无 GUI 端不必为了安全而假装有 UI，也让 dangerous 的可用性变成一条可观测的运行时事实（长连接在/不在）。
- **接受的代价**：既有 Swift 逻辑与测试不再是主干实现，整体降级为 TS 重写期的**行为规范参考**（规模数字与行为对等映射口径见 [v1-roadmap.md](../v1-roadmap.md) Phase 1「行为规范参考与断言迁移」，此处不复述）；重构期间主干必须一直可用，代价是六步切法带来的额外协调成本。
- **可审计的两条结构红线**（旧红线在新图的等价物）：「插件不得 import Host\*」→「插件 = 进程外子进程，能力只经协议白名单」（[ADR 0011](0011-plugin-exec-protocol-loading.md)）；「GUI 是薄壳」→「`a2-panel` 不得含业务逻辑」。

## 实施补记（2026-08-05）：安全边界的显式范围

第 5 条把确认器与订阅者定为「长连接上注册的**角色**、无特权通道」。这套设计的保护范围有明确的边沿，落地时一并钉死在这里（详版与实现出处见 [ADR 0005](0005-agent-first-interaction.md) 文末「实施补记」）：

- **保护的是**：受认可路径上的 AI agent 无法自批 dangerous——它没有任何报文能替人做决定，确认只能来自另一条注册了 confirm-agent 角色的连接；无确认器时 fail-closed 默拒。
- **不保护的是**：与内核**同 UID** 的敌意本机代码。它可以冒充确认器（V1 不验签，身份强化字段只是预留插槽），更可以直接替换 `a2` 二进制——那已经不是协议层能拦的事。这条口径来自 06 票（壳契约）的威胁模型裁定，不是本次新裁。
- **对端 UID 校验的定位**：纵深的**第三道门**，前两道（`run/` 0700、socket 0600）由操作系统强制。凭据取不到时**放行并留痕**（`peer_unverified` 审计事件），取得到但对不上时**拒绝并留痕**（`peer_rejected`）。选择 fail-open 的理由是：前两道门完好时，把整个内核锁死属于零收益换不可用。
- **不在保护范围内也不假装在**：这三条写进 ADR，是为了让「a2 的安全模型到底挡住了谁」这句话在文档层面就有确定答案，而不是留给读代码的人去推断。
