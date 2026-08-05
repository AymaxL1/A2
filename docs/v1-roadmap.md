# V1 阶段路线（内核 bin 化后修订版）

> 定稿：2026-07-28（Mac-only / Swift 原生前提）。**2026-08-04 按「a2 内核 bin 化」效fort重写**：Phase 1 出口判据、门禁口径、在飞工作与人工项落位全部改写；Phase 0 记录原样保留为历史。取代 [platform-framework-research.md](research/platform-framework-research.md) 的 §10（spike 清单）与 §11（分阶段路线）。
> 决策依据：原批见 `.scratch/v1-mac-recharter/`（地图与八张票）；本次修订见本机决策记录 `.scratch/kernel-bin-recharter/`（13 票，未入库）与实施 spec `.scratch/a2-kernel/spec.md`。
> 现行正式决定：[ADR 0003](adr/0003-build-time-trusted-plugins.md)（范围部分经 0011 修订）、[0004](adr/0004-capability-registry-sole-call-surface.md)、[0005](adr/0005-agent-first-interaction.md)（第 4 条已修订）、[0006](adr/0006-local-first-no-cloud.md)、[0007](adr/0007-mihomo-subprocess-gpl-compliance.md)（已修订）、[0008](adr/0008-kernel-bin-ui-optional.md)–[0011](adr/0011-plugin-exec-protocol-loading.md)；**[0001](adr/0001-mac-only-platform-boundary.md)/[0002](adr/0002-swift-native-stack.md) 已废止**（分别由 0009/0010 重立）。

## 总览

| Phase | 内容 | 出口判据 |
|---|---|---|
| 0 | 骨架 + 三 spike + 一次性开发环境仪式 | 三 spike 出结论；回退硬门裁决一次 —— **已完成（2026-07-28）** |
| 1 | 平台最小核 + **代理插件** → **（2026-08-04 改写）内核 bin 化重构** | **重构蓝图第⑤步（壳原子切换）完成**：`a2` 单 bin + `a2 service` 安装 + mihomo 监督 + 三层仲裁与确认器 + 壳原子切换 + 门禁原子切到 TS 四件套 —— **已达成（2026-08-05）**，6 条判据逐条自查见 Phase 1 节 |
| 2 | 宠物 + 提醒（原 §8 的原生化改写） | 两插件能力面 + 壳呈现（按新架构在 Phase 1 出口后重排） |
| 3 | 发布工程（完整链） | 首个可对外分发的版本（渠道 = 单文件下载 + curl 安装脚本；`a2-panel.app` 随附） |

代理插件提前首发（2026-07-28 用户裁决）：它是 agent-first 旗舰用例（外部 agent 设 mihomo）、用户当下刚需，且覆盖面最全（首个 dangerous 确认、子进程、CLI、菜单栏）——平台骨架被真实需求拉动。这条理由在重构后依然成立：代理域仍是新内核的第一条真实纵切。

## Phase 0 — 骨架与三 spike（历史记录，已完成）

**基建（随做）**：单 SPM 包多 target 骨架 + XcodeGen `project.yml` + `Scripts/check.sh`（swift build + swift test + 快照）；一次性签名仪式：开发证书、首次 TCC/通知授权、`notarytool store-credentials`（无签名 .app 会在 UserNotifications 直接崩溃，故 Phase 0 就做）。

**S1 宠物悬浮窗 spike**（原 §10-1 保留，Electron→原生）
`NSPanel` + `NSHostingView`。通过 = 点击穿透可动态切换（`ignoresMouseEvents` + 命中区域）、置顶稳定（`level`）、全空间与全屏辅助（`collectionBehavior`: canJoinAllSpaces / fullScreenAuxiliary / stationary）、多显示器拖拽、睡眠恢复。产物 = demo + 录屏/快照。**本 spike 兼任「AI 自主改-编-测循环」的实证**——过程即证据。

**状态：已完成并通过用户验收（2026-07-28）**——编译/运行/点透/层级/全空间/拖拽等全过，AI 自主循环实证成立（硬门①②的正向证据）。详见 `Spikes/S1PetOverlay/README.md`。

**S2 capability 纵切 spike**（原 §10-3 保留并扩容：+CLI+UDS+dangerous）
注册表注册两个 demo 能力（一 safe 一 dangerous）→ 菜单栏项调用 → `aa capabilities call` → UDS → 宿主确认弹窗（dangerous）全链打通；Runtime 纯逻辑有 swift-testing 覆盖，菜单栏视图有快照。通过 = 全链通且 AI 全程自主完成。

