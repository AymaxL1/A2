---
status: accepted
date: 2026-08-04
supersedes: ADR-0001
---

# 端范围：内核承诺 macOS + Linux，Windows 是远景且不设预留，UI 仅 Mac

内核 bin 化（[ADR 0008](0008-kernel-bin-ui-optional.md)）把「跨端」从远景愿望改成**当下承诺**，[ADR 0001](0001-mac-only-platform-boundary.md)（Mac-only / Mac-first）随之废止。2026-08-04 用户裁定：**内核当下承诺 macOS + Linux**；**Windows 明确是远景，且不为它设任何预留约束**；**UI 只做 Mac**。

## Context

- ADR 0001 把平台承诺收缩为 Mac-only，理由是三端承诺把技术栈锁在 Electron 系、为无真实需求的跨端能力持续付成本。这个理由在「UI 三端」的语境下成立；本次反转后，需要跨端的是**无头内核**（CLI 面），不是 UI——两者的成本结构完全不同，故重开并推翻。
- 事实输入（本机调研 `docs/research/kernel-language-cross-platform.md`，未入库）：Swift 在 Linux 上扎实、在 Windows 上官方自认仍在补课；本机盘点显示平台绑定面只有 AppKit 三个壳 target（2386 行 / 18.9%），其余 10213 行纯逻辑可携带；**Windows 是常驻（SCM）、UDS（仅 SOCK_STREAM、无对端凭据）、POSIX 三处都要重新设计的独立一档**，不是「多编译一个 target」。
- 决策原文：`.scratch/kernel-bin-recharter/issues/01-premises-confirm.md`（跨端 = 当下承诺）与 `.../10-kernel-language-decision.md`（端范围连同语言一起裁）——**本机决策记录，未入库**；本 ADR 正文已自足。

## Decision

- **当下承诺 = macOS + Linux**：内核 bin `a2` 在两端都构建、都测试、都分发；路径与 unit 命名两端同形（`~/.a2`、`com.a2.*`），常驻分别落 launchd user 域与 systemd user unit。
- **Windows = 远景，且不设预留约束**：设计时**不背「别封死 Windows」的包袱**——不为它保留抽象、不做兼容折衷。将来若要做，现有的 UDS Transport 缝隙是天然的接入位置，但那是届时的新效fort，接受届时的重设计。
- **UI 仅 Mac**：菜单栏壳 `a2-panel` 只在 macOS 存在（Touch ID / 系统通知要求 app bundle 身份，是 macOS 的平台事实）。其他端**不做 UI**：Linux 端 V1 无确认器，dangerous 默拒即设计行为，而非功能缺失（[ADR 0005](0005-agent-first-interaction.md) 修订后的第 4 条第①层）。
- **重开条件**：Windows/其他端 UI 仅在真实需求出现时按新效fort重开，本批决定不预设触发判据。

## Consequences

- **门禁多一端**：Linux 交叉编译产物与 systemd 代码路径进门禁（单元级）。**Linux 实机端到端验收未裁**，默认随人工项节奏顺延（如需提前由用户裁定）——记为已知缺口，不是已完成项。
- **平台假设必须显式化**：原 `AAPaths.swift` 里的 macOS 路径假设（纯逻辑区唯一的平台绑定点）由统一的 `~/.a2` 约定取代；对端身份校验两端不同实现（macOS `getpeereid()`、Linux `SO_PEERCRED`），是有意的分叉而非抽象泄漏。
- **接受的代价**：Windows 将来是含核心改动的重写（与 ADR 0001 对 Windows 的态度一致，只是本 ADR 把 Linux 从「远景」提到「承诺」）；两端 UI 不对等是刻意设计——无 GUI 端靠「默拒 + 拒绝即指引」拿到完整可用性，不靠补一个 Linux UI。
