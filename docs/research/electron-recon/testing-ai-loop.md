# Electron 回退研究：测试与 AI 闭环——ADR 0002 四项成本翻转核实

- 对应票：[`.scratch/electron-recon/issues/05-testing-ai-loop.md`](../../../.scratch/electron-recon/issues/05-testing-ai-loop.md)
- 靶子：[ADR 0002](../../adr/0002-swift-native-stack.md) Consequences 段「用户明确接受的成本」四项
- 底稿：[`platform-framework-research.md`](../platform-framework-research.md) §9（测试层级）/§9.2（CI 门禁）——本票只检验其 2026-07 现状，不重新设计
- 正向对照：[`Spikes/S1PetOverlay/README.md`](../../../Spikes/S1PetOverlay/README.md)——Swift 侧 AI 自主改-编-测循环的实证，本票如实引用作对比基线
- 调研时间：2026-07-28

## 结论摘要

| ADR 0002 成本项 | 切回 Electron 是否翻转为收益 | 一句话结论 |
|---|---|---|
| 彻底失去自读兜底 | 部分翻转 | 恢复的是「读得懂」而非「读了就能独立改对」，且仅覆盖用户实际会读的浅层 |
| XCUITest 分钟级闭环 | 表面翻转，DOM 面属实；非 DOM 面（Tray/菜单/系统弹窗）**不翻转** | Playwright/WDIO 对非 DOM 面同样要靠白盒 stub，不是真 E2E——两栈在这里同弱 |
| 语料密度差距 | 翻转，但打折扣 | TS 通用语料远超 Swift 属实；但 Electron 专属 API（Tray/dialog/权限）语料并不比 SwiftUI/AppKit 菜单栏场景丰富多少 |
| 年度 SDK 升级纪律 | 翻转 | Electron/Chromium 升级节奏更密（约 8 周 major），但每次改动幅度小、破坏性远低于 SwiftUI 年度大版本；纪律负担从「集中大爆炸」变成「持续小摩擦」，总量未必更低 |

**关键裁决影响**：非 DOM 面 E2E 核查显示 Swift 的 XCUITest 弱项**不构成 Electron 的差异化优势**——两栈在 Tray/原生菜单/系统弹窗上都退化为「白盒程序化触发 + IPC/evaluate 打桩」，不是真正的黑盒系统级点击。这条是本票对 ADR 0002 权重的最大修正。

---

## 1. E2E：DOM 面 vs 非 DOM 面

### 1.1 DOM 面（渲染进程窗口内容）——基本属实

