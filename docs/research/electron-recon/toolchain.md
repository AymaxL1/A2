# Electron 工具链最小面与「免 Xcode」的诚实边界

> 对应票：[`.scratch/electron-recon/issues/01-toolchain-xcode-free.md`](../../../.scratch/electron-recon/issues/01-toolchain-xcode-free.md)。
> 证据档位三档：**本机实测**（本机探针 / E1 spike 实测数据）> **官方文档**（nodejs.org、electronjs.org、electron.build、developer.apple.com、github.com/nodejs 官方仓库一手内容）> **社区经验**（GitHub issue 讨论、第三方博客，标注置信度）。核实日期：除特别标注外，均为 **2026-07-28**。
> 本机探针基线（直接采信，见票 Context）：Node/npm/pnpm/Homebrew/nvm 全部未装（白板）；`clang++`/`make` 健康；`xcode-select -p` = CLT；`codesign`、`notarytool 1.0.0` 可用；`security find-identity` 0 个签名身份；网络经本地代理 `127.0.0.1:33888`，`registry.npmjs.org`/`github.com` 均 HTTP 200；CLT 自带 `/usr/bin/python3` = **3.9.6**（已 EOL，见 §2）；本机未装 Xcode.app。

## 一句话结论

**Electron 路线的开发→打包→签名→公证全链，在本机现状下不需要 Xcode.app；node-gyp 只在触发原生模块编译时才需要 CLT（已健康），V1 已知依赖面（Tray/UDS/子进程/通知）可零原生模块。Swift 路线里 `xcodebuild`（含 XcodeGen 产物）/XCUITest/SPM 清单解析三项官方证实非完整 Xcode.app 不可，vfsoverlay workaround 只解锁裸 swiftc 单文件直编，够不到这三项；签名+公证环节两条路线成本相同（CLT 即可，Apple 官方证实不需要 Xcode.app）。** 今晚 E1 冒烟 spike 已用真机数据把开发循环这条结论坐实（见 §1.4）。

> ### 勘误 2026-08-04 —— 上面这段关于 Swift 路线的推论已被本机实测部分推翻
>
> **仍然成立的**：`xcodebuild`（含 XcodeGen 产物）、XCUITest、SPM 清单解析三项，确实非完整 Xcode.app 不可（本机复测：`xcodebuild -version` 仍报 `requires Xcode`）。
>
> **不再成立的**：由此推出的「Swift 正式架构必须装完整 Xcode.app」。**造 `.app` 根本不需要 `xcodebuild`。** 2026-08-04 在本机从零跑通：`swiftc` 编 AppKit → 手工组 bundle（`Info.plist` + `Contents/MacOS/`）→ `codesign -s -` ad-hoc 签名（`valid on disk` + `satisfies its Designated Requirement`）→ `NSStatusItem` 菜单栏项装上 → `open` 走 LaunchServices 正常启动、正常退出。整条链零 Xcode。
>
> **另两处需要更新的事实**：
> 1. 「vfsoverlay workaround 只解锁裸 swiftc 单文件直编」——低估了。它支撑的门禁已实跑到 **PASS=403 FAIL=0**，覆盖 9 个 target 的拓扑序编译 + 全套 E2E。且 2026-08-04 起本机 CLT 的重复 modulemap 已由 `sudo mv` 根治，overlay 退役，门禁改为自动探测工具链。
> 2. SPM 坏的成因当年记作「`libPackageDescription.dylib` 空导出符号」——复测为 **880 个符号但零个 `Package.__allocating_init`**，是 dylib 与 `.swiftmodule` 接口错配，不是空库。**当天稍晚已修好，同样没用 Xcode、也没用 sudo**：装官方独立工具链到家目录（`installer -pkg swift-6.1.2-RELEASE-osx.pkg -target CurrentUserHomeDirectory`）。用它跑本仓库真实 `Package.swift`：112 步 `Build complete!`，0 error 0 warning，含 AppKit 的 `AAHostMacOS`。**至此「Swift 路线必须装 Xcode.app」这一判断的最后一条支柱（SPM 清单解析）也已倒掉** —— 三项里只剩 `xcodebuild` 与 XCUITest 仍需 Xcode，而这两项本项目都不必用。
>
> 本勘误**不动**已终裁的 Electron/Swift 路线选择（裁决见 `.scratch/electron-recon/issues/09-final-ruling.md`，不翻案）；只修正「Xcode 是 Swift 路线硬前置」这一条事实判断，因为它此后一直被当作票 11–16 的阻塞理由。

