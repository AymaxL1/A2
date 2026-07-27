# Swift Mac 原生路线核查（Mac-only 前提）

> 调研日期：2026-07-27
> 对应票：`.scratch/v1-mac-recharter/issues/01-swift-mac-route-check.md`
> 对照文档：[platform-framework-research.md](platform-framework-research.md)（2026-07-16，当时前提为 macOS+Windows 双平台，推荐 Electron+TS）
> 资料原则：事实引一手来源（Apple 官方文档、swift.org、OpenAI Codex 官方文档、Sparkle 官方资料、本机 man page）；推断与工程判断明确标注 **【推断】**；非官方证据标注 **【社区】**。
> 本票只提供 Swift 侧事实，不下最终裁决——裁决属于「技术栈决定」票。

## 0. 结论摘要

### 对「Mac-only 下选 Swift」的顺风

1. **窗口能力零缺口且是「去中间层」**：宠物悬浮窗所需的透明、置顶、点击穿透、跨 Space/全屏可见，全部是 `NSWindow` 一手原语（`ignoresMouseEvents`、`collectionBehavior`、`level`）；Electron 在 macOS 上的同名能力（`setIgnoreMouseEvents`、`setVisibleOnAllWorkspaces`、`setAlwaysOnTop` 的 level 取值）就是这些原语的包装。Mac-only 消除了 Electron 的核心卖点（跨平台一致性），窗口层 Swift 能力上限只高不低。
2. **常驻应用工程面官方 API 完整且现代**：登录项/开机自启（`SMAppService`，macOS 13+）、系统通知（UserNotifications，对 Developer ID 分发无额外限制）、签名+公证是平台级要求（Electron 同样要做）、Sparkle 2 更新框架活跃、支持沙箱与 SPM。
3. **Codex 降级路径与语言无关**：`codex exec --json` 是官方定位给自动化的 JSONL-over-stdio 接口，从 Swift `Process` 驱动与从 Node 驱动完全等价；`codex app-server` 是 JSON-RPC 2.0 over stdio，官方提供 JSON Schema 导出（`generate-json-schema`），Swift 裸写协议客户端技术上可行。
4. **系统代理在 V1 深度内绕得开特权助手**：admin 用户直接调 `networksetup` 改代理无需弹窗；要覆盖非 admin/零弹窗，`SMAppService.daemon`（一次性系统设置审批）即可，不需要老式 SMJobBless 助手。
5. **单元/集成测试闭环与 TS 同级**：SPM 多包/多 target 能承载 contracts/host/plugins 分层，模块边界编译期强制；swift-testing（Swift 6 / Xcode 16 起）现代化、纯 CLI（`swift test`）可跑，AI 在该层的写-测-验回路不弱于 TS。

### 对「Mac-only 下选 Swift」的逆风

1. **Codex 无官方 Swift SDK**：官方 SDK 只有 TypeScript（Node 18+）与 Python（3.10+）；app-server 的类型面要自己从 JSON Schema 生成或手写，且协议仍在演进、部分 API 明确标 experimental——类型维护成本长期落在本项目头上，而 TS 路线免费获得官方类型与 SDK 更新。
2. **UI 自动化闭环弱于 TS/Playwright 一档**：swift-testing 明确不覆盖 UI 自动化，必须回 XCTest/XCUITest；SPM 没有 UI 测试 target 类型，XCUITest 依赖 Xcode 工程 + `xcodebuild` + GUI 会话，回路分钟级；断言面靠 accessibility 树而非 DOM。对「AI 驱动开发、用户不会 Swift」，UI 层的自动验证是最大短板，需靠架构补偿（详见第 5 节；注意 Playwright 的 Electron 驱动官方也标 experimental，Electron 侧同样不是满分）。
3. **SwiftUI 年度 API 演进大、语料密度低**：Apple 官方 updates 页显示 SwiftUI 每年 6 月成批新增/重构 API；Stack Overflow 2025 调查中 JavaScript 66%、TypeScript 43.6%、Swift 5.4%（语料规模的代理指标）。AI 产出更依赖编译器护栏，用户无法人工兜底。
4. **SwiftUI `MenuBarExtra` 有已知第一方 API 空洞**：无法编程开合面板、拿不到底层 `NSStatusItem`（有 Apple 反馈单为证）；复杂菜单栏交互要 AppKit `NSStatusItem` 兜底（能力完整，但要写桥接层）。
5. **未签名构建用 UserNotifications 会崩**：`bundleProxyForCurrentProcess is nil` 崩溃意味着连本地开发循环也要求 .app bundle + 签名，这是 AI 自动化本地验证的一个摩擦点（对 Electron 开发期同样存在类似约束，但 Node 侧常用 mock 掉通知层）。

