# Electron 常驻成本、系统集成与发布链复核（2026-07）

> 调研日期：2026-07-28（对应票：`.scratch/electron-recon/issues/04-resident-cost-release.md`）
> 目的：核实 [ADR 0002](../../adr/0002-swift-native-stack.md) 给 Electron 记的三笔成本（常驻内存、8 周 major 维护税、原生感隔层）在 2026-07 当下是否仍成立，并对标 [v1-roadmap.md](../../v1-roadmap.md) Phase 3 已定的发布链（Sparkle、EdDSA、用户确认更新）。mihomo 集成面/GPL 分析已在 [mihomo-integration.md](../mihomo-integration.md) 完成，本文不重查，仅在 §5 确认结论不因栈变。
> 资料原则：官方文档/源码/GitHub Issue 为一手来源，标注出处；单一来源的经验数字标注"经验值/单一来源"以示区别于官方数据。

## 0. 结论摘要

1. **常驻内存**：Tray-only Electron app 的经验区间是 **idle 80–300MB、典型使用期 200–400MB**（多来源相互印证，无官方基准），对照 Swift 菜单栏 app 的 30–80MB——**这笔账在 2026 年仍然真实存在，量级 3–5 倍**。根源是 Chromium 基线开销（~150–200MB 空载）+ 独立 GPU 进程，`backgroundThrottling`/销毁窗口只留 Tray 等策略只能压低到经验区间下限，无法消除结构性差距。
2. **维护税**：官方支持政策原文实测确认——**8 周一个 major**、**同时只支持最新 3 个 major**、每个 major 的安全支持窗口约 **5–6 个月**（不能长期钉住旧版）。"只跟 LTS 式旧版"不可行。Chromium CVE 对本地无远程内容的 app 暴露面显著降低但非零（V8 heap snapshot 完整性等本地攻击面仍存在），Electron 官方安全文档仍建议持续跟随最新版本。
3. **系统集成**：`app.setLoginItemSettings` 在 macOS 13+ 已改用 SMAppService 同一套底层 API（与 Swift 侧一致，系统设置里显示方式相同）；`LSUIElement`（非 `app.dock.hide()`，后者有已知延迟/副作用）可做纯菜单栏 app；Tray 模板图标（`xxxTemplate.png`）官方支持暗色自适应。**关键核实项——Notification 在未签名/ad-hoc 下不可用**：官方文档明确未签名二进制会触发 `failed` 事件、通知不投递，机制与 Swift 侧的 UNNotification 前提相同（底层就是同一套 macOS API），但**表现不同**：Electron 侧是通知静默失败（`failed` event / 空历史），不是应用崩溃。
4. **更新链**：electron-updater 完整支持"用户确认才更新"模式（`autoDownload=false` + `update-available` 监听 + 用户确认后 `quitAndInstall()`），流程能力与 Sparkle 对标持平。但 **macOS 更新包签名是 Squirrel.Mac 的硬性要求**（无证书应用无法自动更新），这一点与 Sparkle 需要 Apple 代码签名配合 EdDSA 密钥轮换的前提相当——两栈在"无证书开发期测试更新"上同样痛，不构成栈间差异。
5. **mihomo 打包**：结论不变——asar 内二进制不能被 `spawn`/`exec` 直接执行（仅 `execFile` 可，且实际是先解包），标准做法是 `asarUnpack` 或 `extraResources` 落到 asar 外；**electron-builder 不会自动重签 extraResources 里的二进制**，必须显式加入 `mac.binaries` 声明路径才会被纳入签名/hardened runtime/公证流程，否则 `codesign --deep --strict` 会在嵌套二进制处失败——这与 [mihomo-integration.md §5](../mihomo-integration.md) 描述的 Swift 侧陷阱（bundle 内二进制需显式重签）同构，两栈打包动作量相当。子进程生命周期用 Node `child_process.spawn` 返回的 `ChildProcess`（`exit`/`close`/`error` 事件）管理，模型与 Swift `Process` 对等。**GPL 边界确认：不因栈变**——义务判定依据是子进程隔离 + CLI 参数/REST 通信这一集成形态本身（FSF "separate programs / arms length"），与宿主用 Swift 还是 Node/Electron 无关；Electron 侧同样是 `child_process.spawn` 启动独立二进制、REST/WS 控制，不发生进程内链接，因此 ADR 0007 的分析结论逐字适用。
6. **app 体积**：Electron 基线（未加 mihomo）经验区间 **"Hello World" 打包后 ~45–115MB（多来源不一致，与优化程度/是否含双架构相关），完整安装物（含 Chromium+Node 基线）常见 120–150MB**；叠加 mihomo（~42MB 安装后/单架构，见 mihomo-integration.md §5）后，Electron 路线的 .app/.dmg 预计落在 **170–260MB** 区间（未做双架构 universal 前提下）；对照 Swift 菜单栏 app 量级（~30–60MB 主体 + 同样的 ~42MB mihomo），Electron 路线体积膨胀 3–4 倍。