---

## 1. 开发循环：Node 安装 + `npm install` + `electron .`

### 1.1 Node.js 版本与用户态 tarball 安装

**【结论】** 截至 2026-07-28，Node.js 当前 Active LTS 是 **v24「Krypton」**，最新补丁 **v24.18.0**（2026-06-23 发布）。官方分发服务器为 macOS 提供 `darwin-arm64`/`darwin-x64` 的 `.tar.gz`/`.tar.xz` 预编译归档，解压后手动加 `PATH` 即可用——不需要 sudo、不需要 Homebrew、不需要任何包管理器。「解压改 PATH」这个操作步骤本身没有对应的官方教程页（是通用 Unix 常识），但归档文件是官方一手资源。
**【证据档位】官方文档**（+ 本机实测复核，见 §1.4）
**【来源】** https://nodejs.org/dist/v24.18.0/ （目录索引，可见 4 个归档文件）；https://nodejs.org/dist/index.json （官方发布元数据，`"lts":"Krypton"` 字段）；https://nodejs.org/en/download

### 1.2 `npm install electron` 是否触碰 Xcode/CLT

**【结论】** `electron` npm 包的 postinstall（`npm/install.js`）调用 `@electron/get` 从 GitHub Releases 下载对应平台预编译二进制并解压到 `node_modules/electron/dist`，**纯下载+解压，不编译**，不需要 C/C++ 编译器，不需要 Xcode/CLT。典型脚手架其余依赖（`typescript`/`eslint`/`vite`，含 vite 依赖的 `esbuild`）同样是纯 JS 包或"预编译原生可执行文件按平台下载"模式（esbuild 官方文档明确：自行编译需要 Go 编译器且"not recommended"，默认走预编译二进制），同样不碰编译器。
**【证据档位】官方文档**
**【来源】** https://www.electronjs.org/docs/latest/tutorial/installation （"the `electron` module will call out to `@electron/get` to download prebuilt binaries"）；https://github.com/electron/electron/blob/main/npm/install.js；https://esbuild.github.io/getting-started/#other-ways-to-install

### 1.3 Electron 当前版本口径

**【结论】** npm registry 直接查询 `dist-tags`：`electron@latest = 43.2.0`（2026-07-21 发布）；同日也发了 `42.7.1`（42.x 支持线的补丁版），两者相差约 30 分钟发布——即 Electron 同时维护多条 major 支持线，`latest` 是 43.2.0。electron-builder：`npm dist-tags latest = 26.15.3`（发布于 2026-06-09；GitHub 上能看到更新的 `26.15.6/26.15.7` 与 `27.0.0-alpha` 系列，但 npm `latest` 稳定 tag 仍是 26.15.3，`27.0.0` 尚在 alpha 未转正）。
**【证据档位】本机实测**（直接 `curl registry.npmjs.org` 核实，见下方命令与返回）
**【来源】** `curl https://registry.npmjs.org/electron`（`dist-tags.latest=43.2.0`，`time["43.2.0"]=2026-07-21T18:51:06.112Z`）；`curl https://registry.npmjs.org/electron-builder`（`dist-tags.latest=26.15.3`，`time=2026-06-09T17:34:36.991Z`）

### 1.4 本机实证：E1 冒烟 spike（今晚新增，最高证据档位）

