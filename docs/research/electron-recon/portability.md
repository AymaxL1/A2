---
status: research
date: 2026-07-28
issue: .scratch/electron-recon/issues/06-portability.md
---

# 「不够通用」两种解读的事实盘点

> 本文档不裁决。用户「不够通用」的动机有两种可能所指,本文把两种解读各自的事实备齐,供 08 票(HITL 澄清)与 09 票(终裁)使用。核实日期 2026-07-28,证据来源以官方文档/官方仓库为主,社区经验单独标注。

## 解读 (a):开发环境通用性

用户诉求「不想被 Xcode 卡进度」如果指的是**开发/测试/CI 能否脱离 Xcode、脱离这台机器**,事实如下。

### 开发循环层面

- Electron 通过 npm 安装的是**预编译二进制**:`electron` 包的 postinstall 步骤会调用 `@electron/get` 按当前操作系统/架构下载对应的 Electron 预编译产物,不需要本机编译([Electron 安装文档](https://www.electronjs.org/docs/latest/tutorial/installation))。这意味着 `npm install && npm start` 这一日常循环在任何装了 Node 的机器上都成立——Linux CI、Windows、另一台没有 Xcode 的 Mac 都一样。
- V1 已知依赖面(Tray、UDS、子进程、通知)全部是 Electron/Node **内置**能力,不需要额外的原生模块([Node `net` 官方文档](https://nodejs.org/docs/latest-v18.x/api/net.html)确认 UDS/named pipe 走的是内置 `net` 模块;Tray/Notification 是 Electron 主进程内置 API)。若真的引入原生模块,node-gyp 在 macOS 上只需要 **Xcode Command Line Tools**,不需要完整 Xcode.app(`xcode-select --install` 即可,node-gyp 官方 README 原话)([node-gyp README](https://github.com/nodejs/node-gyp))。原生模块编译细节与本机 CLT 健康度核实见 01 票。
- 结论:纯域层单元测试、lint、typecheck、大部分业务逻辑构建,可以在**任意有 Node 的机器**上跑,全程不碰 Xcode。

### E2E / 打包层面(边界所在)

- **Electron 自动化测试**可以在 Linux headless CI 上跑:Electron 依赖 Chromium 需要显示驱动,但可以用 Xvfb 虚拟出一个显示环境,或者用 `xvfb-maybe` 这类工具自动处理;CircleCI 等平台甚至已经预装好 Xvfb([Electron 官方「Headless CI」文档](https://www.electronjs.org/docs/latest/tutorial/testing-on-headless-ci))。Playwright 的 Electron automation API 官方仍标注为 experimental,近期版本(Electron 36+)在部分 CI 场景下出现兼容性问题,是社区经验层面的已知坑([playwright/microsoft#2609](https://github.com/microsoft/playwright/issues/2609)、[electron/electron#47419](https://github.com/electron/electron/issues/47419))。这类测试能验证**逻辑正确性**,但验证不了 mac 专属的渲染/交互细节(托盘图标观感、通知身份、点击穿透真实手感)。
- **mac 目标打包(.app/.dmg)不能跨平台构建**:electron-builder 官方与社区一致结论是——受 Apple 限制,mac 目标只能在真实 mac 机器上构建,不存在类似 Windows/Linux 目标那样的 Docker/Wine 交叉编译路径([electron-builder mac 文档](https://www.electron.build/docs/mac/);社区确认见 [quasarframework 讨论](https://github.com/quasarframework/quasar/discussions/15435))。这一点与签名身份是否存在无关——哪怕不签名,也得在 mac 上跑 `hdiutil` 之类的工具生成 dmg。
- **签名与公证**同样是 mac 专属工具链:`codesign`、`notarytool` 官方只在 macOS 上可用;`notarytool` 是否需要完整 Xcode.app 还是 CLT 即可,由 01 票核实为准。社区有非官方的 Linux 侧公证 workaround(基于 iTMS Transporter),但不是 Apple 官方支持路径,本项目未纳入验证范围([notarization-helper 项目](https://github.com/LiamHaworth/notarization-helper))。
- **GitHub Actions macOS runner 税**:2026 年费率下,macOS runner 消耗额度倍率约为 Linux 的 10 倍(Linux 1x/\$0.006 每分钟,Windows 2x/\$0.010,macOS 10x/\$0.062),GitHub 已在 2026-01-01 起下调约 39% 价格但相对倍率结构未变([GitHub Actions 2026 定价分析](https://cicdpipelinecost.com/github-actions-pricing))。项目边界已定「macOS/Windows 真实 CI 是合并/发布门禁」,这个门禁两条路线都逃不掉;但 Electron 路线可以把 lint/typecheck/单元测试/契约测试这类高频快反馈循环下放到便宜的 Linux runner,只把 E2E 与打包放到必须的 mac runner 上,从而压低 mac runner 分钟消耗。

### 对照:Swift 路线

- Swift 官方支持 Linux 工具链,但那条线是给 server-side Swift 用的;**AppKit/SwiftUI 在 Linux 上不存在**,理论上可以把纯逻辑写成不依赖 AppKit 的 Swift package 在 Linux 编译,再导入 Xcode 连接 UI,但项目的裁决集(Tray、透明悬浮窗、点击穿透等)本就大量依赖 AppKit/SwiftUI([Swift 论坛「SwiftUI for Linux」讨论](https://forums.swift.org/t/swiftui-for-linux-and-appkit-and-nsfoundation-and-cocoa-etc/87216))。
- SPM 包解析、`xcodebuild`、XCUITest 都需要完整 Xcode.app,不是 CLT 能顶替的——这正是本机当前踩的坑(CLT 的 `module.modulemap`/`bridging.modulemap` 冲突导致 swiftc/SPM 清单解析全挂,见 01 票本机探针)。
- 换言之:Electron 路线里「可下放到任意 Node 机器」的比例(域层逻辑、CLI、注册表、大部分单元测试)远高于 Swift 路线——Swift 路线里几乎不存在一个「不需要 Xcode.app 就能跑」的开发/测试环节。

### 贡献者/换机上手成本对照

| | Electron | Swift(本项目实际形态) |
|---|---|---|
| git clone 后需要装什么 | Node(用户态 tarball/nvm,不需要 sudo/Homebrew) | Xcode.app(完整安装,非 CLT) |
| 典型下载体量 | Node 官方 tarball 数十 MB 级 | Xcode.app 数 GB 级(iOS+macOS SDK 打包在一起) |
| 首次可跑起来的动作 | `npm install && npm start` | 装完 Xcode、accept license、装齐组件,还可能要修 SPM(本机实测 CLT 有 bug) |
| 换一台新 Mac 重来一次 | 分钟级 | 十分钟到小时级,取决于网络与是否踩坑 |
| 能否在非 Mac 机器上做纯逻辑开发/CI | 可以(Linux/Windows 装 Node 即可跑 lint/test/大部分业务逻辑) | 不能(无 AppKit/SwiftUI;且本项目已裁决 Mac-only,没有在非 Mac 机器上开发的场景) |

### 结论行

**如果用户要的是「开发环境通用性」,事实支持这个诉求**:纯域层测试/lint/构建可以在任意装了 Node 的机器(含 Linux CI、无 Xcode 的另一台 Mac)上跑,完全不碰 Xcode;唯一跑不掉 mac 真机的环节是**目标为 macOS 的打包/签名/公证**,这是 Apple 的平台限制而不是语言选择的限制,Electron 也无法绕开——但比 Swift 路线「几乎每个开发/测试环节都要 Xcode.app」的门槛低得多,且 CI 里可以把大部分快速反馈循环下放到便宜的 Linux runner。

---

## 解读 (b):产品跨平台(将来上 Windows)

用户诉求如果指的是**产品将来要支持 Windows**,事实如下——本节只盘点可携带度,不建议是否要做。

### 栈无关层(不受影响)

capability contract、manifest、注册表、CLI 语义、mihomo 子进程 + REST 这些设计在原调研文档 §5/§6 中就是栈无关的,和 UI 用什么框架无关;09 票终裁时可以确认这层原样保留。

### mac 专属面逐项对照

| mac 专属面 | Windows 等价 | 事实与坑 |
|---|---|---|
| 系统代理设置(`networksetup`) | `netsh winhttp set proxy` 或改注册表 `HKEY_CURRENT_USER\...\Internet Settings` + `InternetSetOption` 广播变更 | Node 没有内置跨平台 API,两边都要 shell out 到系统命令行工具或调用 Win32 API;是对称的「各写一个 adapter」工作量,不是免费的([Microsoft WinHTTP/netsh 文档](https://learn.microsoft.com/en-us/windows/win32/winhttp/netsh-exe-commands)) |
| UDS(unix domain socket) | Windows named pipe | **本项目最大的正面事实**:Node `net` 模块官方文档明确——同一套 API(`net.createServer()`/`.listen(path)`),Unix 下建 UDS,Windows 下自动走 named pipe(路径形如 `\\.\pipe\xxx`);Windows 下 pipe 随进程退出自动清理,比 UDS 还省心(不用处理 stale socket 文件)([Node.js `net` 官方文档](https://nodejs.org/docs/latest-v18.x/api/net.html))。capability registry → `aa` CLI → UDS 这条 S2 纵切链路,理论上换个 socket 路径就能在 Windows 上原样成立,不需要重新设计协议层。 |
| Tray | Electron `Tray` | 官方内置跨平台 API,mac/Windows/Linux 都直接可用;仅图标格式建议不同(Windows 推荐 ICO)([Electron Tray 文档](https://www.electronjs.org/docs/latest/api/tray)) |
| `setIgnoreMouseEvents`(点击穿透) | 同名 API | 官方文档明确 `forward` 转发选项在 **macOS 和 Windows** 都支持(Windows 侧靠底层 mouse hook 转发 `WM_MOUSEMOVE`);但社区反馈 Windows 下 `mouseleave`/`:hover` 不够稳定,是已知 issue([Electron 窗口交互文档](https://www.electronjs.org/docs/latest/tutorial/custom-window-interactions);[electron/electron#30808](https://github.com/electron/electron/issues/30808))。基础能力有,但要专门在 Windows 真机验证,不能想当然照抄 mac 行为。 |
| 登录项 | `app.setLoginItemSettings` | 官方文档明确同时支持 macOS 和 Windows(Linux 不支持,仅 Unity launcher 特例);Windows 侧参数是可执行文件路径 + 参数,写注册表启动项,和 mac 的 launch agent/`SMAppService` 机制不同但都是一等公民官方 API,不需要自己写底层([Electron `app` API 文档](https://www.electronjs.org/docs/latest/api/app)) |
| 通知 | `Notification` | 官方内置跨平台 API,但 Windows 下有前提条件——需要在开始菜单安装带 `AppUserModelID` 的快捷方式(通常由 electron-builder + Squirrel.Windows 安装器自动处理),开发阶段需手动调用 `app.setAppUserModelId()` 才能看到通知;这正是原调研文档 §12「仍需实测」清单点名的坑([Electron 通知文档](https://www.electronjs.org/docs/latest/tutorial/notifications)) |
| 签名(Developer ID → Authenticode) | Windows 代码签名 | **本项目最大的坑**:mac Developer ID 证书目前还能「下载 p12 装到本机签」;但 Windows/Authenticode 自 2023-06-01 起,CA/Browser 论坛新规要求代码签名私钥必须存放在 FIPS 140-2 Level 2/Common Criteria EAL 4+ 认证的硬件上(USB token 或云 HSM),不能再简单导出 p12 本地签名——需要额外采购硬件 token 或云签名服务(如 Azure Trusted Signing、SSL.com eSigner、DigiCert KeyLocker)([CA/Browser Forum 2023 新规说明](https://garantir.io/new-2023-ca-browser-forum-code-signing-requirements/))。未签名或新签名的 exe 还会被 SmartScreen 拦截、需要积累下载量建立信誉。这条流程复杂度和采购成本都明显高于 mac 路线,和「要不要签名分发」这个产品决策强相关。 |

### 打包本身的现实

不止 mac 目标不能跨平台构建;每个目标平台原则上都需要对应的真机/真 OS 环境来构建和验证(Windows 目标虽然有 Wine workaround 可以在 Linux 上构建,但没有等价的 workaround 能在非 Mac 机器上构建 mac 目标)。这意味着哪怕代码栈无关,「多平台 CI matrix」这件事本身仍是真实成本,不因为选 Electron 就消失。

### 结论行

**如果用户要的是「产品未来上 Windows」,事实部分支持**:栈无关层(能力契约、manifest、注册表、CLI 语义、mihomo 子进程 + REST)本就可携带,不受影响;mac 专属面里 **UDS → named pipe 这条 Node `net` API 几乎免费打通**,是最大利好,S2 纵切的协议设计基本不用重新想;但 Tray/通知/点击穿透仍需要 Windows 真机测试与专门适配代码,不是零成本;而 **Authenticode 签名的硬件 token 要求是一项新增的、和 mac Developer ID 证书完全不同形态的采购与流程负担**,不是复制一份签名脚本就能过去。综合看,切 Electron 后「将来 Windows」从 ADR 0001 所说的「含核心全重写」,量级上降到大约「大部分栈无关层复用 + 新增一个 host-windows 适配包(对标现有 `host-electron` 拆出 Windows 专属分支)+ 独立的 Windows 签名/分发流程」——不是零工作量的「顺便就上了」,但也远不到「重写核心」的量级。留在 Swift 路线,因为 AppKit/SwiftUI 在 Windows 上没有生产级方案(ADR 0001 原文已确认),仍然维持「全重写」不变。

---

## 「切 Electron 但 V1 仍 Mac-only 交付」是自洽选项

即使切换到 Electron,V1 完全可以只交付 macOS,ADR 0001 不需要改动。两种「通用性」收益是相互独立的:

- 解读 (a) 的收益在 `npm install` 那一刻就已经全部到手——不需要真的做 Windows 产品,今天就能在任意 Node 机器上开发/测试大部分代码。
- 解读 (b) 的收益要等真正投入 Windows 适配工作(host-windows 包、签名采购流程、真机 E2E)才会兑现,是一次独立的、将来才需要做的新 effort。

因此「不想被 Xcode 卡进度」这个诉求,哪怕只按解读 (a) 处理也已经完整成立,不需要以「将来上 Windows」作为理由去动 ADR 0001。两种解读各自对应的裁决问题(是否真的要切栈、是否要连带重开 0001)留给 08/09 票。