**状态：已完成并通过用户验收（2026-07-28）**——test.sh 7/7 PASS + 真机点验两条 dangerous 分支（确认→`{"approved":true}` 退出 0，拒绝→`denied` 退出 2）。全链在 Swift 上打通。详见 `Spikes/S2CapabilitySlice/README.md`。

**S3 Codex↔CLI 沙箱实测**（新增，[05 票](../.scratch/v1-mac-recharter/issues/05-agent-first-interface.md)遗留最关键项）
workspace-write 沙箱下 `aa` 连宿主 UDS 是否放行。本 spike 只有结论没有失败：若拦 → 依序验证备选（localhost HTTP 短连 → `prefix_rule` 提权文档化）并选定其一。「全被拦且无可接受备选」= 回退硬门③。

**状态：已完成（2026-07-28，结论经用户确认）**——UDS（工作区内外）与 localhost TCP 全部 EPERM；幸存路径选定 `prefix_rule` 提权信任（一次批准持久化，命令沙箱外执行），UDS 设计不变；硬门③未触发。详见 `Spikes/S3CodexSandbox/README.md` 与 07 票回写。**该结论在新架构下继续适用**：agent 经 `prefix_rule` 在沙箱外执行 `a2`，UDS 只在 `a2` 与内核之间。

**被移除/移动的原 spike**：原 §10-2（Codex App Server）随内嵌 Codex 撤出 V1 一并移除（地图前提 4）；原 §10-4（updater/migration）后移为 Phase 3 首项。

**Phase 0 收尾：回退裁决（一次，之后不回头）**。仅结构性失败触发回退 Electron+TS：
① 宠物窗点透/多空间达不到 Electron 参照水平；② AI 在 Swift 上无法自主完成改-编-测循环（反复卡死需人拆解）；③ 本地 IPC 全被沙箱拦且无可接受备选。单纯「开发慢一点」不触发。

**状态：回退裁决已完成（2026-07-28）——维持 Swift,V1 内封栈。** 三条硬门均未触发;硬门之外用户以新动机（进度/工具链/通用性）追加一轮 Electron 回退预研（electron-recon,七张 AFK 票 + E1 冒烟）,终裁不翻案（[ADR 0002 重评记录](adr/0002-swift-native-stack.md)、裁决全文 `.scratch/electron-recon/issues/09-final-ruling.md`）。**2026-08-04 注**：该裁决管的是 **UI 路线**（不回 Electron/Web），依然有效；2026-08-04 重立的是**内核语言与运行时**（Swift → TS/Bun，见 [ADR 0010](adr/0010-ts-kernel-bun-runtime.md)），Mac 壳仍是原生 Swift，两者不冲突。

## Phase 1 — 内核 bin 化重构（2026-08-04 重写）

### 出口判据（新）

**重构蓝图第⑤步（壳原子切换）完成** = 以下同时成立：

1. 单 bin `a2` 承担全部主逻辑（CLI 默认模式 + `a2 daemon run` 常驻模式）；
2. `a2 service install|uninstall|status` 落 launchd/systemd user 单元，自启与自愈归系统 supervisor，CLI 永不隐式拉起 daemon；
3. mihomo 监督面在位（外部安装脚本、配置/reload、存活探测、启停、复用阶梯）；
4. dangerous 三层仲裁与确认器协议在位（默拒 fail-closed / 拒绝即指引 / 确认器带外确认）；
5. `a2-panel` 改喂养源接新内核（事件投影 + 确认器），`aahost`/`aa`/`aa-agent` 废除；
6. 门禁在此步**原子切换**到 TS 门禁四件套：**旧引擎退役、入口与接口保留**（`bash Scripts/check.sh` 一条命令、非零退出、清楚 PASS/FAIL —— 换的是实现，不是接口）。
   *（2026-08-05 字面订正：原文写作「`check.sh` 退役」，与实际交付不符 —— 退役的是 `Scripts/check/` 那套旧引擎；入口脚本一直保留。判据实质未变，见下表第 6 行。11 票起该入口下多了一步插件 e2e，共五步。）*

原判据「agent-first 旗舰场景通过」**作废**——它押在 `aa` + GUI 宿主拓扑上，该拓扑本身正在被替换；其验收精神（全程只经 CLI、零 GUI 打断、dangerous 必经确认）由重写版 flagship e2e 继承。

#### 达成情况（2026-08-05，10 票完成时逐条自查）