**【结论】** `Spikes/E1ElectronSmoke/` 今晚在本机白板环境（无 Node/npm/Homebrew）实测了完整开发循环：用户态装 **Node v24.18.0**（下载 50s + 解压 <1s ≈ **51s**，经本地代理 `127.0.0.1:33888` 一次成功）→ `npm install electron`（**20s**，落地 `electron 33.4.11`，Chromium 130.0.6723.191）→ 悬浮窗冒烟（E1a：透明穿透窗，自检 JSON 全部符合预期，`capturePage()` 截图验证角像素透明）→ UDS 冒烟（E1b：`node:net` 起 Unix socket，外部真实 `node` 子进程往返 **33ms**，全通）。**全程 `clang`/`xcodebuild`/`swiftc` 一次都没被调用，未触碰 sudo/Homebrew/CLT/Xcode**。`Electron.app` 本身是 ad-hoc 签名（`codesign -dv` 显示 `flags=0x20002(adhoc,linker-signed)`）、无 quarantine 属性，启动无 Gatekeeper 弹窗、无需用户确认。纯安装类操作合计 **约 71 秒**（Node 51s + Electron 20s）。
**【证据档位】本机实测**（今晚新增，最高证据档位——直接盖过下方对同一问题的文档层面推断）
**【来源】** `Spikes/E1ElectronSmoke/README.md`（含 run.log、selfcheck-result.json、debug.log、e1a-capture.png 等产物）

**附带发现（对 04 票内存预算相关，非本票直接问题但一并记录）**：单窗口+单 UDS server 场景，Electron 主进程+3 个 Helper 进程合计常驻 RSS 约 **287MB**（`ps -axo pid,rss,comm` 实测）。另有一个未 100% 坐实的现象——**首次执行全新下载的二进制**耗时异常拉长（33s vs 之后重跑 3-5s），怀疑与 Gatekeeper/AMFI 对未执行过二进制的首次签名校验有关，但日志未能完全证实；若产品侧有硬超时红线，建议用进程外看门狗而非同进程 `setTimeout` 兜底（细节见 E1 README「坑 3」）。

### 小结：开发循环是否完全不碰 Xcode/CLT

**是，本机实测 + 官方文档双重确认。** 今天在本机可以立即动工，且已经动工验证通过。

---

## 2. 原生模块边界：node-gyp 何时介入

### 2.1 node-gyp 官方系统需求

**【结论】** `github.com/nodejs/node-gyp` 现行 README「On macOS」小节原文：

> * A supported version of Python
> * `Xcode Command Line Tools` which will install `clang`, `clang++`, and `make`.
>   * Install the `Xcode Command Line Tools` standalone by running `xcode-select --install`. -- OR --
>   * Alternatively, if you already have the full Xcode installed, you can install the Command Line Tools under the menu...

即**官方明确 CLT 就够，完整 Xcode.app 只是"如果你已经装了也能从里面提取 CLT"的备选说法，不是必需项**。本机 CLT 已装、`clang++`/`make` 健康，**完全满足官方声明的系统依赖**。
**【证据档位】官方文档**
**【来源】** https://github.com/nodejs/node-gyp/blob/main/README.md

### 2.2 Python 版本要求与本机现状（唯一需要留意的点）

**【结论】** README 用 Important 提示框写明：`Python >= v3.12 requires node-gyp >= v10`，且要求"a supported version of Python"（链接 Python 官方 devguide 的当前支持状态页动态定义）。核实 Python 官方 devguide（2026-07-28）：**3.9 及更早已 EOL，当前最低"受支持"版本是 3.10**。本机 CLT 自带的 `/usr/bin/python3` 版本为 **3.9.6（已 EOL）**——如果未来确实触发 node-gyp 编译，这条 Python 依赖**不满足**官方"supported"要求，需要额外用户态装一个非 EOL 的 Python 3.x（如从 python.org 下载 macOS installer 或用 pyenv 之类的用户态方案；不需要 sudo、不需要 Xcode.app，属于低成本解阻塞项，但目前是**潜在**阻塞点，不是当前阻塞点，见 §2.3）。
**【证据档位】官方文档**
**【来源】** https://github.com/nodejs/node-gyp/blob/main/README.md；https://devguide.python.org/versions/

