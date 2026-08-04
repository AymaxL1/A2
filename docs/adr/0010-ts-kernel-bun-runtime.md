---
status: accepted
date: 2026-08-04
supersedes: ADR-0002
---

# 技术栈：TS 内核（Bun compile 单文件 bin）+ Swift Mac 壳

内核 bin 化与跨端承诺（[ADR 0008](0008-kernel-bin-ui-optional.md)、[ADR 0009](0009-kernel-platform-scope.md)）触发技术栈全面重议，[ADR 0002](0002-swift-native-stack.md)（Swift 原生全栈）随之废止。2026-08-04 用户裁定：**内核用 TypeScript 重写**，运行时基线为 **Bun compile 单文件 bin**（产物即 `a2`）；**Mac 菜单栏壳继续用 Swift**，经 UDS 与内核通信；同仓 monorepo，**契约以 TS 为单一事实源**。

## Context

- ADR 0002 的前提是 Mac-only + UI 是必需品；反转后内核要跨端、要能把 agent 现场写的插件当子进程拉起，前提消失，语言全重议（用户首先明确排除「Swift 跨端」这条唯一免重写路线）。
- **关键定性**：本内核是**控制面**不是数据面——流量在 mihomo 子进程里，内核只做生命周期、注册表、UDS API、确认仲裁。因此 Rust 的性能优势兑现不了，TS 的 GC/吞吐短板也大半打不到。
- **决定性裁定**：插件北极星 =「**agent 现场写插件**」——插件≈一个 `.ts` 文本文件，agent 当场写、当场装、当场调用，内核 bin 用自带运行时把它作**子进程**拉起。此形态只有 TS 内核能做到最轻（Go 只能嵌 goja 折中）。安全（进程外隔离）与法律（跨语言天然隔离 mihomo）两关皆过之后，按裁决序轮到 agent-first 说话。
- **本机实测背书**（`docs/research/ts-kernel-runtime-bun.md`，未入库）：Bun compile 产物 60.5MiB、冷启动 7.7–13ms、常驻 RSS 26.4MiB；`--target=bun-linux-x64` 交叉编译产出合法 ELF；编译产物内部 `Bun.spawn(process.execPath, …, { BUN_BE_BUN: "1" })` 能把编译期完全不存在的外部 `.ts` 当真正的子进程拉起；`bun:ffi` + `node:net` 取 fd 调 `getpeereid()` 在 macOS 完整打通。
- 决策原文：`.scratch/kernel-bin-recharter/issues/10-kernel-language-decision.md`、`.../11-ts-runtime-bun-verification.md`、`.../07-target-architecture-mapping.md`——**本机决策记录，未入库**；本 ADR 正文已自足。

## Decision

- **内核语言 = TypeScript**，运行时基线 = **Bun compile 单文件 bin**：一个编译产物承担 CLI、daemon（`a2 daemon run`）与插件运行时（`BUN_BE_BUN`）三种模式——daemon 与 CLI 天然同版本，不存在双 bin 的体积与版本漂移问题。
- **翻车条款**：若 Bun 在实施中翻车，**复议的是运行时**（Node SEA / Deno compile 等），**语言裁定不自动重开**。注意 Node SEA 与 Deno compile 已因「不支持运行时执行外部脚本」被文档级排除——它们撑不起插件北极星。
- **Mac 壳留 Swift**：`a2-panel` 及 UI 资产（「一个模型两个渲染器」与手搓快照测试、XcodeGen .app 工程）全套保留、只改喂养源（从直读 runtime 改为内核事件流投影）。Touch ID / 系统通知要求 bundle 身份，这是 .app 工程必须保留的原因。
- **仓库形态 = 同仓 monorepo**：新增 `kernel/`（TS 工程：`src/`、`package.json`、`bun.lock`、协议 schema），Swift 壳继续住 `Sources/`。协议同仓同步演进、切换原子、git 历史连续。
- **契约 TS 为源、不引入代码生成链**：报文类型在 `kernel/` 以可序列化 schema（zod 类）定义并导出 JSON Schema（机器可读契约，也是 agent 写客户端/插件的土壤）；Swift 侧**手写 Codable 对照**；双端对同一批**金标报文样本**做编解码快照，契约漂移即门禁报警。

## Considered Options

- **Swift 跨端（免重写）**：用户首先排除，不再评估。
- **Go**：daemon 工况成熟度最高（tailscaled 同款拓扑、小 bin、peercred 一等公民），但插件北极星只有嵌 JS 引擎的折中解；且同语言 `import` mihomo 在语法上与普通库调用无异，**放大**了误入 GPL 衍生作品陷阱的门槛问题（[ADR 0007](0007-mihomo-subprocess-gpl-compliance.md) 的进程内链接红线语言无关，但 Go 下需要额外的 CI 纪律看守）。
- **Rust**：控制面用不到其运行时优势，重写最慢、agent 迭代摩擦最大，插件北极星同样要嵌 JS 引擎。

## Consequences

用户明确认下的账单：

- **全量重建**：既有 Swift 逻辑与测试全部在 TS 侧重建，旧代码与断言降级为**行为规范参考**（规模数字与行为对等映射口径见 [v1-roadmap.md](../v1-roadmap.md) Phase 1「行为规范参考与断言迁移」，此处不复述）。
- **体积与内存换来的**：单 bin 约 60–90MB、常驻 RSS 比原生高一档，换到的是「单文件下载即用 + 自带插件运行时」。
- **自己踩路**：UDS 对端凭据走 FFI（`getpeereid`/`SO_PEERCRED`）；Bun 的 UDS 权限跟随 umask，内核必须自建 socket 父目录 0700 并在 bind 后显式收紧权限；launchd/systemd 集成在 Bun 生态里没有成熟先例可抄。
- **ADR 0002 的「回退候选 Electron+TS」条款早已于 2026-07-28 的 electron-recon 重评中行使并了结**，本 ADR 不复活它：这次换的是**内核语言与运行时**，不是把 UI 搬回 Web——Mac UI 仍是原生 Swift。
- 契约由 TS 定义、Swift 手写对照，代价是双端各写一次；换来的是无代码生成链、契约漂移在门禁层被抓住。
