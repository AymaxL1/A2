# S1 宠物悬浮窗 spike（PROTOTYPE — 抛弃式，不进产品代码）

> 回答的问题（`docs/v1-roadmap.md` Phase 0 / S1）：**NSPanel + NSHostingView 能否达到 Electron 宠物窗的行为水平？** 同时兼任「AI 自主改-编-测循环」的首个实证（回退硬门①②）。
>
> 本仓库无 git：spike 以本目录本体留档；验证结论写进下方「Findings」，定稿后由新效fort的票引用。

## 运行

```bash
cd Spikes/S1PetOverlay && ./run.sh
```

（`swift run` 在本机暂不可用——SPM 坏，见下方环境发现；`run.sh` 用 swiftc 直编并带 `-vfsoverlay` 工具链补丁。）

出现：桌面上一只置顶透明宠物（🐈）+ 一个控制面板窗 + 菜单栏 🐾 图标（找回控制面板/退出）。所有状态变化同时打印到终端（surface the state）。

## 验收清单（对照 S1 通过判据，手动逐项勾）

- [ ] **透明**：宠物四周无白底/黑底，边缘干净
- [ ] **置顶**：floating / statusBar / screenSaver 三档切换，普通窗口盖不住它
- [ ] **点击穿透（手动档）**：开启后点宠物穿到桌面/下层窗口；关闭后点宠物有反应（跳一下）
- [ ] **点击穿透（自动命中档）**：光标悬停在宠物身上时可点可拖，移开即穿透——Electron `setIgnoreMouseEvents(forward)` 的等价物
- [ ] **全空间**：切 Space、进别人的全屏 app，宠物仍在（canJoinAllSpaces + fullScreenAuxiliary + stationary）；关掉开关对比默认行为
- [ ] **拖拽 + 多显示器**：按住宠物拖到另一块屏
- [ ] **睡眠恢复**：合盖唤醒后宠物还在原位、行为正常（终端会打印 wake 事件）

## Findings（验证后填写）

- 结论：**通过——用户终验通过（2026-07-28）**。初验（02:12）：链路通。VFS overlay 补丁后 swiftc 直编通过（首编约 35s，热缓存 1s）；应用常驻运行；WindowServer 侧证实两窗在屏（宠物窗 layer=3=floating ✓、控制台 layer=0）。运行日志（`02:12:04–02:12:35` 段）显示实际交互全部如预期响应：悬停自动命中↔穿透切换、三档层级循环、全空间开关、拖拽移位（多次坐标变化）、连点 emote 11 次、快速点击与拖拽正确区分。
- 技术要点：顶层代码非 MainActor 上下文 → 必须 `@main @MainActor struct` 入口；stdout 重定向时块缓冲 → 日志 print 后必须 `fflush(stdout)`；30Hz 轮询 `NSEvent.mouseLocation` 做悬停命中无需辅助功能权限，等价 Electron `setIgnoreMouseEvents(forward)`。
- 与 Electron 参照的差距：暂未发现（待用户完成全空间/全屏辅助、多显示器、睡眠恢复三项人工核验后定论）。
- 人工核验项（透明边缘、全空间/全屏存留、跨显示器拖拽、睡眠恢复）：随用户终验一并通过（2026-07-28）。

### 2026-07-28 环境发现（spike 附带产出）

本机（macOS 15.7.4 / Swift 6.0.3）的 Command Line Tools **安装损坏**，两处独立证据：

1. `/Library/Developer/CommandLineTools/usr/include/swift/` 同时存在 `module.modulemap` 与 `bridging.modulemap`，重复定义 `SwiftBridging` → 任何 `import AppKit/SwiftUI` 的编译直接失败（纯 Swift 无 import 正常）。已知 CLT 升级残留问题。
2. `ManifestAPI/libPackageDescription.dylib` 导出符号为空 → `swift build`（SPM）解析清单失败。

且本机未装 Xcode.app（`xcodebuild` 不可用）。修复选项（均需管理员）：
- **微创**（当场解锁 `run.sh`，可逆）：`sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap{,.bak}`（保留 bridging.modulemap 那份）。SPM 仍坏。
- **根治 + Phase 0 刚需**：装完整 Xcode（App Store）→ `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` → 首次启动装组件。`swift run`/`xcodebuild`/XCUITest 全部就位。
- 或重装 CLT：`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`。

### 2026-08-04 结局（上面那段是历史记录，以下为最终处置）

**上文第 1 条已修复，第 2 条的描述有误、且仍未修复。逐条结账：**

- **重复 modulemap（第 1 条）—— 已修。** 用户执行了「微创」那条：`sudo mv .../module.modulemap .../module.modulemap.disabled`。修后实测裸 `swiftc` 零旗标编译并运行成功。**vfsoverlay 就此退役**：`Scripts/check/bootstrap.sh` 改为开跑时现场探测工具链，裸编过即走 `clean` 模式，不再传该旗标；本目录 `toolchain-workaround/` 保留为**历史归档 + 回落分支**（万一在 CLT 仍坏的机器上跑，探测器会自动回落用它）。
- **SPM（第 2 条）—— 当天稍晚也已解决，且当年的描述不准。** 当年记的是「导出符号为空」；2026-08-04 复测为 **880 个 PackageDescription 符号，但零个 `Package.__allocating_init`**，即 CLT 那份 dylib 与 `PackageDescription.swiftmodule` 接口错配，不是空库（tools-version 6.0/6.1/5.9 全部 `Invalid manifest` + `Undefined symbols`）。**修法不需要 Xcode、也不需要 sudo**：装官方独立工具链到家目录 —— `installer -pkg swift-6.1.2-RELEASE-osx.pkg -target CurrentUserHomeDirectory`，落在 `~/Library/Developer/Toolchains/swift-6.1.2-RELEASE.xctoolchain`。用它跑本仓库真实 `Package.swift`：112 步 `Build complete!`，0 error 0 warning。详见 11 票。
- **「根治需装 Xcode」这个判断已被推翻。** 2026-08-04 实测：`swiftc` 编 AppKit → 手工组 `.app`（Info.plist + Contents/MacOS）→ `codesign -s -` ad-hoc 签名 → `NSStatusItem` 菜单栏项装上 → `open` 正常启动，**全程无 Xcode**。造 `.app` 不需要 `.xcodeproj`/`xcodebuild`。修 SPM 也不需要 Xcode（可装官方独立工具链到家目录，`installer -target CurrentUserHomeDirectory`，无需 sudo）。
- **⚠️ 上面最后那条「`sudo rm -rf` CLT 再 `xcode-select --install`」不要执行。** `/usr/bin/` 下的 `git`/`clang`/`swift`/`make` 等 **78 个命令是同一个 118KB 存根的硬链接**，真身全在 CLT 里；删掉 CLT 会让 `git` 当场失效，而本仓库无远端、全部历史只在本地 `.git`。要重装请走覆盖安装（developer.apple.com 下 dmg 装到现有安装上；`xcode-select --install` 在已装时只会说 already installed）。