| # | 判据 | 结论 | 证据 |
|---|---|---|---|
| 1 | 单 bin `a2` 承担全部主逻辑 | **达成** | `kernel/` 一个 Bun compile 产物（61.2MiB），默认 CLI、`a2 daemon run` 常驻；Swift 侧已无任何业务逻辑（整包只剩壳 target 群）。`bun test` 263 条 |
| 2 | `a2 service …` + 系统托管 + 永不隐式拉起 | **达成** | 05 票：三态机读、unit 落位、幂等、漂移收敛到进程；真 `launchctl` 活体冒烟 28/28（含 SIGSEGV → launchd 自愈） |
| 3 | mihomo 监督面在位 | **达成**（有一条如实的缺口） | 06/07 票：三档阶梯、锁版下载 fail-closed、显式升级、存活观测 NDJSON。**缺口**：全程用假 mihomo，「真 mihomo 接受这份配置 / 那几条 REST 与我们的客户端对得上」无自动化断言 —— 已记入对等映射表 10 票 G 组，顺延人工项 |
| 4 | dangerous 三层仲裁与确认器协议在位 | **达成** | 08 票：默拒 / 拒绝即指引 / 带外确认三收场 + 角色注册 + 零轮询推送 + 对端 UID；旗舰 e2e 幕 2/3/4 对**真内核 + 真壳代码路径**跑通三条收场 |
| 5 | `a2-panel` 接新内核，旧三可执行废除 | **达成** | 10 票：16 个旧 target（22444 行）退场；`a2-panel` 以对等客户端注册 confirm-agent、事件投影驱动菜单（零轮询有实证）、退出仅断连；`.app` 以 `com.a2.panel` 身份出包 + ad-hoc 签名 |
| 6 | 门禁原子切换到四件套，**旧引擎退役、入口与接口保留** | **达成** | 旧引擎 `Scripts/check/`（15 模块 / 429 条断言）整棵退场。**入口路径 `Scripts/check.sh` 保留**、接口逐字不变（一条命令 / 非零退出 / 清楚 PASS-FAIL），换的是引擎 —— 与 11 票「换引擎接口不变」同一种安排。四件套之外另加两条静态关（`tsc --noEmit` / `swift build` 零 warning）与 `.app` 出包核验（验收框要求「以 a2-panel 身份出包」）。**11 票追加**：插件 e2e 一步 + 一道「内核产物比源码旧就当场重建」的新鲜度守卫（此前 e2e 会静默拿旧产物开跑） |

**结论：Phase 1 出口达成（2026-08-05）**。作废的原判据由 `Scripts/a2-flagship-e2e.sh` 继承其验收精神
（46 条：旗舰链零打断 / dangerous 三收场 / 壳退出仅断连 / 显式还原 / 壳与真内核的能力面对账）。

**出口不含**（逐条已在别处记账，列此免得被绿灯掩盖）：下表 5 条人工项、
对等映射表 J 组的四条做不到项、以及 agent-delegation 那 8 条**排期未定**的顺延账
（`kernel/test/swift-parity-map.md` 10 票 A 组：本 spec 的迁移六步表里没有它的位置，是一处 spec 遗漏）。

### 六步切法（每步可合并、门禁绿）

| 步 | 内容 | 门禁 |
|---|---|---|
| ① | 契约与骨架：`kernel/` TS 工程 + 协议 schema + `a2 daemon run` UDS 骨架 + TS 门禁起步 | `check.sh` 保绿（Swift 侧不动） |
| ② | 控制面重建：注册表/运行时等价物 + CLI 子命令面（结构化输出、拒绝即指引）+ `a2 service` | 同上 + TS 侧 `bun test` |
| ③ | mihomo 监督面：安装脚本、配置管理、自启 unit、存活探测、实例复用阶梯 | 同上 |
| ④ | 仲裁与确认器协议：三层仲裁 + 角色注册 + 订阅推送（壳未接入时默拒层即生效） | 同上 |
| ⑤ | **壳原子切换**：`a2-panel` 接新内核、旧可执行废除、快照测试跟切 —— **已完成（2026-08-05）** | **唯一门禁切换点**：`check.sh` → TS 门禁四件套（已切） |
| ⑥ | 插件宿主：`BUN_BE_BUN` 拉起 + exec 协议（[ADR 0011](adr/0011-plugin-exec-protocol-loading.md)） | TS 门禁 |

### 门禁口径