- **Playwright `_electron`**：官方文档标题仍标注 `experimental`（2026-07 现状不变），但据 Playwright 维护者 mxschmitt 在社区讨论中的说法，该 API 至今无破坏性变更、VSCode 等大型客户在用，生产可用性实践上已经足够；`experimental` 更多是标签遗留而非质量声明。[Playwright Electron docs](https://playwright.dev/docs/api/class-electron)、[GitHub issue #39477](https://github.com/microsoft/playwright/issues/39477)、[ray.run 社区讨论](https://ray.run/discord-forum/threads/141836-state-of-electron-support-on-playwright)
- **WebdriverIO**：官方推荐路径已从 `wdio-electron-service`（社区版，README 标注 `DEPRECATED`，39 star）迁移到 `@wdio/electron-service`（WebdriverIO 官方组织维护），是 Electron 官方文档的首选推荐工具。[Electron 官方自动化测试文档](https://www.electronjs.org/docs/latest/tutorial/automated-testing)、[wdio-electron-service README](https://github.com/webdriverio-community/wdio-electron-service/blob/main/README.md)
- **闭环速度**：`_electron.launch()` 默认超时 30s，本地典型启动/首个断言在数秒量级，CI 环境常见 10–20s 冷启动延迟（受沙箱/资源限制影响）。「秒级闭环」在**本地热路径**上属实，但不是无条件的——CI 首次拉起仍有实打实的进程冷启动成本，量级上仍明显快于 XCUITest 的分钟级，这条差异化成立。[Playwright ElectronApplication](https://playwright.dev/docs/api/class-electronapplication)、[Simon Willison 实测记录](https://til.simonwillison.net/electron/testing-electron-playwright)

### 1.2 非 DOM 面（Tray / 原生菜单 / 系统弹窗）——核心核查，结论：两栈同弱

这是本票权重最高的一节：**若 Electron 在非 DOM 面同样弱，则 ADR 0002 里「XCUITest 分钟级闭环」这条成本，在回退动机里就不构成差异化理由**——因为两边最终都要靠白盒变通，差的只是速度，不是能力上限。核查结果：

- **系统托盘（Tray）点击**：无论 Playwright 还是 WebdriverIO，都没有「模拟系统级鼠标点击菜单栏图标」的官方 API。社区可查到的做法（如 `electron-tray-test` 仓库）本质是**手动点击 + 主进程事件监听打印日志**，不是自动化 E2E；且 Electron 自身在 macOS 上对 Tray 点击事件的支持有已知历史缺陷（外接鼠标左键点击不触发，见 [electron/electron#4796](https://github.com/todbot/electron-tray-test)）。真正可自动化的路径是绕过系统点击、直接在测试里调用/触发主进程里 Tray 的事件回调（白盒）。
- **原生菜单（应用主菜单/右键菜单）**：Playwright 官方明确「无法访问 Electron 的 context/popup 菜单」（[issue #11100](https://github.com/microsoft/playwright/issues/11100)），应用主菜单可通过 `electron-playwright-helpers` 的 `clickMenuItemById()` 等辅助函数触发——但这是**程序化按 ID 调用菜单项**，不是模拟真实点击菜单栏 UI；右键 context menu 目前双方文档都没有可行路径。[playwright.dev/docs/api/class-electron](https://playwright.dev/docs/api/class-electron)
- **系统弹窗（`dialog.showOpenDialog`/`showSaveDialog`/`showMessageBox`）**：Playwright 官方原话——「不拦截原生 dialog API，因为它们发生在主进程并直接调用 OS API」。官方推荐做法是用 `electronApplication.evaluate()` 在主进程里**替换 dialog 模块的方法**，让测试全程不出现真实系统 UI（即打桩，不是真交互）。`electron-playwright-helpers` 的 `stubDialog()`/`stubMultipleDialogs()` 是这条路径的社区封装，活跃维护（82 star，v2.0 覆盖 Electron 27+）。[Playwright Electron docs](https://playwright.dev/docs/api/class-electron)、[electron-playwright-helpers](https://github.com/spaceagetv/electron-playwright-helpers)
- **通知权限弹窗**：macOS 上 Electron 通知走系统 `UNNotification`，需要签名才会真正出现；权限弹窗是 **macOS 系统级 UI**，不属于 Electron 进程窗口树，Playwright/WebdriverIO 均无内建拦截或交互能力，需要外部方案（AppleScript/Accessibility API）才能点掉。

**与 Swift/XCUITest 侧对比（诚实对比，不单方面吹 TS）**：

- XCUITest 同样**没有查到**专门文档化的「自动化点击 `NSStatusItem` 菜单栏图标」路径——搜索未见 Apple 官方或社区给出可靠方案，这块在 Swift 侧同样是空白，不是 Electron 独有的短板。
- 但系统权限弹窗这一项上，Apple 侧有一个 Electron 没有的结构性优势：macOS 上 **XCTest 对系统权限弹窗有内建的隐式处理**——WWDC 2020 明确说明 XCTest 会自动点击「Don't Allow」类按钮防止弹窗卡住测试，需要自定义行为时还有 `addUIInterruptionMonitor()` 可挂钩。这是测试框架原生提供的能力，不需要额外白盒 hack；而 Playwright/WebdriverIO 对同类系统弹窗完全没有内建机制，需要自建 AppleScript/辅助功能脚本。[WWDC20 10220](https://developer.apple.com/videos/play/wwdc2020/10220/)、[Use Your Loaf 博客](https://useyourloaf.com/blog/handling-system-alerts-in-ui-tests/)
- 净结论：**非 DOM 面整体上两栈都弱，且都要靠白盒变通**；唯一的不对称点（系统权限弹窗的内建拦截）反而对 Swift/XCUITest 更有利。因此 ADR 0002「XCUITest 分钟级闭环」这条成本，其减分效力应限定在 **DOM 内 UI 自动化**（因为这块 Electron 确实靠 Playwright 秒级闭环碾压），而不能外推到 Tray/菜单/弹窗——那里回退到 Electron 拿不到实质收益。

---

## 2. 单元/域层：vitest 对标 swift-testing 纯包层——原样可用

`platform-framework-research.md` §9.1 的第 1 层「纯领域单元测试」思想（虚拟时钟、cron/DST、权限决策、能力注册、幂等、补偿、migration）与技术栈无关，在 vitest 上原样可执行，且 2026 现状比原调研时更成熟：

- vitest 对纯 TS、无 DOM 依赖的领域层是「理想用例」，原生 ESM/TS 支持（esbuild 转译，零配置），冷启动比 Jest 快 3.5 倍量级，新项目默认选型。
- 与 swift-testing 的对比结构一致：两者都是「宿主无关的纯逻辑层单元测试」，工具成熟度上 vitest 略占先手（生态更新频率、并行执行默认开启），但这不是 ADR 0002 成本翻转的重点——§9 的分层思想本就技术栈中立，翻不翻转都不影响这一层可用度。

---

## 3. 快照/视觉：透明悬浮窗适用性——可用但有已知盲区

- Playwright screenshot 支持 `omitBackground` 选项，可在截图中保留透明通道，理论上适配宠物悬浮窗这类透明窗口的截图基线比对；同时支持 CSS/JS 注入做遮罩，处理动态元素。
- Storybook 生态的 Loki 仍在维护，是 Storybook 场景视觉回归的可行选择（也有 Lost Pixel/Chromatic/Percy 等新选项）；但这些方案主要面向组件级/网页级截图，**对「透明置顶悬浮窗在真实桌面背景上的视觉表现」（S1 验收清单里的透明边缘、点击穿透视觉反馈）没有查到专门验证过的先例**——这类桌面合成层面的视觉正确性，截图工具能采到图，但基线比对的稳定性（不同壁纸/不同显示器缩放下截图内容会变）仍是未验证的盲区，需要 spike 才能定论，不能只凭文档推断。

---

## 4. AI 闭环：改-编-测循环的真实形变——诚实对比，非单方面结论

- **TS 侧**：无需编译等待是相对准确的直觉——tsc watch / vite HMR 是亚秒级增量反馈，类型检查可与执行并行（先跑测试，类型错误异步报），循环形状是「保存→秒级反馈→继续改」。
- **Swift 侧实证（S1 spike）**：本机 CLT/SPM 均损坏的极端环境下，AI 仍完成了自主改-编-测闭环——`swiftc` 直编（vfsoverlay 补丁绕过工具链问题）首编约 35s、**热缓存 1s**，全链路（透明、置顶、点击穿透自动命中/手动档、全空间、拖拽多显示器、睡眠恢复）用户终验通过。这是「AI 在 Swift 也能打通自主循环」的正向证据，且热缓存下的单次迭代（1s）并不比 TS 的 HMR 慢一个数量级。
- **诚实对比结论**：两栈在「稳态热编译反馈速度」上其实接近（都是亚秒到个位数秒），S1 证明 Swift 的编译等待不是 AI 自主循环的实质阻塞点——真正阻塞 S1 的是**工具链损坏**（CLT/SPM 环境问题），这是本机环境缺陷，不是 Swift 语言/生态的结构性成本，修复后（装完整 Xcode）预期这块差距会进一步收窄。因此 ADR 0002 里「AI 闭环」相关的顾虑，翻转到 Electron 后收益是真实但幅度有限的——主要体现在「不需要处理本机工具链损坏」这一具体环境问题上，而非 TS 语言本身对编译等待有结构性优势。

---

## 5. 自读兜底：具体到哪些层——恢复的是「浅层可读」，不是「全栈可独立改」

ADR 0002 原话是「彻底失去」，用户前提是「TS 有一定阅读能力」（读、写、审都依赖 AI 是 Swift 侧前提，TS 侧用户能读但未必能独立写对）。切回 Electron 恢复的自读兜底，具体到分层：

- **能读、且读了有用**：`manifest`（插件清单，JSON/YAML 结构化数据，与语言无关，Swift 侧同样能读）、**capability contract**（TS 类型定义/interface，是「文档化的形状」，比读 Swift protocol 定义门槛低——这是 TS 语法本身比 Swift 更接近用户已有阅读经验的地方，是这条成本翻转里最实的部分）。
- **能读、但读了未必能判断对错**：域逻辑（domain layer）的具体实现——业务规则的正确性判断需要理解上下文而非语法，用户「有一定阅读能力」不等于能独立发现逻辑 bug，这部分兜底价值有限，本质仍依赖 AI 诊断 + 测试覆盖，和 Swift 侧的「编译器+产物化验证+AI 诊断」模式差别没有 ADR 0002 字面暗示得那么大。
- **结论**：自读兜底翻转是真实的，但价值集中在「配置态/契约态」（manifest、类型声明）而非「实现态」（域逻辑内部）；ADR 0002 把它写成「彻底失去」在 Swift 侧、「完全恢复」在 Electron 侧的二元对立，实际是一个「兜底粒度」问题——粒度越浅（配置/类型），恢复越彻底；粒度越深（业务逻辑正确性），恢复越有限。

---

## 6. 语料密度：通用语料差距属实，Electron 专属 API 语料没有明显优势

- SO 2025 数据（Swift 5.4% vs TS 43.6% 使用率）反映的是**语言级**通用语料密度，这条差距真实存在且量级悬殊，属实。
- 但 ADR 0002 的顾虑落地到「AI 写这个产品所需的具体 API」时，通用语料密度不能直接套用：本票第 1 节核查显示，Electron **专属**的 Tray/native dialog/系统权限交互 API，其文档质量和可查资料，并不比 SwiftUI/AppKit 菜单栏场景（`NSStatusItem`/`NSPanel`/`UNUserNotificationCenter`）丰富——两边都是「主流语言 + 小众系统集成面」的组合，专属 API 语料都相对稀薄，只是稀薄的绝对量级不同（Electron 生态整体基数大，同样小众话题下沉淀的问答/博客数量仍多于 Swift 对应话题）。一句话评估：**语言级语料差距翻转成立，但 API 级差距的翻转幅度明显小于语言级数字暗示的量级**，实际收益介于两者之间，偏向语言级（因为遇到问题时 AI 也会借助通用 TS/JS 经验做类比迁移，这条路径在 Swift 侧较弱）。

---

## 参考来源

- [Playwright Electron API 文档](https://playwright.dev/docs/api/class-electron)
- [Playwright GitHub issue #39477 — Electron 支持现状问询](https://github.com/microsoft/playwright/issues/39477)
- [ray.run 社区讨论 — Electron 支持稳定性](https://ray.run/discord-forum/threads/141836-state-of-electron-support-on-playwright)
- [Electron 官方自动化测试教程](https://www.electronjs.org/docs/latest/tutorial/automated-testing)
- [wdio-electron-service（社区版，已 deprecated）README](https://github.com/webdriverio-community/wdio-electron-service/blob/main/README.md)
- [electron-tray-test — Tray 点击事件手动验证](https://github.com/todbot/electron-tray-test)
- [Playwright GitHub issue #11100 — 无法访问 context menu](https://github.com/microsoft/playwright/issues/11100)
- [electron-playwright-helpers](https://github.com/spaceagetv/electron-playwright-helpers)
- [WWDC20 10220 — Handle interruptions and alerts in UI tests](https://developer.apple.com/videos/play/wwdc2020/10220/)
- [Use Your Loaf — Handling System Alerts In UI Tests](https://useyourloaf.com/blog/handling-system-alerts-in-ui-tests/)
- [Simon Willison — Testing Electron apps with Playwright and GitHub Actions](https://til.simonwillison.net/electron/testing-electron-playwright)
- [Loki — Visual Regression Testing for Storybook](https://loki.js.org/)
- [2025 Stack Overflow Developer Survey](https://survey.stackoverflow.co/2025/)
