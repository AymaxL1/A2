# 01 — Electron 工具链最小面与「免 Xcode」的诚实边界

Type: research
Status: open

## Question

Electron 路线在这台机器上的开发→构建→分发全链,各环节到底需要什么工具?「免 Xcode」的边界画在哪里?对照项:留在 Swift 路线解除阻塞的成本清单。具体要回答:

1. **开发循环**:装哪个 Node(版本/安装方式,本机无 Homebrew 无 sudo 意愿,用户态 tarball 是否够)后,`npm install` + `electron .` 的日常循环是否完全不碰 Xcode/CLT?
2. **原生模块**:node-gyp 何时才会介入(哪些常用依赖带原生模块)、它需要的是 CLT 的 clang(本机已实测健康)还是完整 Xcode;V1 已知依赖面(Tray/UDS/子进程/通知)是否可以做到零原生模块。
3. **打包/签名/公证**:electron-builder(或 forge)在 mac 上出 .app/.dmg 各需什么;无签名身份时能走到哪一步(开发态运行、ad-hoc 签名、通知可用性);正式 Developer ID 签名+notarytool 公证需要什么(证书即可?还是必须 Xcode.app?)。
4. **对照:Swift 路线解阻塞成本**:逐项列出 Swift 路线上哪些环节真的非 Xcode.app 不可(SPM 修复、XcodeGen 的 xcodebuild、XCUITest、SDK pin、签名仪式),哪些其实 CLT 修好就行;vfsoverlay 直编法(见 `Spikes/S1PetOverlay/toolchain-workaround/`)的天花板在哪。
5. 结论表:两条路线各自的「今天就能动工吗/被什么卡/解卡动作与耗时」。

## Context

- 本机探针结论(2026-07-28,已实测):Node/npm/pnpm/Homebrew/nvm 全部未安装(白板);clang++/make 健康(CLT 只坏 Swift 头);`xcode-select -p` = CLT;codesign 可用、notarytool 1.0.0 可用、`security find-identity` 0 个签名身份;网络经本地代理 127.0.0.1:33888,registry.npmjs.org 与 github.com 均 HTTP 200。把这些事实原样收进研究文档。
- 本机 Swift 坏法详情:CLT 的 `module.modulemap`/`bridging.modulemap` 重复定义 SwiftBridging,swiftc 全挂、SPM 清单解析不了;S1/S2 靠 vfsoverlay 直编绕过(无 sudo)。
- 相关旧结论:`docs/v1-roadmap.md` Phase 0「一次性签名仪式」段(无签名 .app 在 UserNotifications 直接崩溃——Swift 侧事实,Electron 侧要独立核实)。

## Output

`docs/research/electron-recon/toolchain.md`(中文,列来源 URL 与核实日期;区分实测/官方文档/社区经验三档证据)。