### 2.3 V1 已知依赖面（Tray/UDS/子进程/通知）是否可做到零原生模块

| 能力 | 结论 | 证据档位 | 来源 |
|---|---|---|---|
| 系统托盘 Tray | Electron **内置** `Tray` API，主进程模块，不需要额外 npm 包、不涉及 node-gyp | 官方文档 | https://www.electronjs.org/docs/latest/api/tray |
| Unix Domain Socket | Node.js **内置** `net` 模块原生支持 UDS（`net.createServer({path})`），不需要第三方原生模块 | 官方文档 + 本机实测（E1b，33ms 往返） | https://nodejs.org/api/net.html；`Spikes/E1ElectronSmoke/README.md` §4 |
| 子进程管理 | Node.js **内置** `child_process` 模块（`spawn`/`exec`/`fork`）足够，标准库自带 | 官方文档 + 本机实测（E1b 用 `child_process.spawn` 拉起外部 node） | https://nodejs.org/api/child_process.html |
| 系统通知（内置） | Electron **内置** `Notification` API，不需要额外包（可用性细节见 §3.5） | 官方文档 | https://www.electronjs.org/docs/latest/api/notification |
| 系统通知（第三方 node-notifier，备选） | 纯 JS 包装器，macOS 上靠**随包分发的预编译** `terminal-notifier` 可执行文件 shell-out，**不触发本地编译** | 官方文档（项目 README） | https://github.com/mikaelbr/node-notifier |

**结论**：V1 已知依赖面（Tray/UDS/子进程/通知）**全部走 Electron/Node 内置能力，可以做到零原生模块**，node-gyp 大概率不会介入。若未来引入需要编译的三方包（历史上如老版本 `sqlite3`/`serialport`/`keytar` 等），CLT 依旧够用，唯一要补的是 §2.2 的非 EOL Python（用户态可解，不需要 sudo/Xcode.app）。

---

## 3. 打包/签名/公证

### 3.1 electron-builder 出 .app 的基础工具依赖

**【结论】** electron-builder 官方文档没有单列一页"系统要求"，但可拆解为：打未签名 `.app` 主要靠 Node.js 环境 + electron-builder 自带/自动下载的预编译二进制（`app-builder-bin`、`7zip-bin`，均为"下载对应平台现成可执行文件"模式，不触发本地编译）；打 `.dmg` 用 macOS 系统自带的 `hdiutil`；做签名验证用 `/usr/bin/codesign`（macOS 系统自带存在，但真正**签名**动作依赖 `codesign_allocate`，后者由 Xcode 或 CLT 提供——本机已装 CLT，满足）；图标转换用系统自带 `iconutil`。
**【证据档位】官方文档（部分）+ 社区/工具归属佐证**
**【来源】** https://www.electron.build/docs/features/code-signing/；https://www.electron.build/docs/features/code-signing/code-signing-mac/；https://www.electron.build/docs/mac/

### 3.2 dmg-license 历史坑：已在现行版本修复（推翻过时社区经验）

**【结论，纠正常见但过时的信息】** 2021-2022 年前后广泛流传的"electron-builder 打 dmg 会因为 `dmg-license`（依赖 `iconv-corefoundation` 原生插件）触发 node-gyp 编译失败"这条坑，在**当前发布版本 26.15.3** 中已不成立——直接核实该版本 tag 下 `packages/dmg-builder/package.json` 与 `src/dmgLicense.ts` 源码，`dmg-license` **已不在依赖列表里**，DMG license 功能被重写为纯 TypeScript 实现。只要不主动配置 DMG license 弹窗，`npm install electron-builder` 后打基础 `.app`/`.dmg`，**理论上不会触发任何原生编译**（建议仍以本机实测收尾确认）。
**【证据档位】官方文档 / 一手源码核实**
**【来源】** https://github.com/electron-userland/electron-builder/blob/electron-builder@26.15.3/packages/dmg-builder/package.json（历史背景社区经验：https://github.com/electron-userland/electron-builder/issues/6489）