- **⑤之前**：`Scripts/check.sh` 保绿（`swift build` + `swift test` + 各级 e2e，既有断言口径不变），TS 侧门禁并行起步。
- **⑤之时（2026-08-05 已执行）**：原子切换到 **TS 门禁四件套** —— ① `bun test`（CLI 面为主战场：argv 进、stdout JSON / 退出码出）；② **契约金标报文快照**（TS 与 Swift 双端对同一批样本编解码，防契约漂移；两侧分别落在 ① 与 `swift test` 两步里）；③ **壳快照测试**（「一个模型两个渲染器」原封平移，**判据搬进 `swift test`**，14 票那条 shell 中间层随之退役）；④ **重写版 flagship e2e**（对真实 `a2` bin + 假 mihomo 夹具跑端到端）。
  实际落地另加三样（如实记，均不改「一条命令」这条接口）：静态关 `tsc --noEmit` 与 `swift build` 零 warning，以及 `.app` 出包核验。**入口路径 `Scripts/check.sh` 保留** —— 换引擎不换接口（11 票的先例）。
- **行为规范参考与断言迁移**（**规模数字与映射口径的单一出处**，ADR 0008/0010 引用本条、不另记数字）：Swift 侧约 **10213 行逻辑 + 4929 行测试（428 断言口径）**随六步推进逐步退场——代码降级为 TS 重建的**行为规范参考**，断言按**行为对等**逐条映射到 TS 侧，允许合并/淘汰只属 Swift 实现细节的断言。
- **⑤之后**：旧引擎（`Scripts/check/` 整棵 15 模块 / 429 条断言）退役；`check.sh` 作为**入口**保留，实现已换。

### 在飞工作的处置（v1-core-proxy）

- 01–10 票在 main；11–16 票 + 17 票（swift-testing 全量迁移）在分支 `worktree-v1-tickets-11-16`，**合入 main 由用户执行**（仓库无 remote）。
- 合入后，这批工作的价值**转为行为规范参考**：代理域的能力面语义、订阅/模式/节点行为、以及 17 票迁到 `Tests/` 的全套 swift-testing 断言，是 TS 重建时的行为规格来源，不再是主干实现（口径见上「行为规范参考与断言迁移」）。
- 旧 Phase 1 在原判据下的完成度（保留记录）：`Scripts/check/flagship-e2e.sh` 已用一个宿主实例、全程只经 `aa` 走通旗舰链（开代理 → 切模式 → 选节点 → 更新订阅），并有 dangerous 换源的反向对照；门禁 PASS 428 / FAIL 0。但脚本里的「agent」是 shell 模拟的，**两条必须有人在场的实测从未做过**——见下表第 4、5 项。

### 5 条人工项（顺延到⑤之后，按新形态重定义）

原口径见 v1-core-proxy 13 票（签名仪式）与 16 票（旗舰验收）；条目分组以那两票为准。

| # | 原形态 | ⑤后的新形态 |
|---|---|---|
| 1 | 装 Xcode + 签发 Apple Development 证书 | 不变（前置条件），但签的对象是 **`A2 Panel.app`**（bundle id `com.a2.panel`）；内核 bin `a2` 走单文件下载分发，不吃 .app 签名链 |
| 2 | 用真证书重签 `.app` + 重跑门禁 | 对 `A2 Panel.app` 出包 + 跑 TS 门禁。**自动部分 10 票已完成**：`Scripts/build-app.sh` 一条命令出包 + ad-hoc 签名 + 8 条结构/签名核验，已进门禁；剩下的是**换真身份**这一步（`AA_CODESIGN_IDENTITY` 一个 env） |
| 3 | 首次 TCC / 通知授权点头 | 归**确认器**：`a2-panel` 以确认器角色呈现 Touch ID / 通知，授权仪式在它身上做一次。**对着 `com.a2.panel` 做**（旧 id `com.aa.host` 从未授过权，10 票换 id 的代价此刻恰好是零） |
| 4 | 真 Codex 经 `aa docs agents-md` + `prefix_rule` 完成旗舰操作 | 对 **`a2 … --json`** 重跑同一场景 |
| 5 | 换源 dangerous 真机点验（真弹窗批准/拒绝两分支） | 对**确认器**重跑：带外确认的批准/拒绝两分支。**协议链已自动化**（旗舰 e2e 幕 2/3 跑的是壳的真代码路径），人工项只剩「**人真的点了那个按钮**」这一步 |

