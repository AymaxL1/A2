# 宠物悬浮窗：Electron 对 S1（Swift NSPanel）验收项的逐条对标

> 对应票：`.scratch/electron-recon/issues/02-pet-window-parity.md`。
> 基线：以 2026-07-27 npm `electron@latest` = **43.2.0** 为当前版本口径（[npm registry dist-tags](https://registry.npmjs.org/electron)）；文中未注明版本的"当前文档"均指 [electronjs.org/docs/latest](https://www.electronjs.org/docs/latest/api/browser-window)。GitHub issue 逐条标注 open/closed 与创建/关闭时间；"closed as not planned/stale"≠已修复，仅代表维护者/机器人关闭，正文会明确区分。
> S1 验收原文见 `Spikes/S1PetOverlay/README.md`（已用户验收，2026-07-28）；引用要点：验收清单 7 项（透明、置顶、点击穿透手动档/自动命中档、全空间、拖拽+多显示器、睡眠恢复），Findings 记「结果：全部通过」，技术要点提到「30Hz 轮询 `NSEvent.mouseLocation` 做悬停命中，等价 Electron `setIgnoreMouseEvents(forward)`」——即 S1 作者本人已把这条实现锚定为 Electron 对应物。

---

## 1. 点击穿透可动态切换

**API**：`win.setIgnoreMouseEvents(ignore[, options])`，`options.forward: boolean`，当前文档标注支持平台为 **macOS + Windows**（[Electron BrowserWindow 文档](https://www.electronjs.org/docs/latest/api/browser-window)）。语义：`ignore=true` 时窗口内的鼠标事件穿透到下层窗口；`forward=true` 时鼠标移动消息仍会转发给 Chromium，使 renderer 内 `mouseenter`/`mouseleave` 等事件继续触发。

**命中区域方案**：官方 Window Customization 教程给出的标准写法是——`mouseenter` 时 IPC 通知主进程 `setIgnoreMouseEvents(true, {forward: true})`，`mouseleave` 时 `setIgnoreMouseEvents(false)`。这是**事件驱动**，不需要像 S1 那样自行轮询 `NSEvent.mouseLocation`（30Hz）；`-webkit-app-region` 是拖拽区域标记（用于第 5 项拖拽），与点击穿透命中区域是两套机制，不要混用。

**已知坑（GitHub 检索）**：
- [#27017](https://github.com/electron/electron/issues/27017) "the parameter `forward` of `setIgnoreMouseEvents` doesn't work on Mac"——2020-12-15 提出，**closed**。早期版本 forward 在 mac 完全不生效；现行文档已把 forward 标为 mac+Windows 均支持，说明此后已被修，但页面未能提取到明确的 fix PR 号/版本号，需 E1 冒烟自行复核当前 43.x 是否稳定生效。
- [#33281](https://github.com/electron/electron/issues/33281) "setIgnoreMouseEvents forwarding does not work when certain non-electron windows are in focus"——2022-03-15 提出，**closed as not planned**（带 stale 标签，非真正修复）。触发条件是非 Electron 窗口（如系统任务管理器类窗口）持有焦点，宠物场景一般不会撞上，风险低。
- [#26718](https://github.com/electron/electron/issues/26718) "Mac child browserwindow with `forward:false`, mousemove only fires when button held down"——2020-11-27，**closed as not planned**。用的是 `forward:false` 边缘情形，S1/官方推荐模式用 `forward:true`，命中概率低。
- [#30808](https://github.com/electron/electron/issues/30808) "Mouse event forwarding is buggy"——2021-09-02，**仍 open**，但标签显示为 **Windows 平台专属**（hover/`mouseleave` 不稳定），与本项目 mac-only 无关；只作为侧面证据：该功能在 Windows 侧 5 年未修，维护优先级不高。

**结论**：mac 上 `forward:true` 目前文档层面被正式支持，检索到的坑多为老、已标记 not planned/stale，或是 Windows 专属；未查到 2024 年以后的 mac 专属高优先级 bug。判定：**达标，但仍需 E1 专项冒烟复核**（尤其是命中区域切换的响应延迟/丢帧）。

---

## 2. 置顶稳定

**API**：`win.setAlwaysOnTop(flag[, level][, relativeLevel])`。`level` 字符串 → `NSWindow` 层级的映射（源码级确认，见 `shell/browser/native_window_mac.mm`，[GitHub](https://github.com/electron/electron/blob/main/shell/browser/native_window_mac.mm)）：

| level 字符串 | NSWindow 常量 |
|---|---|
| floating | NSFloatingWindowLevel |
| torn-off-menu | NSTornOffMenuWindowLevel |
| modal-panel | NSModalPanelWindowLevel |
| main-menu | NSMainMenuWindowLevel |
| status | NSStatusWindowLevel |
| pop-up-menu | NSPopUpMenuWindowLevel |
| screen-saver | NSScreenSaverWindowLevel |

`relativeLevel`（仅 mac）在给定 level 基础上做层内偏移；文档原文提示 Apple 不建议设到比 `screen-saver` 再高超过 1 层。这与 S1 直接操作 `NSWindow.level` 是**同一枚举族**的封装，无信息丢失——第 2 项本身的"映射关系"达标。

**已知坑（与第 3 项是同一坑的两面）**：
- [#37865](https://github.com/electron/electron/issues/37865) "Window Always on top is not working when any other app is on full screen"——2023-04-06，**closed as not planned**，mac（M1 Pro）专属，用了 `setVisibleOnAllWorkspaces(true,{visibleOnFullScreen:true})` + `setAlwaysOnTop(true,'floating',MAX_VALUE)` 组合仍失效。
- [#36364](https://github.com/electron/electron/issues/36364) "setAlwaysOnTop + setVisibleOnAllWorkspaces + visibleOnFullScreen not working unless the window is manually focused by user"——2022-11-15，**closed as not planned**（stale），mac 12.6.1 arm64，报告"必须手动 focus 一次才生效"。
- [#10078](https://github.com/electron/electron/issues/10078) "alwaysOnTop over other fullscreen apps"——2017-07-21，**closed，标签 wontfix**。

三条报告横跨 2017/2022/2023 三个年份，都是同一件事——`alwaysOnTop` 单独无法压过全屏 App 的 Space，必须配合 `setVisibleOnAllWorkspaces`，即便配合了也有"需手动 focus 才生效"的历史投诉，且均以 wontfix/not planned 关闭（不是修复关闭）。**这是本票检索到的最大风险点**，判定：**有坑**，需要在 E1 之外做真机人工反复验证（见清单）。

---

## 3. 全空间与全屏辅助

**源码实锤**（`NativeWindowMac::SetVisibleOnAllWorkspaces`，[raw 源码](https://github.com/electron/electron/blob/main/shell/browser/native_window_mac.mm)）：

```cpp
void NativeWindowMac::SetVisibleOnAllWorkspaces(bool visible,
                                                bool visibleOnFullScreen,
                                                bool skipTransformProcessType) {
  if (!skipTransformProcessType) {
    if (visibleOnFullScreen) {
      Browser::Get()->DockHide();
    } else {
      Browser::Get()->DockShow(JavascriptEnvironment::GetIsolate());
    }
  }
  SetCollectionBehavior(visible, NSWindowCollectionBehaviorCanJoinAllSpaces);
  SetCollectionBehavior(visibleOnFullScreen, NSWindowCollectionBehaviorFullScreenAuxiliary);
}
```

只设置了 **`CanJoinAllSpaces`** 与 **`FullScreenAuxiliary`** 两位。**不设置 `NSWindowCollectionBehaviorStationary` / `IgnoresCycle`**——这两位只在 Electron 内部特殊 `windowType:"desktop"`（桌面壁纸类窗口）分支才会设置，普通 `BrowserWindow` 没有暴露通用 `setCollectionBehavior` API 拿到它们。

→ **对比 S1 的确认能力缺口**：S1 README 明确写的是 `canJoinAllSpaces + fullScreenAuxiliary + stationary`。Electron 的 JS 层 API 缺 `stationary` 等价物。`stationary` 的作用是"窗口在 Space 切换动画中保持画面位置、不参与窗口循环排序"，对宠物窗观感的实际影响未知（`canJoinAllSpaces` 本身已能让窗口常驻），需 E1/真机切 Space 时目测是否有可感知的位置抖动。

**副作用**：`visibleOnFullScreen:true` 分支会隐式调用 `app.dock.hide()`（进程类型转 `UIElementApplication`），除非同时传 `skipTransformProcessType:true`（该选项由 [PR #27200](https://github.com/electron/electron/pull/27200) 于 2021-02-02 合入 master，页面未能确认首发的具体正式版本号，需 E1 在当前 43.x 上直接验证其存在与效果）。对应踩坑记录：[#26350](https://github.com/electron/electron/issues/26350) "setVisibleOnAllWorkspaces visibleOnFullScreen 导致 dock 图标消失"——2020-11-05 提出，**至今仍 open**，本质是源码故意为之的设计行为（不传 `skipTransformProcessType` 就会撞上），不是随机 bug，但是一个必须知道的隐式副作用。

**结论**：核心可用（能拿到 canJoinAllSpaces + fullScreenAuxiliary），但相对 S1 有一处明确的 API 表面缺口（无 `stationary` 等价物）+ 一处需要正确传参才能规避的副作用（dock 图标消失）。判定：**有坑/小缺口**。

---

## 4. 透明 + 无边框窗

官方当前文档（`BaseWindowConstructorOptions`，[结构文档](https://www.electronjs.org/docs/latest/api/structures/base-window-options)）：

- `transparent: boolean`，默认 `false`；"on Windows this does not work unless the window is frameless"（mac 无此前置限制）。
- `hasShadow: boolean`，默认 `true`；**文档原文明示："on Mac the native window shadow will not be shown on a transparent window"**——即 mac 上一旦 `transparent:true`，系统阴影必然消失，这是**文档化的固定行为**，不是 bug。宠物贴图若本身不依赖系统阴影问题不大，但比 S1（NSHostingView，阴影可独立控制）少一层可调性，需人工过目验收。
- `roundedCorners: boolean`，默认 `true`，文档只明确说明对 Windows（<11 22000 无效）与 Linux（依赖桌面环境 CSD）的影响，**未见 mac 专属说明**。

**已知坑**：
- [#47833](https://github.com/electron/electron/issues/47833) "Unable to customize window border radius"——**2025-07-20 提出**，mac Tahoe 26.0 + Electron 37.2.3，**closed as not planned**。报告：无论 `transparent` 开关或 `setBorderRadius` 调用如何，无边框窗口背景始终带约 14px 系统圆角。这是**近一年内**的报告，证明"transparent+frame:false 在 mac 合成器细节上不理想"不是历史遗留已根治的问题，而是持续性弱点。
- 更老的同类报告：[#1603](https://github.com/electron/electron/issues/1603)（2015-05-07，OSX transparent+frameless 圆角，closed）、[#24952](https://github.com/electron/electron/issues/24952)（无阴影相关讨论）、[#7448](https://github.com/electron/electron/issues/7448)（frameless 透明窗获得焦点后画出系统阴影，closed）、[#8847](https://github.com/electron/electron/issues/8847)（transparent 窗口动画后留下半透明残影，closed）、[#14304](https://github.com/electron/electron/issues/14304)（transparent 窗口阴影更新滞后，closed）、[#21173](https://github.com/electron/electron/issues/21173)（transparent+frameless 窗口内容变化时阴影异常，closed）、[#32450](https://github.com/electron/electron/issues/32450)（mac transparent 窗口字体阴影残留，closed）——十年跨度内反复出现同一类"合成器细节"投诉，多数 closed，但结合 #47833（2025）看，**类型没有断根，只是个例常年零星出现**。
- resize 相关的一批 2025 年新问题（[#48593](https://github.com/electron/electron/issues/48593)、[#48421](https://github.com/electron/electron/issues/48421)、[#49173](https://github.com/electron/electron/issues/49173)，及修复 [PR #50301](https://github.com/electron/electron/pull/50301)/[#51175](https://github.com/electron/electron/pull/51175)）**全部是 Windows 平台**（layered window 与 `WS_THICKFRAME` 冲突），与 mac 无关，不计入本项目风险，但佐证 transparent+frame:false 组合在 Electron 里始终是跨版本要回归测试的脆弱角落。

**结论**：mac 上核心可用性没问题（能建窗、能透明），但有一条文档化的观感差异（系统阴影必然消失）+ 一条 2025 年仍未解决的圆角残留 issue（#47833，closed not planned）。判定：**有坑（观感细节级，非阻断）**，E1 冒烟需裸眼截图检查边缘。

---

## 5. 多显示器拖拽 与 睡眠恢复

**多显示器拖拽**：
- [#31058](https://github.com/electron/electron/issues/31058) "Inconsistent window dragging behavior between BrowserWindow / BrowserView"——2021-09-22，**closed**。核心结论：用 `-webkit-app-region: drag` 做拖拽依赖 Chromium 原生拖拽实现，跨屏拖拽**没有半透明预览、窗口是"跳变"过去而不是跟手移动**；未聚焦窗口点击可拖拽区域只激活不移动；拖拽中光标离开可拖拽区域会卡顿。这是 Chromium 拖拽实现的固有行为差异，不是随机 bug——S1（NSPanel 手写 `mouseDragged`）大概率是跟手的原生手感，Electron 默认拖拽在跨屏场景观感更弱。
- 其余多显示器系列（[#9560](https://github.com/electron/electron/issues/9560)、[#20633](https://github.com/electron/electron/issues/20633)、[#17933](https://github.com/electron/electron/issues/17933)、[#10862](https://github.com/electron/electron/issues/10862)、[#31999](https://github.com/electron/electron/issues/31999)）绝大多数是"不同 DPI/缩放下初始定位计算错误"，场景集中在 Windows 混合缩放多屏，mac Retina 环境命中率较低，但提示：**跨 DPI 显示器边界的拖拽落点**要重点冒烟。

**睡眠恢复**：未查到"窗口从睡眠恢复后位置/层级丢失"的 mac 专属近期高活跃 issue。[#24135](https://github.com/electron/electron/issues/24135)"OSX sleep/wakeup 崩溃"较老且非本项目场景（多显示器崩溃）；[#12706](https://github.com/electron/electron/issues/12706)"Detecting 'Put display to sleep' on macOS"——2018-04-24，**closed**，enhancement 性质（`powerMonitor` 事件扩展需求，非 bug）。整体上没有查到 mac 睡眠恢复的结构性坑，但也缺乏近期第三方复现报告可以"打包票"说没问题。

**结论**：拖拽是**行为差异**（能拖但不跟手，跨屏跳变），判定**有坑**；睡眠恢复判定**证据不足以下结论**，只能列为真机人工验收项。

---

## 6. E1 冒烟清单 / 只能真机人工验收项 / 能力缺口对照表

### E1 冒烟应验证项（可脚本化断言或半自动化观察）

1. `transparent:true, frame:false` 窗口能建立、能收发 IPC、进程不崩溃，记录实际 `electron --version`（基线 43.2.0）。
2. `setIgnoreMouseEvents(true,{forward:true})` 开启后：底层点击可穿透；`mouseenter`/`mouseleave` 仍能在 renderer 内触发（验证 forward 事件转发生效，对应 #27017 历史坑是否复现）。
3. `setAlwaysOnTop(true,'screen-saver')` 后，用第二个探测窗口对比层级，确认高于普通窗口。
4. `setVisibleOnAllWorkspaces(true,{visibleOnFullScreen:true, skipTransformProcessType:true})` 调用后检查 dock 图标是否保留（验证 `skipTransformProcessType` 是否按预期工作，对应 #26350）。
5. 裸眼截图检查窗口边缘：是否有系统阴影残留（预期没有，符合文档）、是否有 ~14px 圆角背景色块残留（对应 #47833）。
6. `-webkit-app-region:drag` 拖拽在单屏内的基本可用性（跟手性、松手位置准确度）。

### 只能真机人工验收项（CI/脚本难以断言，需要真实多屏/真实 Space/真实睡眠）

1. 全空间稳定性：真实切换 Space、进入他人全屏 App 时宠物窗是否维持置顶、是否需要"先手动 focus 一次"才生效（对应 #37865/#36364，本票最大风险点，必须反复验证而非信任单次成功）。
2. 多显示器拖拽：真实拖拽宠物窗跨越不同分辨率/缩放的两块屏，观察是否跳变、落点是否准确（对应 #31058 与 DPI 系列 issue）。
3. 睡眠恢复：合盖/唤醒后位置、层级、点击穿透状态是否保持（社区证据稀薄，必须真机独立验证，不能类比 Windows/Linux 报告）。
4. Space 切换时是否有可感知的位置抖动/闪烁（对应 Electron 未设置 `NSWindowCollectionBehaviorStationary` 的 API 缺口，纯目测，无法脚本断言）。

### 能力缺口对照表（S1 → Electron）

| S1 验收项 | S1 实现方式 | Electron 对应 API | 对标结论 |
|---|---|---|---|
| 点击穿透可动态切换 | 30Hz 轮询 `NSEvent.mouseLocation` 命中，无需辅助功能权限 | `setIgnoreMouseEvents(forward)` + `mouseenter`/`mouseleave` 原生事件驱动 | **达标**，且实现更省事（事件驱动 vs 轮询）；已知坑均老/低优先级或 Windows 专属 |
| 置顶三档（floating/statusBar/screenSaver） | 直接操作 `NSWindow.level` | `setAlwaysOnTop(flag, level)`，同一 `NSWindow.Level` 枚举族 1:1 映射（源码确认） | **达标**（纯映射关系层面） |
| 与全屏 App 抢层级稳定性 | S1 已用户验收通过 | `alwaysOnTop` + `visibleOnFullScreen` 组合，2017/2022/2023 三个年份反复报告"需手动 focus 才生效"，均 wontfix/not planned 关闭 | **最大风险点/有坑**——非一次性 bug，是跨年份重现的同一限制 |
| 全空间 + 全屏辅助 | `collectionBehavior = canJoinAllSpaces + fullScreenAuxiliary + stationary` | `setVisibleOnAllWorkspaces` 只设前两位，无 `stationary` 等价 API；`visibleOnFullScreen:true` 隐式隐藏 dock 图标（需 `skipTransformProcessType` 规避） | **有坑/小缺口**——核心可用，精细行为位缺失+隐式副作用需正确传参 |
| 透明干净边缘 | `NSHostingView` 原生渲染，阴影/圆角可独立控制 | `transparent:true` 保证无系统阴影（文档明示）；无边框窗口有 ~14px 圆角背景残留（#47833，2025 年仍未解决） | **有坑**——观感细节级，非阻断，需人工验收 |
| 拖拽 + 多显示器 | `NSWindow` 原生 `mouseDragged`，跟手 | `-webkit-app-region:drag` 依赖 Chromium 原生拖拽，跨屏是跳变非跟手（#31058） | **有坑**——体验差异而非功能缺失 |
| 睡眠恢复 | 已人工验收通过 | 无已知结构性坑，但社区证据稀薄 | **待真机验证**——现有资料不足以下结论 |

---

## 附：检索方法说明

- Electron 官方文档：`electronjs.org/docs/latest`（BrowserWindow / BaseWindowConstructorOptions 页）+ `github.com/electron/electron` 的 `docs/api/browser-window.md`（main 分支源）+ `shell/browser/native_window_mac.mm`（源码级核实 collectionBehavior 与 level 映射，避免只信文档转述）。
- GitHub issue 检索：均在 `electron/electron` 仓库内按关键词搜索并逐条打开确认状态/日期/标签；凡引用均已标注 open/closed 与创建日期，closed 的进一步区分"real fix"与"not planned/stale/wontfix"（后者不代表问题已解决，只代表维护者停止跟踪）。
- 版本基线：2026-07-27 从 `registry.npmjs.org/electron` 的 `dist-tags.latest` 读取，为 **43.2.0**。