### 3.3 无签名身份时能走到哪一步

**【结论】** electron-builder 默认 `CSC_IDENTITY_AUTO_DISCOVERY=true`（自动搜钥匙串身份）；本机 0 个身份的情况下，官方文档明确：**未找到有效证书时直接跳过签名，不会自动做 ad-hoc 签名**——要拿 ad-hoc 签名必须显式配置 `mac.identity: "-"`。**开发态 `electron .`（未打包）不受此影响**：因为运行的是官方已经 ad-hoc 签名过的 `Electron.app` 本体（E1 spike 实测 `codesign -dv` 确认 `adhoc,linker-signed`），不会触发 Gatekeeper 拦截（本机 E1 spike 无弹窗、零阻断）。**打包产物**若完全不签名，在 Apple Silicon 上是否能启动是社区经验层面的风险点（内核层面强制要求 arm64 可执行文件至少带有效签名，ad-hoc 也算，但完全零签名理论上会被拒绝加载）；electron-builder 官方 Troubleshooting 页面同时提醒"禁用签名要同时禁用 Hardened Runtime，否则组合可能导致无法启动"。
**【证据档位】官方文档（跳过签名的默认行为、Hardened Runtime 提醒）+ 社区经验（Apple Silicon 强制签名机制，未在 Apple 一手文档找到专门措辞，建议打包环节单独实测）+ 本机实测（开发态不受影响，E1 spike）**
**【来源】** https://www.electron.build/docs/features/code-signing/code-signing-mac/；https://www.electron.build/docs/troubleshooting/；社区佐证 https://eclecticlight.co/2020/08/22/apple-silicon-macs-will-require-signed-code/

### 3.4 正式 Developer ID 签名 + notarytool 公证需要什么

**【结论】** Apple 官方文档（TN3147）明确：**"You don't need the complete Xcode application—the Command Line Tools package contains an identical copy of notarytool."** 即公证只需要有效的 **Developer ID** 证书（需付费 Apple Developer Program 会员身份）+ CLT 自带的 `codesign`/`notarytool`，**不需要装完整 Xcode.app**。electron-builder 内置公证（基于 `@electron/notarize`）支持 Apple ID + App 专用密码，或 App Store Connect API Key 两种认证方式。**这一环节两条路线（Electron / Swift）成本相同**——本机 CLT 已具备 `notarytool 1.0.0` + `codesign`，都够用，公证不是 Swift 独有的负担。
**【证据档位】官方文档**
**【来源】** https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool；https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution；https://www.electron.build/docs/features/code-signing/notarization/

### 3.5 无签名/ad-hoc 状态下通知可用性（推翻预期的发现——与 Swift 侧不同）

**【结论，重要，推翻预期】** `docs/v1-roadmap.md` 记录的是 Swift 侧事实：**无签名 .app 调用 UserNotifications 会直接崩溃**。Electron 官方 API 文档对同一问题给出的是**不同的行为**：Electron 通知底层走的也是 `UNNotification` API（"On MacOS, notifications use the UNNotification API as their underlying framework"），但官方文档明确：**"This API requires an application to be code-signed in order for notifications to appear. Unsigned binaries will emit a `failed` event when notifications are called."**——即 Electron 团队在这层做了兜底，未签名时是**优雅失败（emit `failed` 事件 / `getHistory()` 返回空数组）**，不是进程崩溃。当前 Electron 稳定版 43.2.0 处于这套实现范围内。ad-hoc 签名对 UNUserNotificationCenter 是否足够弹出通知，未找到 Electron/Apple 官方对这个具体组合的直接声明，第三方 `desktop-notifier` 项目文档称"ad-hoc 签名足够本地使用，正式分发建议用开发者证书"，可合理推断适用；结合 §3.3，本机默认打包不会自动 ad-hoc 签名，需显式配置 `mac.identity: "-"` 才能让通知路径可用。**建议列入 E1 后续冒烟范围单独验证**（本次 E1 spike 未覆盖通知 API）。
**【证据档位】官方文档（Electron 通知行为、失败模式）+ 社区经验（ad-hoc 签名对通知是否足够，中等置信度）**
**【来源】** https://www.electronjs.org/docs/latest/api/notification；社区佐证 https://pypi.org/project/desktop-notifier/