**真 mihomo 那条缺口的一个候选补法（10 票 CR 建议，2026-08-05 记，尚未实现、需用户裁定）**：
给旗舰 e2e 加一条 env seam `A2_REAL_MIHOMO_BIN=<路径>` —— 有它时多跑一幕**真内核**（真 mihomo 接受 a2 渲染的
`config.yaml` + 三条 REST 与我们的客户端逐条对照），并把那次人工实测的**真回包**收进金标，用来钉住
`kernel/test/support/fake-mihomo` 这份假件（今天假件复刻的是我们**以为**的 REST 语义，它验不了「我们以为的」对不对）。
**需用户裁定才能做**：本机跑着用户自己的 mihomo（施工红线是绝不触碰），这一幕只能在用户指定的另一份二进制上跑。

**Linux 口径**：交叉编译产物与 systemd 代码路径属当下承诺、进门禁（单元级）；**Linux 实机端到端验收未裁**，默认随人工项节奏顺延（如需提前由用户裁定）。

## Phase 2 — 宠物 + 提醒（原 §8 原生化改写清点）

原 §8 领域设计保留，按下表改写进各自 spec（票 08 第 3 项的清点结论）：

| 原设计 | 保留（领域，栈无关） | 改写（表现层→原生） | 删除 |
|---|---|---|---|
| §8.1 宠物 | 高层能力面 `pet.present/emote/play/isAvailable`（不暴露帧/坐标）；任务状态驱动表现；保存选择与位置；reduced-motion | 透明悬浮窗→`NSPanel`+`NSHostingView`（S1 已验）；托盘→`NSStatusItem`；动画载体（SwiftUI/SpriteKit）实施时定 | Web 页面宠物 |
| §8.2 提醒 | 调度模型仅 `once`/`cron`+timezone；休眠恢复至多补发一次；退出后不触发；presenter 能力选择（系统通知 ↔ pet presenter 回退）；独立存储不读 pet 数据 | 通知投递→UserNotifications（签名前提）；常驻定时→**内核调度服务** | Web/PWA 触发 |
| dev 体验 | 可注入 Fake host（AAHostTestKit） | Vite 热加载→SwiftUI Preview + 注入 Fake host | — |

两插件的能力面照代理插件模式建模（agent-first：能力是第一交互面）。**2026-08-04 注**：本表的领域内容不变，但落位随新架构调整——业务逻辑与调度归内核（TS），UI 表现层归可选壳；具体排期在 Phase 1 出口后重画。

## Phase 3 — 发布工程（首个对外分发前）

- **分发渠道（2026-08-04 裁定）**：V1 = **单文件直接下载 + curl 安装脚本**；Homebrew Formula 列后续；`a2-panel.app` 随附带包。
- **签名/公证**：`a2-panel.app` 走 Developer ID 分发链 + 公证流水线脚本化；内核 bin 的签名形态随渠道另定（Phase 1 出口后按实际分发物排）。
- **自更新**：Sparkle 自更新（EdDSA key、appcast、**用户确认更新**——不做静默）的适用面限于 `.app`；`a2` bin 的升级是显式命令（不做静默更新，[ADR 0006](adr/0006-local-first-no-cloud.md) 的暂缓清单继续）。
- **迁移/备份与失败恢复**（原 §10-4 后移至此）。
- **GPL 义务落地（2026-08-04 改写）**：`a2 about` 子命令 + 随包静态文本声明「调用外部 GPL-3.0 程序 mihomo」+ 许可与源码获取指引；关于页降级为同一份文本的可选呈现面；**内核重签校验已废除**（[ADR 0007](adr/0007-mihomo-subprocess-gpl-compliance.md) 修订）。义务落点不依赖 UI，故**不再是 Phase 3 才能履行的事**——随内核 bin 一并交付。
- 冒烟与人工可审计 checklist（安装/升级/回滚/卸载，原 §9.2 发布前清单的保留项）按新分发物重写。

## 排期外（继续暂缓）

原 §12 暂缓清单全部继续（运行时第三方**插件市场**、云账号/同步、App Store、静默更新等）；另加已裁定项：TUN 模式、代理仪表盘窗、内嵌 Codex、Windows/其他端 UI（[ADR 0009](adr/0009-kernel-platform-scope.md)）、**MCP adapter（继续挂起不排期**——已裁不进 V1，真实需求出现再立效fort，[ADR 0011](adr/0011-plugin-exec-protocol-loading.md)）、V1 插件的事件面与常驻态（显式已知限制）。

> 注：「运行时第三方插件」中**本机用户/agent 自己写的单文件插件已不在暂缓之列**（`a2 plugin add` 装载零闸，[ADR 0011](adr/0011-plugin-exec-protocol-loading.md)）；继续暂缓的是面向不受信任第三方作者的分发与市场。
