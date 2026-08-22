---
status: accepted
date: 2026-08-09
---

# 面板自足引导：`.app` 内嵌内核 bin，显式点击装内核

2026-08-09 用户裁定：`A2 Panel.app` 从「纯壳」变成**自带内核的完整分发单元**——包里嵌一份内核 bin，mac 用户下载、打开、点一次「安装并启动」就能用上，不必先开终端。这不改 [ADR 0008](0008-kernel-bin-ui-optional.md) 的任何一条立场（CLI 仍是唯一必需交互面、壳仍是可选的对等客户端、系统状态仍只由显式动作改变），改的是**「显式」可以从哪里发起**。

## Context

- **实际卡住的地方**：[ADR 0008](0008-kernel-bin-ui-optional.md) 第 6 条定了「常驻 = 显式安装 + 系统托管」，10 票的壳照此实现为纯壳（包里只有 `Contents/MacOS/a2-panel`）。于是一个只想点图标的 mac 用户的真实路径是：开终端 → `curl … | sh` 或手动下单文件 → `a2 service install` → 再回来双击 `.app`。**「可选客户端」在实践中前置了一段命令行**，而 mac 上想要 dangerous 确认弹窗的恰恰是最不想开终端的那批人。
- **multica 的桌面端形态（参照要点）**：把 Go 二进制**打进 `.app`**、**GUI 只当发起者**（不自己实现业务逻辑）、**GUI 不把 CLI 装进 PATH**、**bin 版本随 app 走**（换 app 就换 bin，不做两条独立升级线）。这四条与本项目的薄壳铁律同向，本次原样采纳。
- **a2 与 multica 的分野**：multica 的 daemon 是 GUI **fork 出来的子进程、无看门狗**。a2 **不学这一条**——常驻仍归 launchd 用户域托管（`RunAtLoad` + `KeepAlive.Crashed`），开机自启与崩溃自愈归系统 supervisor，应用层不造看门狗（[ADR 0008](0008-kernel-bin-ui-optional.md) 第 6 条不动）。旧版壳退出只断连；2026-08-22 的生命周期修订见下。
- **macOS 的两条环境事实**：①**App Translocation**——带 `com.apple.quarantine` 的 app 从非标准位置首次启动时，系统会把它挂到一个随机只读位置再运行，包内绝对路径因此**不稳定**（【推断/高质量二手】，见 `docs/research/kernel-daemon-topology.md` §3，**该研究文档未入库**；本仓库未实测 translocation 本身）；②本地构建的 `.app` 不带 quarantine、但浏览器下载的 zip 会带，而 ad-hoc 签名的包过不了 Gatekeeper（**13 票本机实测**，见 [签名 runbook](../runbooks/signing-and-authorization.md) §6.1）。
- **决策原文**：`.scratch/a2-kernel/issues/14-panel-embed-kernel.md`（打包与门禁）、`15-service-copy-to-home.md`（内核侧机制）、`16-panel-bootstrap-ui.md`（UI）——**本机决策记录，未入库**；本 ADR 正文自足。

## Decision

1. **`.app` 自足**：`Contents/Resources/a2` 内嵌**本次构建的**内核 bin（`Scripts/build-app.sh`）。签名**先内后外**（先签内嵌 bin、再签 bundle，同一 identity，**不用 `--deep`**）；包结构红线因此从「恰 1 个 Mach-O」修订为「**恰 2 个，且就是壳与内嵌内核那两条路径**」，另加两条断言：内嵌 bin 实跑 `version` = 内核版本单一来源、`lipo` 判 arm64 单架构。于是 `A2-Panel-<版本>-macos.zip` 成为**小白的完整包**。
2. **显式点击边界**：壳**仍不隐式拉起任何东西**。启动时不自动装、连不上不自动起、退出不自动停。改变系统状态的只有**用户的一次显式点击**：首启（且内核未装）弹一次说明框——说清装什么（launchd 用户服务 `com.a2.kernel`、创建 `~/.a2`）、怎么卸，两个按钮「安装并启动」/「稍后」；选了「稍后」就不再纠缠，菜单项常驻可随时再装。[ADR 0008](0008-kernel-bin-ui-optional.md) 第 6 条「永不隐式拉起」的**精神不变**：多的是一条**显式发起路径**，不是一条自动路径。

   > **修订（2026-08-22，小白生命周期收口）**：用户打开 Panel 即显式表达“启动 A2”；若服务已安装但停着，Panel 只执行 `service start`，不安装、不升级、不改 unit。用户点「退出 A2」时，Panel 必须先在接管态执行 `proxy off`，再执行 `service stop`，成功后才退出；daemon 的正常退出钩子负责收掉内嵌 mihomo。unit、开机自启登记和 `$A2_HOME` 都保留，所以下次打开可直接 `start`。旧文“退出只断连”由此废止；意外崩溃不伪装成用户退出，仍由 launchd 自愈。

   > **修订（2026-08-18，[ADR 0014](0014-mihomo-embedded-subprocess.md)，同日 07 票追记后的终形）**：首启弹窗**内容与授权范围不变**（仍只装内核服务 + 建 `~/.a2`）——mihomo 的初始化不进首启流，全归 agent 对话（0014 第 3 条）。