---

## 1. 关键窗口能力

### 1.1 菜单栏常驻：`MenuBarExtra` 够用面与 AppKit 退回点

**事实（Apple 官方文档）：**

- SwiftUI [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)（macOS 13+）是"A scene that renders itself as a persistent control in the system menu bar"。默认下拉菜单样式；`.menuBarExtraStyle(.window)` 可换成"popover-like window from the menu bar icon"，适合数据较丰富的面板。
- 纯菜单栏应用需在 Info.plist 设 `LSUIElement=true` 隐藏 Dock 图标；文档同时警告："An app that only shows in the menu bar will be automatically terminated if the user removes the extra from the menu bar."（本平台有悬浮窗与控制中心窗口，不属于"只有菜单栏"的应用，此项影响有限。**【推断】**）
- AppKit [`NSStatusItem`](https://developer.apple.com/documentation/appkit/nsstatusitem)（"An individual element displayed in the system menu bar"）由 `NSStatusBar.statusItem(withLength:)` 创建，提供 `button`（完全自定义外观/事件）、`menu`、`isVisible`、`behavior`、`length`（含 `variableLength`）、`autosaveName` 等全量控制。

**必须退回 `NSStatusItem` 的场景（社区证据 + 官方反馈单）【社区】：**

- MenuBarExtra 没有第一方 API 来：编程开合/关闭其面板、访问底层 `NSStatusItem`、访问弹出的 `NSWindow`。已有公开 Apple Feedback：[FB10185203（无法编程 show/hide）](https://github.com/feedback-assistant/reports/issues/328)、[FB11984872（.window 样式内控件无法关闭自身面板）](https://github.com/feedback-assistant/reports/issues/383)。
- 社区库 [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) 专为补这些洞而存在（其 README 明确列出上述缺口），侧面证明缺口真实且常见。

**结论：** 菜单栏入口本身两条路都通。简单「图标+菜单/面板」用 `MenuBarExtra` 即可；需要「点图标切换自绘面板、动画图标、程序化开合」时退回 `NSStatusItem`——AppKit 侧能力完整、无平台缺口，成本是一层 AppKit/SwiftUI 桥接代码。**【推断】**

### 1.2 宠物悬浮窗：透明、置顶、点击穿透、跨 Space/全屏

**事实（Apple 官方文档）：**

| 需求 | 原生 API | 官方描述 |
|---|---|---|
| 点击穿透 | [`NSWindow.ignoresMouseEvents`](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents) | "A Boolean value that indicates whether the window is transparent to mouse events." |
| 置顶 | [`NSWindow.level`](https://developer.apple.com/documentation/appkit/nswindow/level-swift.property) | "Each level in the list groups windows within it in front of those in all preceding groups. Floating windows, for example, appear in front of all normal-level windows." |
| 所有 Space 可见 | [`NSWindow.CollectionBehavior.canJoinAllSpaces`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) | "The window can appear in all spaces." |
| 全屏 app 之上可见 | 同上 `.fullScreenAuxiliary` | "The window displays on the same space as the full screen window." |
| Mission Control 不动它 | 同上 `.stationary` | "Mission Control doesn't affect the window, so it stays visible and stationary, like the desktop window." |
| 透明 | [`isOpaque`](https://developer.apple.com/documentation/appkit/nswindow/isopaque) + `backgroundColor` + `alphaValue` + `hasShadow` | 文档将四者并列于"Configuring the Window's Appearance"；无边框透明窗即 `styleMask=.borderless` + `isOpaque=false` + `backgroundColor=.clear` 的标准组合 **【推断（惯用法，属性本身为官方文档）】** |

[`collectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.property) 官方定义为"Window collection behaviors related to Mission Control, Spaces, and Stage Manager"，正是宠物窗所需的那组开关。

**SwiftUI 现状：** SwiftUI 正在补窗口控制（macOS 15 新增 [`Scene.windowLevel(_:)`](https://developer.apple.com/documentation/swiftui/scene/windowlevel(_:))，例：`.windowLevel(.floating)`），但点击穿透、`collectionBehavior` 仍无 SwiftUI 原生 API——宠物窗的现实做法是 `NSWindow`（或 `NSPanel`）+ `NSHostingView` 装 SwiftUI 内容。**【推断（基于两侧 API 面的有无）】**

### 1.3 与 Electron `BrowserWindow` 方案对照

**事实（[Electron 官方文档](https://www.electronjs.org/docs/latest/api/browser-window)）：**

- `win.setIgnoreMouseEvents(ignore[, options])`："Makes the window ignore all mouse events"；`forward` 选项（穿透时仍转发 mousemove）标注 macOS/Windows。
- `win.setVisibleOnAllWorkspaces(visible[, options])` 标注 macOS/Linux（"This API does nothing on Windows"）；`visibleOnFullScreen` 选项为 macOS 专属。
- `win.setAlwaysOnTop(flag[, level])` 在 macOS 上的 level 取值（`floating`、`status`、`pop-up-menu`、`screen-saver` 等）就是 `NSWindow.Level` 的对应物。

**对照结论：** 在 macOS 上，Electron 的悬浮窗能力是对同一组 `NSWindow` 原语的封装与子集暴露；Mac-only 前提下 Swift 直接持有原语，可做 Electron 封装未暴露的组合（如结合 `NSTrackingArea`/事件监视做像素级动态点击区域），不存在「Electron 能做、原生做不到」的窗口能力。旧调研文档中 Electron 此项的「决定性优势」在 Mac-only 下不再成立——它当时的价值在于同一套 API 同时覆盖 Windows。**【推断（对照两侧官方 API 面）】**

## 2. 常驻应用工程面

### 2.1 登录项 / 开机自启：`SMAppService`（macOS 13+）

**事实（[Apple 官方文档](https://developer.apple.com/documentation/servicemanagement/smappservice)）：**

- `SMAppService` 是"An object the framework uses to control helper executables that live inside an app's main bundle"，统一管理登录项、LaunchAgent、LaunchDaemon，取代旧 `SMLoginItemSetEnabled` 与手装 plist。
- 主应用自启即 `SMAppService.mainApp` + [`register()`](https://developer.apple.com/documentation/servicemanagement/smappservice/register())："The application launches on subsequent logins."
- 用户可在系统设置撤销（`kSMErrorLaunchDeniedByUser`），并有 `openSystemSettingsLoginItems()` 引导入口。
- LaunchDaemon（第 4 节代理会用到）："The system won't bootstrap the LaunchDaemon until an admin approves the LaunchDaemon in System Preferences."——即一次性管理员审批，之后每次开机自动拉起。

### 2.2 系统通知：UserNotifications 与非 MAS 分发

**事实（[Apple 官方文档](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)）：**

- `UNUserNotificationCenter.requestAuthorization(options:)` 请求授权："The first time your app makes this authorization request, the system prompts the person to grant or deny the request and records that response. Subsequent authorization requests don't prompt the person."
- 支持 provisional（静默试用）授权；官方要求调度前检查 `authorizationStatus`。
- 官方文档未对 App Store / Developer ID 分发做任何区分——本地通知不需要 MAS，也不需要推送证书。**【推断（基于文档无此限制 + 大量 Developer ID 应用实际使用）】**

**非 MAS 的真实坑（未签名构建）【社区，含 Apple 论坛】：**

- 未签名/非 bundle 进程调用 UserNotifications 会直接崩溃：`NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil`。见 [Apple Developer Forums #649583](https://developer.apple.com/forums/thread/649583) 与 [wezterm #6731](https://github.com/wezterm/wezterm/issues/6731)（unsigned build 场景复现）。
- 工程含义：通知相关代码必须以「签好名的 .app bundle」形态运行——本地开发/CI 也要走开发证书或 ad-hoc 签名，纯 `swift run` 可执行文件测不了真通知，需在测试中隔离通知端口。**【推断】**

### 2.3 非 App Store 分发：签名 + 公证

**事实（[Apple 官方文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)）：**

- "Beginning in macOS 10.15, all software built after June 1, 2019, and distributed with Developer ID must be notarized."
- 要求 Developer ID 证书 + "Enable the Hardened Runtime capability"。
- "Notarization of macOS software is not App Review."——自动扫描，非人工审核。

**对照：** 该要求作用于所有 macOS 分发渠道的产物，Electron 应用同样必须签名+公证；此项是平台成本，不构成 Swift/Electron 差异。差异在于 Swift/Xcode 工具链对签名公证是第一方集成（`xcodebuild`、`notarytool`），Electron 需 electron-builder 等第三方封装。**【推断】**

### 2.4 更新：Sparkle 现状

**事实（[Sparkle 官方文档](https://sparkle-project.org/documentation/) 与 [GitHub 仓库](https://github.com/sparkle-project/Sparkle)）：**

- Sparkle 2 现行支持："Runtime: macOS 12.0 or later on `2.x`, macOS 10.13 or later on `2.9.3`"；项目活跃（2.x 分支 4300+ commits，持续发版）。
- 安全模型："Updates are verified using EdDSA signatures and Apple Code Signing"；要求 HTTPS appcast、应用本身完成 Developer ID 签名与公证。
- 支持沙箱应用（官方 sandboxing guide）、支持 SwiftUI/程序化接入、支持 SPM 安装、支持 delta 更新与原子安装。

**结论：** 非 MAS 的 Mac 应用更新在 Swift 侧是成熟的既有轮子，与 Electron 的 autoUpdater（macOS 上同样要求签名）能力对等。**【推断（对照旧文档 Electron autoUpdater 一节）】**

## 3. Codex 集成成本（Swift 路线最大逆风项，逐条核实）

> 域名说明：旧调研文档引用的 learn.chatgpt.com 确为官方文档现址——实测 `developers.openai.com/codex/*` 308 永久重定向到 `learn.chatgpt.com/docs/*`。

### 3.1 官方 SDK 矩阵：没有 Swift

**事实（[Codex SDK 官方文档](https://learn.chatgpt.com/docs/codex-sdk)、[TypeScript SDK README](https://github.com/openai/codex/tree/main/sdk/typescript)）：**

- 官方 SDK 仅两种：TypeScript——"requires Node.js 18 or later"；Python——"requires Python 3.10 or later"。无 Swift、无其他语言。
- TS SDK 的实现方式是包装 CLI：spawn `codex` 进程并通过 stdin/stdout 交换 JSONL 事件；Python SDK "controls the local Codex app-server over JSON-RPC"。
- 即：官方 SDK 本质都是「子进程 + JSONL/JSON-RPC 客户端」，并非绑定 Node 运行时的深层能力——这决定了 Swift 裸写同类客户端在原理上没有障碍，差的是官方维护的类型与封装。**【推断（基于 SDK 实现方式的官方描述）】**

### 3.2 Swift 直连 `codex app-server` 的可行性

**事实（[app-server 官方文档](https://learn.chatgpt.com/docs/app-server)、[codex-rs/app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)）：**

- 定位："Codex app-server is the interface Codex uses to power rich clients (for example, the Codex VS Code extension)"；"Use it when you want a deep integration inside your own product."
- 协议：JSON-RPC 2.0 双向通信，注意细节——"with the `\"jsonrpc\":\"2.0\"` header omitted on the wire"（线上帧省略 jsonrpc 头），stdio 传输为默认（newline-delimited JSON/JSONL）；WebSocket 传输"experimental and unsupported"。
- 握手与模型：连接后先 `initialize` + `initialized`，随后 `thread/start`、`turn/start`，经 `item/*`、`turn/*` 通知流式收结果；支持 server-initiated requests（审批回调等）。
- 稳定性：核心 thread/turn/item 流程文档化；不少 API 标注 experimental（须开 `capabilities.experimentalApi`，"under development; do not call from production clients yet"）。

**Swift 侧成本评估【推断】：**

- 传输层薄：Foundation [`Process`](https://developer.apple.com/documentation/foundation/process)/`Pipe` 管理子进程 stdio 是标准库能力，JSONL 逐行解析 + JSON-RPC 路由是几百行级别的基建。
- 真实成本在类型面与演进面：请求/通知/审批的完整类型要自己建；协议随 Codex CLI 版本演进（experimental 面会移动），每次升级需要自己 diff schema、改代码——TS 路线里这部分由官方 SDK/生成的 TS types 吸收。这是持续性成本，不是一次性成本。

### 3.3 Schema 生成物对 Swift 的可用性

**事实（[app-server 官方文档](https://learn.chatgpt.com/docs/app-server)）：**

- "You can generate a TypeScript schema or a JSON Schema bundle from the CLI"：`codex app-server generate-ts` 与 `codex app-server generate-json-schema`。
- 官方生成目标只有 TypeScript 与 JSON Schema，无 Swift。

**含义【推断】：** JSON Schema bundle 可作为 Swift 类型的生成源（经 quicktype 等第三方生成器转 Codable，或据其手写核心子集），并可在 CI 中对 pin 住的 Codex 版本做 schema drift 检测。可行，但生成质量与增量维护要自己负责，属「二等公民但有正门」的状态。

### 3.4 降级路径：Swift 驱动 `codex exec --json`

**事实（[非交互模式官方文档](https://learn.chatgpt.com/docs/non-interactive-mode)）：**

- "Non-interactive mode lets you run Codex from scripts (for example, continuous integration (CI) jobs) without opening the interactive TUI."
- `--json` 下"stdout becomes a JSON Lines (JSONL) stream so you can capture every event Codex emits while it's running"。
- 支持会话续跑：`codex exec resume --last` / `codex exec resume <SESSION_ID>`；文档以 CI/自动化为第一场景（含 GitHub Actions 示例）。

**结论：** 此路径对任何能 spawn 子进程、读 JSONL 的语言完全等价，Swift 无任何额外成本；作为 app-server 不稳时的降级面成立。牺牲的是深度交互（审批回调、双向请求）——与旧调研文档对该降级路径的判断一致。**【推断（成本对比部分）】**

## 4. 系统代理设置（V1 仅系统代理深度）

**事实一（本机 `man networksetup`，networksetup(8)）：**

- "The networksetup command is used to configure network settings typically configured in the System Preferences application. **The networksetup command requires at least admin privileges to change network settings.** If the 'Require an administrator password to access system-wide preferences' option is selected in System Preferences > Security & Privacy, then **root privileges are required**."
- 代理相关子命令齐全：`-setwebproxy` / `-setsecurewebproxy` / `-setsocksfirewallproxy`（及对应 `-set...state on|off`）、`-setproxybypassdomains`、`-setautoproxyurl`。

**事实二（Apple DTS 在 [Developer Forums #805149](https://developer.apple.com/forums/thread/805149) 的回答，SystemConfiguration 路线）：**

- 编程改系统代理走 `SCPreferences`，非 root 进程用 `SCPreferencesCreateWithAuthorization`；系统用 Authorization Services 检查 `system.services.systemconfiguration.network` 右，其规则为 `authenticate-admin-nonshared`、`"timeout" => 30`——"the right won't use a credential that's older than 30 seconds"，因此连续修改会反复弹管理员授权框。
- DTS 给出的免弹窗方案："The workaround is … to do this work as root."（`is-root` 规则直接满足该右）。

**事实三（[SMAppService.register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) 官方文档）：** 以 `SMAppService.daemon` 注册 root LaunchDaemon，仅需管理员在系统设置一次性批准（"The system won't bootstrap the LaunchDaemon until an admin approves the LaunchDaemon in System Preferences"），之后随系统自启。

**V1 结论（按深度需求排列）【推断（组合上述事实）】：**

1. **最低成本**：应用以 admin 用户身份 spawn `networksetup`——默认安全设置下改代理不弹任何窗（个人 Mac 首账号通常即 admin）。局限：非 admin 用户、或开了"系统级偏好需管理员密码"时失效。
2. **UI 内直改**：`SCPreferencesCreateWithAuthorization`——无需 helper，但每 30 秒授权时效带来反复弹窗，只适合低频切换。
3. **完全体**：`SMAppService.daemon` 注册 root 守护进程（XPC 通信），一次审批后零弹窗、覆盖非 admin、可靠恢复——这已是现代官方机制，**不需要**已废弃的 SMJobBless 老式特权助手。
4. 与 Electron 对照：Electron 同样只能走这三条路（child_process 调 networksetup / 原生模块调 SC API / 特权守护进程），此项不构成两栈差异；差异仅在第 3 条上 Swift 写 daemon+XPC 是第一方路径，Electron 需混入原生代码或独立二进制。**【推断】**

> 超出 V1 的注：TUN 模式、按 App 分流等需要 Network Extension（system extension、单独审批面），本票按票面约定不展开。

## 5. 工程与测试（含「AI 驱动开发」前提下的闭环现实程度）

### 5.1 SPM monorepo 能否承载 contracts / host / plugins 分层

**事实（[Swift Package Manager 官方文档](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/)、[PackageDescription.Target](https://developer.apple.com/documentation/packagedescription/target)）：**

- "The Swift Package Manager lets you share your code as a package, depend on and use other shared packages, as well as build, test, document, and run your code."
- 一个 package 可含任意多 target（`target` / `executableTarget` / `testTarget` / `binaryTarget` / `plugin` / `macro`），target 间与包间依赖显式声明；支持本地路径依赖（monorepo 多包互引）；重名冲突有 module aliasing。
- 模块边界是编译期强制：未声明依赖就 `import` 不了——旧调研文档 4.1 节的 contracts/plugin-sdk/host-runtime/plugin-* 分层可直接映射为「一仓多包」或「单包多 target」，且边界约束比 TS 项目靠 lint 规则更硬。**【推断（映射部分）】**
- 限制：app 壳（签名、Info.plist、资源、XCUITest target）仍需一个 Xcode 工程（可由 XcodeGen/Tuist 从声明生成）；SPM 自身不产出 .app。**【推断（基于 SPM 文档范围 + 下述 target 类型清单）】**

### 5.2 测试框架现状

**事实：**

- [swift-testing](https://developer.apple.com/documentation/testing/)：Swift 6.0 / Xcode 16.0 起随工具链分发；宏驱动（`@Test`/`#expect`）、参数化、tags、进程内并行、与 Swift 并发深度集成；"integrates seamlessly with Swift Package Manager testing workflow"——`swift test` 纯 CLI 可跑。
- UI 自动化与性能测试不在 swift-testing 范围：Apple 官方指引是继续用 XCTest 的 UI automation（`XCUIApplication`）与性能 API（[WWDC24「Meet Swift Testing」](https://developer.apple.com/videos/play/wwdc2024/10179/)）。
- [`XCUIApplication`](https://developer.apple.com/documentation/xctest/xcuiapplication)："A proxy that can launch, monitor, and terminate a test application"——黑盒驱动真实 app，走 accessibility 树查询与合成事件。
- SPM 的 target 类型全表（[PackageDescription.Target](https://developer.apple.com/documentation/packagedescription/target)）中**没有 UI 测试 bundle 类型**——XCUITest target 只能挂在 Xcode 工程下，用 `xcodebuild test` 驱动。

### 5.3 「AI 写-测-验闭环」的现实程度（票的重点问题）

**分层评估【推断（基于上述一手事实的工程判断）】：**

| 层 | Swift 路线 | 对照 TS/Electron 路线 | 差距 |
|---|---|---|---|
| 领域/单元/契约 | `swift test`（swift-testing），秒级、无 GUI、纯 CLI，编译器先杀掉一整类错误 | vitest/jest | **无差距**，类型强度还略占优 |
| 视图快照 | 社区标准 [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)【社区】：unit 层把 SwiftUI 视图渲染成图片/文本产物，AI 可 diff | Playwright screenshot / jest snapshot | 略弱（生态单一），但闭环形态相同 |
| 应用内 UI 驱动 | XCUITest：需 Xcode 工程 + 构建整 app + GUI 会话，单轮分钟级；断言面 = accessibility 树（需自觉维护 accessibilityIdentifier），无 DOM dump 可读 | Playwright 驱动 web 内容成熟（selector、trace、自动等待）；但对 Electron 壳的驱动官方标注 experimental（[Playwright Electron](https://playwright.dev/docs/api/class-electron)） | **明显更弱**：迭代慢、AI 语料少、失败诊断靠 .xcresult 截图/日志 |
| 系统面（托盘、悬浮窗置顶/穿透、通知、登录项） | XCUITest 也只能覆盖部分；本质要真机冒烟 | Electron 侧同样是 Playwright 盲区（旧调研文档已承认需平台脚本/人工冒烟） | **两栈同样痛**，不构成净差距 |

**兜底手段（「用户不会 Swift」时让 AI 闭环最大化）【推断/工程建议】：**

1. **把可验证性下沉**：UI 做薄，状态机/ViewModel/能力层全部落在 swift-testing 可测的纯 Swift 包——与旧调研文档对 Electron 的分层建议同构，Swift 下由模块边界强制执行。
2. **快照当「可 diff 的眼睛」**：关键视图（宠物形态、面板布局）用快照测试生成图片产物，AI 与人都能直接看图对比，绕开「读不懂 Swift 断言」的问题。
3. **自检出口**：宿主暴露诊断 CLI/端口（能力调用、窗口状态回报），让端到端验证走机器接口而非像素——这也是平台本身「能力注册表 + CLI」架构的副产品。
4. **XCUITest 只保少量冒烟**（启动、菜单栏入口、宠物窗出现、通知授权路径），在 `xcodebuild test` 里跑，产物（.xcresult 截图）作为人工可审计证据。
5. **编译即评审**：Swift 强类型 + Swift 6 数据竞争检查让大量 AI 错误在 build 阶段报出（见第 6 节），部分补偿 UI 层验证弱。

**诚实结论：** UI 自动化端 Swift 确实比 TS/Playwright 弱一档且更慢，这是逆风中最实的一条；但 (a) 差距集中在「应用内 UI 驱动」一层，(b) Electron 在系统面同样依赖人工冒烟、其 Playwright 驱动也是 experimental，(c) 本平台架构（能力层薄 UI）恰好把大部分验证需求移出了最弱的那层。补偿可行，代价是必须持续保持分层纪律。

## 6. AI 代写 Swift 的风险面

### 6.1 语言/框架年度变动

**事实：**

- Apple 官方 [SwiftUI updates](https://developer.apple.com/documentation/updates/swiftui) 页逐年记录 API 变化：2023（visionOS/Observation）、2024、2025（Liquid Glass、scroll edge effects、AttributedString 编辑等十余类）、2026.6（`@State` 宏化、`ContentBuilder` 统一替代 `ToolbarContentBuilder` 等类型专用 builder、文档类 API 等）——每年 6 月一波数十项级别的新增/重构，部分属于惯用法替换。
- Swift 语言层：[Swift 6 迁移指南](https://www.swift.org/migration/documentation/migrationguide/)："With the Swift 6 language mode, the compiler can now guarantee that concurrent programs are free of data races"；"Adopting the Swift 6 language mode is entirely under your control on a per-target basis"——严格并发是每 target 可选、可渐进。

**风险解读【推断】：** AI 训练语料通常滞后最新 SDK 一年上下，倾向写「去年的惯用法」；缓解因素是 Apple 的弃用周期长，旧写法一般仍编译可用，主要风险是「非最新/混搭」而非「不能用」。严格并发是双刃：开启后编译器把 AI 的并发错误显式逼出（护栏），但报错噪音也显著增加（摩擦）。

### 6.2 社区资料密度

**事实（代理指标）：** [Stack Overflow 2025 开发者调查](https://survey.stackoverflow.co/2025/technology)：过去一年大量使用 JavaScript 66%、TypeScript 43.6%、**Swift 5.4%**。

**解读【推断】：** 该数字是语料规模/问答密度的代理指标，不直接测量 AI 代码质量；但方向明确——Swift+AppKit 组合（尤其菜单栏、悬浮窗这类小众场景）的公开语料远薄于 Web/TS，AI 首轮产出的正确率与自我纠错材料都会更差，冷门 API 上更易幻觉。缓解因素：本项目所需 API 高度集中在第一方框架（AppKit/SwiftUI/UserNotifications/ServiceManagement），第一方文档质量高且稳定，属 Swift 语料里密度最高的部分。

### 6.3 用户无法人工兜底时的护栏【推断/工程建议】

1. **编译器是第一道自动审查**：强类型 + 显式模块边界 + （渐进开启的）Swift 6 数据竞争检查，把一大类 AI 错误挡在运行前；这是相对 TS（`any`/运行时逃逸更多）的真实优势。
2. **全链路 CLI 化**：`swift build/test`、`xcodebuild test`、`xcrun notarytool` 全部可脚本化——AI 可自主完成「改-编-测-打包」循环，无需用户操作 Xcode GUI。
3. **产物化验证**：快照图片、JSONL 事件日志、.xcresult 截图，让「对不对」变成用户不懂 Swift 也能肉眼判断的产物。
4. **依赖面收紧**：优先第一方框架，第三方仅收活跃且事实标准者（Sparkle、swift-snapshot-testing 级别），减少 AI 踩小众库坑的面。
5. **SDK 版本窗口纪律**：每年 WWDC 后 pin 住 Xcode/SDK 版本一段时间再升级，把年度 API 演进的冲击变成计划内批处理。

---

## 附：来源清单（一手）

- Apple：[MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) · [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem) · [NSWindow.ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents) · [NSWindow.collectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.property) / [CollectionBehavior 常量](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) · [NSWindow.level](https://developer.apple.com/documentation/appkit/nswindow/level-swift.property) · [NSWindow.isOpaque](https://developer.apple.com/documentation/appkit/nswindow/isopaque) · [Scene.windowLevel(_:)](https://developer.apple.com/documentation/swiftui/scene/windowlevel(_:)) · [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) / [register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) · [Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications) · [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [Swift Testing](https://developer.apple.com/documentation/testing/) · [WWDC24 Meet Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10179/) · [XCUIApplication](https://developer.apple.com/documentation/xctest/xcuiapplication) · [PackageDescription.Target](https://developer.apple.com/documentation/packagedescription/target) · [SwiftUI updates](https://developer.apple.com/documentation/updates/swiftui) · [DTS 论坛回答 #805149（系统代理授权）](https://developer.apple.com/forums/thread/805149) · [论坛 #649583（未签名通知崩溃）](https://developer.apple.com/forums/thread/649583)
- swift.org：[SwiftPM 文档](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/) · [Swift 6 迁移指南](https://www.swift.org/migration/documentation/migrationguide/)
- OpenAI Codex（developers.openai.com → learn.chatgpt.com 官方重定向）：[app-server](https://learn.chatgpt.com/docs/app-server) · [app-server README（openai/codex）](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md) · [Codex SDK](https://learn.chatgpt.com/docs/codex-sdk) · [TS SDK](https://github.com/openai/codex/tree/main/sdk/typescript) · [非交互模式](https://learn.chatgpt.com/docs/non-interactive-mode)
- Sparkle：[官方文档](https://sparkle-project.org/documentation/) · [仓库](https://github.com/sparkle-project/Sparkle)
- Electron（对照）：[BrowserWindow](https://www.electronjs.org/docs/latest/api/browser-window) · [Playwright Electron（experimental）](https://playwright.dev/docs/api/class-electron)
- 本机：`man networksetup`（networksetup(8)）
- 社区证据（已标注）：[FB10185203](https://github.com/feedback-assistant/reports/issues/328) · [FB11984872](https://github.com/feedback-assistant/reports/issues/383) · [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) · [wezterm #6731](https://github.com/wezterm/wezterm/issues/6731) · [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) · [SO 2025 调查](https://survey.stackoverflow.co/2025/technology)
