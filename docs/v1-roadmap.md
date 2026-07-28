# V1 阶段路线（Mac-only / Swift 原生）

> 定稿：2026-07-28。取代 [platform-framework-research.md](research/platform-framework-research.md) 的 §10（spike 清单）与 §11（分阶段路线）；该文档逐节处置清单见 [03 票](../.scratch/v1-mac-recharter/issues/03-tech-stack-decision.md) Answer。
> 决策依据：`.scratch/v1-mac-recharter/`（地图与八张票）；正式决定见 `docs/adr/0001`–`0007`（均 accepted）。

## 总览

| Phase | 内容 | 出口判据 |
|---|---|---|
| 0 | 骨架 + 三 spike + 一次性开发环境仪式 | 三 spike 出结论；回退硬门裁决一次 |
| 1 | 平台最小核 + **代理插件**（首个真实纵切） | agent-first 旗舰场景通过 |
| 2 | 宠物 + 提醒（原 §8 的原生化改写） | 两插件能力面 + GUI 落地 |
| 3 | 发布工程（完整链） | 首个可对外分发的签名+公证+可更新版本 |

代理插件提前首发（2026-07-28 用户裁决）：它是 agent-first 旗舰用例（Codex 设 mihomo）、用户当下刚需，且覆盖面最全（首个 dangerous 确认、子进程、CLI、菜单栏）——平台骨架被真实需求拉动。

## Phase 0 — 骨架与三 spike

**基建（随做）**：单 SPM 包多 target 骨架 + XcodeGen `project.yml` + `Scripts/check.sh`（swift build + swift test + 快照）；一次性签名仪式：开发证书、首次 TCC/通知授权、`notarytool store-credentials`（无签名 .app 会在 UserNotifications 直接崩溃，故 Phase 0 就做）。仓库 git 化与否由用户择时决定；git 化后 check/smoke 原样迁 GitHub Actions macOS runner。

**S1 宠物悬浮窗 spike**（原 §10-1 保留，Electron→原生）
`NSPanel` + `NSHostingView`。通过 = 点击穿透可动态切换（`ignoresMouseEvents` + 命中区域）、置顶稳定（`level`）、全空间与全屏辅助（`collectionBehavior`: canJoinAllSpaces / fullScreenAuxiliary / stationary）、多显示器拖拽、睡眠恢复。产物 = demo + 录屏/快照。**本 spike 兼任「AI 自主改-编-测循环」的实证**——过程即证据。

**状态：已完成并通过用户验收（2026-07-28）**——编译/运行/点透/层级/全空间/拖拽等全过，AI 自主循环实证成立（硬门①②的正向证据）。详见 `Spikes/S1PetOverlay/README.md`。

**S2 capability 纵切 spike**（原 §10-3 保留并扩容：+CLI+UDS+dangerous）
注册表注册两个 demo 能力（一 safe 一 dangerous）→ 菜单栏项调用 → `aa capabilities call` → UDS → 宿主确认弹窗（dangerous）全链打通；Runtime 纯逻辑有 swift-testing 覆盖，菜单栏视图有快照。通过 = 全链通且 AI 全程自主完成。

**状态：已完成并通过用户验收（2026-07-28）**——test.sh 7/7 PASS + 真机点验两条 dangerous 分支（确认→`{"approved":true}` 退出 0，拒绝→`denied` 退出 2）。全链在 Swift 上打通。详见 `Spikes/S2CapabilitySlice/README.md`。

**S3 Codex↔CLI 沙箱实测**（新增，[05 票](../.scratch/v1-mac-recharter/issues/05-agent-first-interface.md)遗留最关键项）
workspace-write 沙箱下 `aa` 连宿主 UDS 是否放行。本 spike 只有结论没有失败：若拦 → 依序验证备选（localhost HTTP 短连 → `prefix_rule` 提权文档化）并选定其一。「全被拦且无可接受备选」= 回退硬门③。

**状态：已完成（2026-07-28，结论经用户确认）**——UDS（工作区内外）与 localhost TCP 全部 EPERM；幸存路径选定 `prefix_rule` 提权信任（一次批准持久化，命令沙箱外执行），UDS 设计不变；硬门③未触发。详见 `Spikes/S3CodexSandbox/README.md` 与 07 票回写。

**被移除/移动的原 spike**：原 §10-2（Codex App Server）随内嵌 Codex 撤出 V1 一并移除（地图前提 4）；原 §10-4（updater/migration）后移为 Phase 3 首项。