3. **执行器白名单**：面板经内嵌 bin 执行的命令**只有四条**——`service install`（带 `--copy-to-home`）、`service uninstall`、`service status`、`version`，全部走机读 JSON 输出。白名单是硬的：壳里没有第二条通往内核 bin 的路，也没有「随便执行一条 a2 命令」的口子。壳仍**不含业务逻辑**（[ADR 0008](0008-kernel-bin-ui-optional.md) 第 5 条结构红线不破）：它只发起命令、解析机读结果、呈现。

   > **修订（2026-08-10，17 票）**：白名单**恰增一条**，共五条——新增 `service uninstall --purge --json`（第 6 条那个「同时删除 ~/.a2」勾选走的就是它）。它与不带 `--purge` 的那条**各占一个枚举成员**，而不是同一条命令的一个布尔参数：会删数据的形态必须自己占一行、进那份逐字对照的断言，否则「白名单是硬的」就只剩一句口号。其余不变——仍全部走机读 JSON，壳仍不含业务逻辑（删什么、拒不拒绝全在内核里判）。

   > **修订（2026-08-18，[ADR 0014](0014-mihomo-embedded-subprocess.md)，同日 07 票追记后的终形）**：白名单**恰增两条**——`mihomo status --json` 与 `mihomo restart --json`（enable/disable 不进面板，初始化归 agent），原则不变：每条占一个枚举成员、逐字进断言。另：面板新增纯本地 agent 入口，不经 CLI、不入白名单；未安装也出现，内容随状态自适应。第 7 条（不进 PATH）**原样不动**，剪贴板提示词是它的补偿面。

   > **修订（2026-08-22，A2 skill 入口）**：该菜单项改名「**初始化 A2（添加到 AI 助手）**」。提示词让 agent 在**当前用户的全局 skill 目录**创建或更新名为 `a2` 的个人 skill，明文禁止创建成项目/仓库级 skill；skill 本身只调用 `~/.a2/bin/a2 guide` 并按实时输出工作，**不复制 guide 正文、命令或流程**。所有功能与升级内容只维护在内核 guide。

   > **修订（2026-08-22）**：白名单再增三条生命周期命令：`service start --json`、`service stop --json`、`proxy off --json`。最后一条只用于安全退出时还原系统代理，不开放任意 proxy argv。
4. **unit 指向 `$A2_HOME/bin/a2` 的拷贝，不指进 `.app`**。`a2 service install --copy-to-home` 把自身原子拷到 `$A2_HOME/bin/a2` 并让 unit 指向拷贝（机制归 15 票，面板不碰文件系统）。三条理由：
   - **免疫 translocation**：包内路径在带 quarantine 的首启下不稳定，写进 unit 的绝对路径会指向一个下次就不存在的位置；
   - **挪包 / 删包不断服**：用户把 `.app` 从 Downloads 拖进 `/Applications`、改名、或干脆删掉，已经在跑的服务不该跟着死；
   - **两条升级线解耦**：换 app 与换内核是两件可以分开发生的事（见第 5 条）。