---

## 4. 对照：Swift 路线解阻塞成本清单

| 环节 | CLT 是否够用 | 结论依据 |
|---|---|---|
| `xcodebuild`（编译 XcodeGen 生成的 .xcodeproj/.xcworkspace） | **否**，CLT 无此工具 | Apple 官方文档明确列举 `xcodebuild`/`xctrace`/`simctl`/`devicectl` **只随 Xcode.app 分发**，CLT 里没有（本机 `xcodebuild` 不可用，与官方文档吻合）。来源：https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/；https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference |
| XCUITest（UI 自动化测试） | **否** | 依赖同一份"仅 Xcode.app 分发"清单里的 `xcodebuild`/`simctl`；Simulator.app 物理位于 `Xcode.app/Contents/Developer/Applications/` 下，CLT 目录没有。来源同上 |
| SPM 清单解析（`swift build`/`swift test`） | **官方承认"可能受限"，非等价支持** | swift.org 官方安装文档原文："when Xcode is not installed, the functionality of the Swift Package Manager may be limited due to some outstanding issues"；swift-package-manager 官方仓库 issue #7306 里 Apple/Swift 核心维护者亲口确认"issue is specific to the Command Line Tools package"——与本机 `libPackageDescription.dylib` 空导出症状吻合。来源：https://www.swift.org/install/macos/package_installer/；https://github.com/swiftlang/swift-package-manager/issues/7306 |
| SDK pin / 多 SDK 共存切换 | **否**，CLT 单一固定 macOS SDK | 官方文档："You can only install one version of the package on your Mac at a time"，且不含 iOS/watchOS/tvOS 等额外平台 SDK；多平台/多版本管理机制（Xcode Components 面板、`xcodebuild -downloadPlatform`）依赖 Xcode.app。来源：https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/；https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components |
| Developer ID 签名 + notarytool 公证 | **是，CLT 够用**（两条路线公共环节，成本相同） | 见 §3.4 |
| vfsoverlay 直编法（`Spikes/S1PetOverlay/toolchain-workaround/`）天花板 | 仅解锁**裸 `swiftc` 单文件/少量文件直接编译**（绕过 CLT 里损坏的 `module.modulemap` 重复定义 `SwiftBridging` 问题） | 本机实测：S1/S2/S3 三个 spike 均靠这条路径跑通（`run.sh` 用 `swiftc -vfsoverlay` 直编，首编约 35s、热缓存 1s）。**够不到**：`swift build`/`swift test`（SPM 清单解析，与 module.modulemap 问题是两个独立故障——即使把 vfsoverlay 补丁也用在 SPM 上，`libPackageDescription.dylib` 空导出符号问题依然在）、`xcodebuild`（XcodeGen 产物编译）、XCUITest。即**当前规划的"SPM 单包多 target monorepo + XcodeGen + swift-testing(`swift test`) + XCUITest 冒烟"这套正式架构，vfsoverlay workaround 完全覆盖不到，必须靠完整 Xcode.app 解锁**。来源：`Spikes/S1PetOverlay/README.md`「2026-07-28 环境发现」段 |

**Xcode.app 解锁动作**：App Store 下载安装（体积通常数十 GB，视网络环境耗时 30 分钟至数小时不等，本机网络经代理，Mac App Store 走的通道与 npm/GitHub 不同，未实测能否顺畅下载）→ 首次启动装组件 → `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`（**需要 sudo**，与票 Context 里"本机无 sudo 意愿"直接冲突）。这是 Swift 路线在"不想被 Xcode 卡进度"这个顾虑上的核心症结：不是编译器本身坏了修不好，而是**修复路径的入场券**（完整 Xcode.app + 一次 sudo）正是用户想绕开的东西。