**Phase 0 收尾：回退裁决（一次，之后不回头）**。仅结构性失败触发回退 Electron+TS：
① 宠物窗点透/多空间达不到 Electron 参照水平；② AI 在 Swift 上无法自主完成改-编-测循环（反复卡死需人拆解）；③ 本地 IPC 全被沙箱拦且无可接受备选。单纯「开发慢一点」不触发。

**状态：回退裁决已完成（2026-07-28）——维持 Swift,V1 内封栈。** 三条硬门均未触发;硬门之外用户以新动机（进度/工具链/通用性）追加一轮 Electron 回退预研（electron-recon,七张 AFK 票 + E1 冒烟）,终裁不翻案（[ADR 0002 重评记录](adr/0002-swift-native-stack.md)、裁决全文 `.scratch/electron-recon/issues/09-final-ruling.md`）。Phase 0 剩余项 = 基建（SPM 骨架/XcodeGen/check.sh/最小签名仪式）,前置条件 = 装完整 Xcode.app（用户择时;本机 CLT 损坏,修好前 `swift build` 不可信）;期间纸面工作（spec/tickets/域模型）零 Xcode 先行。

## Phase 1 — 平台最小核 + 代理插件

**平台侧**：manifest / 注册表正式化（含风险分级三档与宿主确认 UI——dangerous 确认永远落宿主 GUI，CLI 不交互阻塞）；ProcessPort；菜单栏宿主框架（`NSStatusItem`）；UDS server 正式化；`aa` 双层命令面（`capabilities list|describe|call --json` 底座 + 域子命令映射）+ `aa docs agents-md` + `prefix_rule` 信任文档。

**代理插件**（范围=（[04 票](../.scratch/v1-mac-recharter/issues/04-proxy-plugin-v1-scope.md)）in 清单）：内核打包+重签入构建链；系统代理接管/还原/崩溃自愈；订阅管理（多存单激活、手动更新）；模式/组节点/延迟测速；菜单栏轻壳（ClashX Meta 对标）；能力面 safe/normal/dangerous 全套。

**验收 = 旗舰场景**：Codex 经 `aa` 开代理/切节点全程零 GUI 打断；换订阅源必触发宿主确认。测试面：`check.sh` 门禁 + 代理域 swift-testing + 快照 + 冒烟 1–2 条。

## Phase 2 — 宠物 + 提醒（原 §8 原生化改写清点）

原 §8 领域设计保留，按下表改写进各自 spec（票 08 第 3 项的清点结论）：

| 原设计 | 保留（领域，栈无关） | 改写（表现层→原生） | 删除 |
|---|---|---|---|
| §8.1 宠物 | 高层能力面 `pet.present/emote/play/isAvailable`（不暴露帧/坐标）；任务状态驱动表现；保存选择与位置；reduced-motion | 透明悬浮窗→`NSPanel`+`NSHostingView`（S1 已验）；托盘→`NSStatusItem`；动画载体（SwiftUI/SpriteKit）实施时定 | Web 页面宠物 |
| §8.2 提醒 | 调度模型仅 `once`/`cron`+timezone；休眠恢复至多补发一次；退出后不触发；presenter 能力选择（系统通知 ↔ pet presenter 回退）；独立存储不读 pet 数据 | 通知投递→UserNotifications（签名前提）；常驻定时→宿主调度服务 | Web/PWA 触发 |
| dev 体验 | 可注入 Fake host（AAHostTestKit） | Vite 热加载→SwiftUI Preview + 注入 Fake host | — |

两插件的能力面照代理插件模式建模（agent-first：能力是第一交互面）。

## Phase 3 — 发布工程（首个对外分发前）

Developer ID 分发链 + 公证流水线脚本化；Sparkle 自更新（EdDSA key、appcast、**用户确认更新**——不做静默）；迁移/备份与失败恢复（原 §10-4 后移至此）；GPL 义务落地（关于页附 GPL-3.0 文本 + 内核版本与源码指引，[ADR 0007](adr/0007-mihomo-subprocess-gpl-compliance.md)）；`Scripts/smoke.sh` 十条内 XCUITest 冒烟集齐；安装/升级/回滚/卸载人工可审计 checklist（原 §9.2 发布前清单的 Mac 化保留）。

## 排期外（继续暂缓）

原 §12 暂缓清单全部继续（运行时第三方插件、市场、云账号/同步、App Store、静默更新等）；另加本效fort裁定：TUN 模式、代理仪表盘窗、内嵌 Codex、Windows/Web、MCP adapter（registry 稳定后另行评估，届时 Swift SDK 不成熟可 sidecar）。