5. **升级永远显式**：面板启动时问一次内嵌 bin 的版本、与线上内核版本比对（不轮询）；不一致才在菜单出「升级内核 vX→vY」，**点了才升**。不后台自查、不静默替换——与 `a2 about` 的 `upgrade` 字段、安装脚本的收尾提示同一条口径（[ADR 0006](0006-local-first-no-cloud.md) 暂缓清单）。
6. **卸载对等**：能装就能卸。「停止并卸载内核服务」走同一条白名单（`service uninstall`，带确认弹窗），**只拆 unit**；`$A2_HOME/bin/a2` 那份拷贝与 `~/.a2` 里的数据留给显式清理——与 `install.sh --uninstall` 的「先看后删」是同一种姿势（数据同侧的东西不由一次点击带走）。**删掉 `.app` 不会卸掉已装的服务**，这正是第 4 条拷贝的直接后果，必须在 runbook 里说明。

   > **修订（2026-08-10，17 票）**：「留给显式清理」补上**那条显式清理本身**——`a2 service uninstall --purge`，以及卸载确认框里一个**默认不勾**的「同时删除 ~/.a2」勾选。理由：原文把「不由一次点击带走」实现成了「压根没有一条路能带走」，于是小白的实际卸载路径止步于「删掉 .app，`~/.a2` 与两个 launchd 服务全留着」——**删 ≠ 净**。修订后的口径是「删得净，但只走显式路径」：不勾时行为一字不变（只拆 unit）；勾了才依次拆 `com.a2.kernel`、拆 a2 自管的 `com.a2.mihomo`、删整个 `$A2_HOME`，机读面给出移除的 label 与删掉的绝对路径（先看后删的账）。两条边界随之写死：①**范围恒为 `com.a2.*` 与 `$A2_HOME`**，用户自己装的 mihomo（`io.metacubex.mihomo`）在任何路径下都不在清理范围内，契约层由 label 形状（`^com\.a2\.`）钉着；②**系统代理仍处接管态时结构化拒绝且零删除**（`service_purge_blocked`，退出码 1，拒绝即指引）——接管快照是还原的唯一依据，随 `$A2_HOME` 一起删掉就再也还原不回去；还原仍然只有显式命令一条路，卸载**绝不**顺手替人做。于是零残留路径 = 菜单卸载（勾选）→ 拖 `.app` 进垃圾桶，除 macOS 惯例的偏好 plist 外不留东西。
7. **面板不提供「装 CLI 到 PATH」**：没有这个按钮，不写 shell 配置，不建 symlink。包里那份 bin 是**面板的执行器**，不是给终端用的。要 CLI 的人走既有渠道（单文件下载 / `install.sh`），那条渠道**一字不动**。
8. **签名与 quarantine 的如实口径**：ad-hoc 是 Phase 1 的终态；真开发者证书 + 公证仍是人工项，届时内嵌 bin **随链先签**（同一个 `AA_CODESIGN_IDENTITY`，顺序不变）。内嵌 bin 进的是 bundle 的**资源封印**——本票实测：改它一个字节，`codesign --verify --strict` 即报 `a sealed resource is missing or invalid`。

## Consequences

- **包大了一个数量级**：`.app` 从 1.6MiB 到 **63MiB**，zip **约 24.5MiB**（内核 bin 内置完整 Bun 运行时，见 [ADR 0010](0010-ts-kernel-bun-runtime.md)）。这是「不必开终端」的直接价格，收下。
- **一个发布包里出现两处内核**（单文件那份与 `.app` 里那份）→ 发布元数据加 `embeddedKernelVersion` 字段，并有 **fail-closed 的三处对账**：schema 拒绝「面板包不记内嵌版本」与「两版内核」，组装脚本再解一遍最终 zip 实跑一次核对（`Scripts/release-assemble.sh` 自检）。
- **出包要两条工具链**：壳要 `swift`，内嵌内核要 `bun`。以前 `.app` 里没有内核，出包不关 bun 的事。
- **两条分发渠道彻底独立**：只拿 `.app` 的人不需要 PATH 上有 `a2`；只拿 CLI 的人不需要 `.app`。两条都要的人机器上会有两份 bin（PATH 一份、`$A2_HOME/bin` 一份），各自显式升级——这是有意的解耦，代价是 runbook 必须写清「谁管谁」。
- **对 [ADR 0008](0008-kernel-bin-ui-optional.md) 的处置**：第 5 条（壳 = 可选的对等客户端、无业务逻辑）与第 6 条（显式安装 + 系统托管、永不隐式拉起）**都不改写**，第 6 条挂一条修订记指向本 ADR——变的是「显式」的发起面多了一个，不是那条边界松了。
- **不采 multica 的无看门狗 fork**：GUI 不做进程监督，崩溃自愈仍归 launchd。代价是「装服务」这件事比 fork 一个子进程重（要写 plist、要 `launchctl`），换来的是壳崩了/退了内核照跑。
- **实施分工**：本 ADR 由 14 票（打包与门禁）、15 票（`--copy-to-home`、线上内核版本、`service --json`）、16 票（引导 UI 与菜单模型）三票落地；14 票交付时 UI 尚未长出来，分发 runbook 的小白路径按本 ADR 定的口径写在前面，16 票收尾。
- **仍是人工项**：真证书签名 + 公证、首次 TCC / 通知授权、带 quarantine 的双击首启实测（translocation 是否真的发生）——全部顺延，见 [分发 runbook](../runbooks/distribution.md) §8 的完整并集。