---

## 5. 结论表：两条路线「今天能否动工/被什么卡/解阻塞动作与耗时」

| 路线 / 环节 | 今天能否动工 | 被什么卡 | 解阻塞动作与预估耗时 |
|---|---|---|---|
| **Electron — 开发循环**（Node 装机 + `npm install` + `electron .`） | **能，已实测通过**（E1 spike，§1.4） | 无阻塞 | 无需动作。实测：Node 51s + Electron 装 20s ≈ 71s 装机时间 |
| **Electron — V1 能力面**（Tray/UDS/子进程/通知） | **能** | 无阻塞（零原生模块，见 §2.3） | 无需动作 |
| **Electron — 原生模块**（若未来引入需编译的三方包） | 视具体包而定，**目前 V1 范围不触发** | 若触发：Python 3.9.6（CLT 自带）已 EOL，不满足 node-gyp "supported" 要求 | 用户态装非 EOL Python 3.x（python.org installer 或 pyenv），预估 **10-20 分钟**，不需要 sudo/Xcode.app |
| **Electron — 打包 .app/.dmg（未签名/开发态）** | **能**（理论推导，未专项实测，§3.1-3.2） | 无阻塞（CLT 提供 `codesign_allocate`；dmg-license 老坑已在 26.x 修复） | 无需动作，建议后续做一次专项打包 smoke |
| **Electron — 通知可用性（未签名/ad-hoc）** | 优雅失败而非崩溃（官方文档），**具体弹出条件未实测** | 若要通知实际弹出，需 `mac.identity: "-"`（ad-hoc）签名 | 打包配置改一行 + 本机验证，预估 **<30 分钟**；不需要 Xcode.app |
| **Electron — 正式签名+公证** | 需要 Developer ID 证书（当前 0 个身份） | 缺证书（Apple Developer Program 会员，非技术阻塞是流程/费用阻塞） | 注册 Apple Developer Program（人工审核，通常 1 天内~数天）+ 生成证书；CLT 的 `codesign`/`notarytool` 已就绪，不需要装 Xcode.app |
| **Swift — 当前状态**（vfsoverlay 直编，S1/S2/S3 已验证） | **能，但仅限裸 swiftc 直编场景** | vfsoverlay 只解决 module.modulemap 问题，够不到 SPM/xcodebuild/XCUITest（§4） | 已用，无额外动作，但是**天花板已封顶** |
| **Swift — 正式规划架构**（SPM 单包多 target + XcodeGen + swift-testing + XCUITest） | **不能** | `xcodebuild`（XcodeGen 产物）、`swift build`/`swift test`（SPM 清单解析）、XCUITest 三项均官方证实非完整 Xcode.app 不可；vfsoverlay workaround 覆盖不到 | 装完整 Xcode.app（App Store 下载，数十 GB，视网络 **30 分钟至数小时**）+ 首次启动装组件 + `sudo xcode-select -s ...`（**需要 sudo**，与用户"无 sudo 意愿"冲突）+ 首次编译索引等待 |
| **Swift — 正式签名+公证** | 需要 Developer ID 证书（与 Electron 相同缺口） | 缺证书，非工具链阻塞 | 与 Electron 一致：CLT 的 `codesign`/`notarytool` 已就绪，不需要 Xcode.app，只缺证书 |

**一句话对比**：Electron 路线今天已经实测跑通全部开发循环，且打包/签名/公证链路理论上不需要 Xcode.app（唯一共同缺口是两条路线都没有的 Developer ID 证书）；Swift 路线今天能靠 vfsoverlay 绕过跑通裸编译 spike，但要落地已裁决的正式架构（SPM+XcodeGen+XCUITest）必须装完整 Xcode.app 并执行一次 sudo，这正是用户想避开的"被 Xcode 卡进度"场景的技术根因。
