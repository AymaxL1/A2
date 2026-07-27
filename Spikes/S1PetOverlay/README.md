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