---

## 1. 常驻足迹（RSS）

来源：[Electron process model 官方文档](https://www.electronjs.org/docs/latest/tutorial/process-model)、[Seena Burns – Debugging Electron Memory Usage](https://seenaburns.com/debugging-electron-memory-usage/)、[windowslatest.com 2025-12 报道](https://www.windowslatest.com/2025/12/07/ram-prices-soar-but-popular-windows-11-apps-are-using-more-ram-due-to-electron-web-components/)、多篇 2025–2026 框架对比文章。

**进程结构（官方）**：Electron app 至少由三类进程组成——主进程（"Electron"）、一个 GPU 辅助进程、每个 `BrowserWindow`/web embed 一个渲染进程；Tray-only 场景若彻底不建窗口，理论上只剩主进程 + GPU 进程，但大多数壳仍会保留一个隐藏的 `BrowserWindow`（承载设置面板/托盘菜单渲染），因此渲染进程通常不会真正归零。

**多来源经验数据点（无单一权威基准，交叉印证）**：

| 来源 | 数字 | 场景 |
|---|---|---|
| windowslatest.com（2025-12） | Electron 类应用被点名为 Windows 11 RAM 占用上升的主因之一（RAM 涨价背景报道） | 泛化观察，非精确测量 |
| 多篇框架对比文章（2025–2026，如 pikvue.com、raftlabs） | Electron 空载 ~200–300MB，Tauri 同场景 ~30–40MB（约 10 倍差距） | 通用桌面 app 对比，非 tray-only 专测 |
| 菜单栏系统监控类 Electron app 经验值 | 200–400MB；对照原生 Swift/SwiftUI 同类 app 30–80MB | Mac 菜单栏场景，与本项目形态最接近 |
| Chromium 基线（多来源共识） | 空载 Chromium 运行时本身 ~150–200MB | Electron 固定开销下限，与业务代码无关 |
| Seena Burns 实测记录 | 加载大数据集时 RSS 可从 ~300MB 飙升到 800MB–1GB，且导航离开后不回落（allocator 不主动归还内存给 OS） | 提醒：RSS 是"不精确的坏指标"，需结合 `process.getProcessMemoryInfo()` 等更细粒度 API |

**缓解手段与效果（官方机制，效果为经验估计）**：

- `backgroundThrottling: false`/`true` 控制后台窗口的动画/定时器节流；对 Tray-only 场景默认 `true` 已经在省电，但**不减少常驻 RSS 基线**，只影响 CPU/电量。
- "销毁窗口只留 Tray"（监听 `window-all-closed`，不 `app.quit()`，托盘菜单里按需重建窗口）能把渲染进程数压到 0，但**主进程 + GPU 进程的 Chromium 基线开销无法消除**——这是经验区间下限（idle ~80MB 一说）的来源，而非"接近原生"的量级。

**结论**：ADR 0002 记的这笔账在 2026-07 依然真实——3–5 倍于 Swift 菜单栏 app 的常驻内存，是 Chromium 运行时的结构性成本，非工程优化能抹平。24/7 代理场景（本项目形态）会长期占用这笔常驻内存，账要诚实对待。

---

## 2. 维护税

来源：[Electron Timelines 官方文档](https://www.electronjs.org/docs/latest/tutorial/electron-timelines)（WebFetch 实测）、[endoflife.date/electron](https://endoflife.date/electron)（WebFetch 实测）、[Electron Breaking Changes 文档](https://www.electronjs.org/docs/latest/breaking-changes)、[Electron Security 文档](https://www.electronjs.org/docs/latest/tutorial/security)。

**发布节奏与支持窗口（官方原文，2026-07-28 实测）**：

> "The latest three stable major versions are supported by the Electron team."
> "Electron's cadence between major version releases is 8 weeks long."
> "The latest stable release unilaterally receives all fixes from `main`, and the version prior to that receives the vast majority of those fixes as time and bandwidth warrants. The oldest supported release line will receive only security fixes directly."
> "We only support the latest minor release for each stable release series."

endoflife.date 实测当前窗口（2026-07）：v43（2026-06-30 发布，支持至 2027-01-05）、v42（2026-05-05 发布，支持至 2026-10-20）、v41（2026-03-10 发布，支持至 2026-08-25）——**三个 major 并行支持，每个 major 实测支持窗口约 5.5 个月**（如 v40 从 2026-01-13 发布到 2026-06-30 EOL）。

**"只跟 LTS 式旧版"不可行**：官方模型没有 LTS 概念，只保证最新 3 个 major、且每个 major 只支持"最新 minor"（如 42.1.x 支持时，41.0.x 不再回补，只有 41 系列的最新 minor 才算在窗口内）。这意味着：**要保持在安全支持窗口内，实际升级节奏接近"每 5–6 个月至少跟进一次 major"**，与 ADR 0002 "8 周 major"的表述一致（8 周出一个 major，落后 3 个 major≈24 周≈5.6 个月就出窗口）。

**breaking changes 密度**：官方为每个 major 维护独立的 `breaking-changes.md` 章节（[链接](https://www.electronjs.org/docs/latest/breaking-changes)），变更分类为 API Changed / Behavior Changed / Default Changed / Deprecated / Removed；官方承诺"至少提前一个 major 版本加废弃警告"，说明变更是持续、非偶发的常规节奏（未逐版本人工计数 breaking changes 条目数，成本-收益判断此处不做逐条清点，用官方持续维护该文档这一事实作为"变更密度不为零、需要制度化跟进"的证据）。

**Chromium CVE 对本地 app 的实际暴露面**：Electron 官方安全文档原文——

> "displaying arbitrary content from untrusted sources poses a severe security risk that Electron is not intended to handle"
> "An application built with an older version of Electron, Chromium, and Node.js is an easier target than an application using more recent versions"

即：**本项目"不加载远程内容的本地 app"形态确实规避了 Electron 安全模型里风险最高的一类（渲染任意不可信内容）**，大幅缩小实际可触达攻击面；但暴露面不为零——2025 年出现的 V8 heap snapshot 完整性问题（`EnableEmbeddedAsarIntegrityValidation` 未覆盖快照校验）说明本地攻击（写入用户可写安装目录后加载恶意快照）仍是现实风险类别，且 Chrome/Chromium 官方明确声明"物理本地攻击不在其威胁模型内"——也就是说这类问题的修复节奏不受"我们不联网"这个前提保护。结论：**风险显著降低但不能作为"可以不跟版本"的理由**，维护税实质仍然存在。

---

## 3. 系统集成对标

来源：[Electron `app` API 文档](https://www.electronjs.org/docs/latest/api/app)、[Electron PR #37244](https://github.com/electron/electron/pull/37244)、[Apple SMAppService.openSystemSettingsLoginItems() 文档](https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems())、[Electron Dock Menu 文档](https://www.electronjs.org/docs/latest/tutorial/macos-dock)、[Electron Notification 官方文档](https://www.electronjs.org/docs/latest/api/notification/)、[Electron nativeImage 文档](https://www.electronjs.org/docs/latest/api/native-image)。

- **登录项**：`app.setLoginItemSettings`/`getLoginItemSettings` 在 macOS 13+ 已重构为 Mac App Store 与非 MAS 构建共用同一套底层 API，对齐 Apple 的 `SMAppService`（[PR #37244](https://github.com/electron/electron/pull/37244) 原文："on macOS 13 and up, uses a single streamlined underlying API on both Mac App Store and normal builds"）；系统设置里的显示方式与 Swift 侧 `SMAppService.mainApp` 一致（同一个 Login Items 面板），没有栈差异。
- **`app.dock.hide()` vs `LSUIElement`**：`app.dock.hide()` 有已知副作用（应用菜单短暂不可用、连续调用 1 秒内无效——[electron#592](https://github.com/electron/electron/issues/592)）且**Dock 图标仍会在启动时短暂闪现后才隐藏**；纯菜单栏 app 的推荐做法是在 `Info.plist` 里直接设 `LSUIElement: true`（与 Swift 侧完全同一机制，因为本质就是同一个 plist key），而不是运行时调用 API。
- **Tray 模板图标**：官方支持 `xxxTemplate.png` 命名约定标记模板图标，自动适配亮/暗菜单栏（[nativeImage 文档](https://www.electronjs.org/docs/latest/api/native-image)），"Template image is only supported on macOS"——与 Swift `NSImage.isTemplate` 能力对等。
- **Notification 未签名/ad-hoc 可用性（本票核心待核实项）**：Electron 官方文档明确原文——

  > "On MacOS, notifications use the UNNotification API as their underlying framework. This API requires an application to be code-signed in order for notifications to appear. Unsigned binaries will emit a `failed` event when notifications are called."
  > "Like all macOS notification APIs, this method requires the application to be code-signed. In unsigned development builds, notifications are not delivered to Notification Center and this method will resolve with an empty array."

  **结论**：Electron 与 Swift 侧面对的是**同一个操作系统前提**（UNNotification 框架本身要求代码签名）——这不是 Electron 独有的短板，而是 macOS 平台对该 API 的通用要求。**区别在失败表现**：Swift 侧未签名会直接崩溃（票面既有认知）；Electron 侧未签名/ad-hoc 只是通知"静默失败"（`failed` 事件、`getHistory()` 返回空数组），应用本身不崩溃，是更温和的降级路径。工程含义：两栈都需要一次性签名仪式才能开发期验证通知功能，但 Electron 的失败模式对开发迭代更友好（不会因为忘记签名而整个 app 崩掉）。

---

## 4. 更新链对标（Sparkle vs electron-updater/Squirrel.Mac）

来源：[electron-updater GitHub Issue 讨论汇总](https://github.com/electron-userland/electron-builder/issues/7356)、[electron-builder 官方文档](https://www.electron.build/docs/features/auto-update/)、[Sparkle 官方文档 – Publishing an update](https://sparkle-project.org/documentation/publishing/)、[Sparkle EdDSA 迁移文档](https://sparkle-project.org/documentation/eddsa-migration/)。

- **"用户确认才更新"支持度**：electron-updater 完整支持该模式——设 `autoUpdater.autoDownload = false`，监听 `update-available` 事件后由 UI 询问用户，用户确认才调用 `autoUpdater.quitAndInstall()`；不确认时更新会在下次启动时才应用（"not strictly necessary to handle"）。能力上与 v1-roadmap Phase 3 已定的 Sparkle 用户确认更新（不做静默）**对标持平，无功能缺口**。
- **更新包签名要求**：macOS 平台的 electron-updater 底层是 Squirrel.Mac，**应用必须代码签名才能自动更新**（多个来源与官方文档一致确认这是 Squirrel.Mac 的硬性前提，非可选项）；且 macOS 默认 target 是 `dmg+zip`，zip 是 Squirrel.Mac 更新机制必需产物。这与 Sparkle 的前提相当——Sparkle 的 EdDSA 密钥轮换信任链本身就绑定 Apple 代码签名证书（"Sparkle uses the matching Apple code signature to trust changes in Sparkle public keys"），即 Sparkle 同样预设了 Developer ID 签名的存在。
- **无证书开发期怎么办**：两栈在这一点上处境相同——没有找到官方"无证书也能测自动更新"的正式路径；社区反馈（自签证书、`GenericHTTPServer` 信任自定义 CA 等 feature request）显示这是双方都存在的开发期摩擦，**不构成 Electron 相对 Sparkle 的额外劣势**，只是"发布链需要一次性签名仪式"这件事本身无法回避（与 Swift 侧 Phase 0 已经识别的"一次性签名仪式"同构）。

---

## 5. mihomo 打包复核（结论：GPL 边界与集成动作量均不因栈变）

来源：[Electron ASAR Archives 官方文档](https://www.electronjs.org/docs/latest/tutorial/asar-archives)、[electron#9459](https://github.com/electron/electron/issues/9459)、[electron-builder mac 配置文档](https://www.electron.build/docs/mac/)、[electron-builder Interface.MacConfiguration](https://www.electron.build/electron-builder.Interface.MacConfiguration.html)、[Node.js child_process 官方文档](https://nodejs.org/api/child_process.html)；GPL 分析本身沿用 [mihomo-integration.md §6](../mihomo-integration.md) 与 [ADR 0007](../../adr/0007-mihomo-subprocess-gpl-compliance.md)，不重新论证。

- **asar unpack / extraResources**：官方确认 asar 归档内的文件不是真实文件系统路径，`child_process.spawn`/`exec` 无法直接执行其中的二进制（只有 `execFile` 支持，且实质是先把二进制解包到磁盘再执行——[electron#9459](https://github.com/electron/electron/issues/9459)）。标准做法是用 `asarUnpack` glob 把 mihomo 排除出 asar，或直接放进 `extraResources`（落在 `Contents/Resources/` 下，天然是普通文件）。两条路径任选其一即可满足"子进程可执行"的前提，与 Swift 侧把内核当作 bundle 内普通资源文件同构。
- **electron-builder 是否自动重签**：**不自动**。electron-builder 默认会对 app 本体及其"嵌套框架、辅助程序和生成的安装程序"签名，但第三方二进制要被纳入这一签名流程，需要显式在 `mac.binaries` 配置项里声明路径（"paths to additional native binaries within your app bundle that need to be signed"）；未声明的话，`codesign --deep --strict` 在公证阶段会在这个未签名的嵌套二进制处失败——这与 [mihomo-integration.md §5](../mihomo-integration.md) 描述的陷阱（bundle 内二进制必须显式重签、否则破坏签名完整性）**逐字对应**，两栈在这一步的工程动作量相当：都需要构建脚本显式把 mihomo 纳入签名清单，用自己的 Developer ID + hardened runtime + timestamp 重签，再整体公证。
- **子进程生命周期管理的 Node 形态**：`child_process.spawn()` 返回 `ChildProcess`（继承 `EventEmitter`），标准生命周期挂 `exit`（含退出码/信号）、`close`（stdio 流关闭后触发，晚于 `exit`）、`error`（无法启动/无法 kill/IPC 失败）三个事件；长驻子进程常见模式是 `detached: true` + `stdio: 'ignore'` + `subprocess.unref()`。与 Swift `Process` 的 `terminationHandler`/`waitUntilExit` 模型能力对等，无结构性差异（与 mihomo-integration.md §3 "两栈候选下 mihomo 集成难度无实质差异"的既有结论一致）。
- **GPL 边界确认（不因栈变）**：ADR 0007 与 mihomo-integration.md §6 的分析锚点是**集成形态**——mihomo 作为独立官方二进制、以 CLI 参数启动子进程、通过 REST/WS 做控制面通信，落在 FSF GPL FAQ 所述"pipes, sockets and command-line arguments are communication mechanisms normally used between two separate programs"的 separate programs / arms-length 一侧。这个判定完全基于**进程边界与通信机制**，不涉及宿主进程用什么语言实现；Electron 侧的 `child_process.spawn` + `fetch`/WebSocket 客户端与 Swift 侧的 `Process` + `URLSession` 是同一形态的两种实现，因此 ADR 0007 的红线（禁止进程内链接/cgo/c-archive/静态嵌入执行）与义务（附 GPL-3.0 文本 + 源码获取指引、不得对 mihomo 附加额外限制）**逐字适用于 Electron 路线，无需重新论证或调整**。

---

## 6. app 体积基线

来源：多篇 2025–2026 框架/打包优化文章（交叉印证，无单一官方基准数字）；mihomo 体积数据复用 [mihomo-integration.md §5](../mihomo-integration.md)（实测 41.4 MiB 安装后/单架构，官方压缩资产 ~16MB）。

| 来源/口径 | 数字 | 备注 |
|---|---|---|
| 优化后 "Hello, World!" | ~45–46MB | 经充分裁剪的下限，非默认脚手架产物 |
| 默认脚手架产物 | ~115MB（另一来源给出 50–80MB 下限区间） | 数字不一致，取决于是否 `asar`、是否裁剪 devDependencies、是否双架构 |
| Chromium + Node 固定开销拆解 | Chromium ~40–60MB + Node ~10–20MB（另一口径给到 Chromium ~80MB + Node ~40MB） | 两组数字量级不同但方向一致：**固定运行时开销即占大头，与业务代码量无关** |
| electrobun（Electron 替代品，2026 年初对照参照物） | 12MB app bundle（Bun 运行时 10MB + 原生绑定 1.5MB + 业务代码 0.5MB） | 反向印证 Electron 基线膨胀主要来自 Chromium，而非"桌面壳"这件事本身必然昂贵 |

**综合估算**：不叠加 mihomo 时，Electron 路线 .app/.dmg 基线落在 **~45–150MB** 的宽区间（口径差异大，反映"优化程度"而非架构下限的唯一真值）；叠加 mihomo（~42MB 安装后，单架构）后预计落在 **~90–190MB**，若做双架构 universal 再 +~40MB（对照 mihomo-integration.md §5 的 lipo 合成路径），上限可到 ~230MB。对照 Swift 菜单栏 app 量级（~30–60MB 主体，见 ADR 0002）+ 同样的 mihomo ~42MB，Swift 路线预计 ~70–100MB——**Electron 路线体积普遍是 Swift 路线的 1.5–3 倍**，具体倍数强依赖打包优化投入，不是不可压缩的硬下限，但需要专门的裁剪工作才能逼近区间下限。

---

## 附：来源清单

- Electron 官方文档：[process-model](https://www.electronjs.org/docs/latest/tutorial/process-model) · [electron-timelines](https://www.electronjs.org/docs/latest/tutorial/electron-timelines) · [breaking-changes](https://www.electronjs.org/docs/latest/breaking-changes) · [security](https://www.electronjs.org/docs/latest/tutorial/security) · [app API](https://www.electronjs.org/docs/latest/api/app) · [macos-dock](https://www.electronjs.org/docs/latest/tutorial/macos-dock) · [Notification API](https://www.electronjs.org/docs/latest/api/notification/) · [nativeImage](https://www.electronjs.org/docs/latest/api/native-image) · [asar-archives](https://www.electronjs.org/docs/latest/tutorial/asar-archives)
- endoflife.date：[electron](https://endoflife.date/electron)
- electron-builder：[mac 配置](https://www.electron.build/docs/mac/) ·[Interface.MacConfiguration](https://www.electron.build/electron-builder.Interface.MacConfiguration.html) · [auto-update](https://www.electron.build/docs/features/auto-update/) · [GitHub electron-builder#7356](https://github.com/electron-userland/electron-builder/issues/7356)
- electron/electron GitHub Issues：[#592 dock.hide](https://github.com/electron/electron/issues/592) · [#9459 asar spawn](https://github.com/electron/electron/issues/9459) · [#37244 setLoginItemSettings SMAppService](https://github.com/electron/electron/pull/37244)
- Apple：[SMAppService.openSystemSettingsLoginItems()](https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems())
- Node.js：[child_process 官方文档](https://nodejs.org/api/child_process.html)
- Sparkle：[Publishing an update](https://sparkle-project.org/documentation/publishing/) · [EdDSA 迁移文档](https://sparkle-project.org/documentation/eddsa-migration/)
- 经验性/多来源交叉印证（非官方基准，已在正文标注）：Seena Burns《Debugging Electron Memory Usage》、windowslatest.com 2025-12 报道、多篇 2025–2026 Electron/Tauri 对比与打包体积优化文章（pikvue.com、raftlabs、gowombat 等）、electrobun 项目对照数据
- 本地既有调研（沿用不重查）：[mihomo-integration.md](../mihomo-integration.md)（§2 进程管理、§5 打包与分发、§6 GPL 合规、§7 版本策略）、[ADR 0002](../../adr/0002-swift-native-stack.md)、[ADR 0007](../../adr/0007-mihomo-subprocess-gpl-compliance.md)、[v1-roadmap.md](../../v1-roadmap.md) Phase 3
