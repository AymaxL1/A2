# 地图:Electron 回退预研 — 不让 Xcode 卡 V1 进度

Labels: wayfinder:map
创建:2026-07-28(深夜;用户 AFK,按用户指令充图与研究票 AFK 并行,问题汇总留至 `questions-for-user.md`)
**到达:2026-07-28 —— 九票全部解决;终裁(09 票)= 不翻案,维持 ADR 0002(Swift 原生),V1 内封栈。本图归档:已评估,维持原判。**

## Destination

一份事实齐备、可当面裁决的回退评估:在「初版尽快落地、不被 Xcode 卡进度」的新动机下(2026-07-28 深夜用户原话),把 ADR 0002(Swift 原生)的裁决理由逐条重检,给出 Electron+TS 路线对已锁定决策集(agent-first、注册表唯一调用面、代理插件首发、S1–S3 已验场景)的等价实现图景、代价清单与本机实测证据;所有需要用户拍板/澄清的问题一次性汇总为 `questions-for-user.md`。**是否翻案 ADR 0002 是 HITL 终裁票(09),不在 AFK 部分。**

## Notes

- **既有决定**:`docs/adr/0001–0007`(均 accepted)、`docs/v1-roadmap.md`、旧图 `.scratch/v1-mac-recharter/`。本图不重开的原则:local-first、构建时可信插件、注册表唯一调用面、agent-first、mihomo 子进程红线。
- **新动机(本图存在的理由)**:用户 2026-07-28:「我的诉求是希望把初版快速开发出来,不希望 Xcode 卡我进度」;更早消息:「Swift 要弄 Xcode 等编译环境非常麻烦,不够通用」。注意历史脉络:Phase 0 三 spike 全部通过、路线图三条回退硬门**均未触发**——本图是硬门框架之外的新裁决动机,不是硬门触发;终裁票须直面这层关系。
- **本机事实(2026-07-28 探针,详见 01 票)**:CLT 的 C/C++ 链健康(坏的只有 Swift 头);**Node 生态零安装**(白板,非损坏);codesign/notarytool 工具齐但钥匙串 0 签名身份;网络经本地代理 127.0.0.1:33888,npm registry 与 GitHub 均通。
- **分工(用户 2026-07-28 指令)**:Fable 5 主会话只做方案设计与决策;闭环操作(调研/探针/spike)由 Sonnet 5 子代理执行。
- **产物落点**:研究结论 `docs/research/electron-recon/<slug>.md`(本 worktree 分支);冒烟 spike 在 `Spikes/E1ElectronSmoke/`;HITL 票不 AFK 解决,其问题进 `.scratch/electron-recon/questions-for-user.md`。
- **tracker 约定**:`docs/agents/issue-tracker.md`。子代理只写自己的票文件与研究文档,**不改本文件**——Decisions so far 由主会话统一回写,避免并发覆盖。
- **文档语言**:中文。

## Decisions so far

<!-- 主会话在各票 resolved 后统一回写 -->

- [测试与 AI 闭环:切 Electron 找回什么](issues/05-testing-ai-loop.md) — 四项成本翻转打折:自读兜底只恢复浅层(manifest/contract 可读,域逻辑仍靠 AI+测试);DOM 面秒级闭环属实(Playwright `_electron`/WebdriverIO 活跃),但**非 DOM 面(Tray/原生菜单/系统弹窗)两栈同弱**(只能白盒打桩)——XCUITest 弱项不构成差异化理由,裁决权重最大修正;语料差距语言级属实、Electron 专属 API 面不明显;升级税形态互换(8 周小步 vs 年度集中)未必更低;S1 实证 Swift 热缓存编译约 1s,AI 闭环差距主要是环境损坏所致而非语言结构性。详见 `docs/research/electron-recon/testing-ai-loop.md`。
- [capability 纵切与 CLI/UDS:S2/S3 在 Electron 的等价形态](issues/03-capability-cli-uds.md) — Node `net` 的 UDS 坑集合与 S2 同源同量,无新增阻塞;dangerous 确认推荐独立 `BrowserWindow`+`app.focus({steal:true})`;**`aa` CLI 分发推荐 Node SEA**(Plan B=yao-pkg;拒绝要求装 node/bun compile(mac 签名 bug)/`ELECTRON_RUN_AS_NODE`(违反 runAsNode fuse 安全声明且破坏 prefix_rule 字面量匹配));**S3 栈无关性确认成立**——Seatbelt 拦的是沙箱内客户端 `connect(2)`,不识别监听端语言,`prefix_rule` 幸存路径不变,且反哺约束 CLI 必须产出干净 `aa` 前缀。详见 `docs/research/electron-recon/capability-cli.md`。
- [「通用性」两种解读的事实盘点](issues/06-portability.md) — 解读(a)开发环境通用性**支持**:V1 依赖面零原生模块,`npm install && npm start` 任意 Node 机器成立(Linux CI/无 Xcode Mac);唯 mac 目标打包/签名/公证锁定真机 mac(Apple 限制;GitHub Actions macOS runner ≈ Linux 10 倍价)。解读(b)跨 Windows **部分支持**:栈无关层不受影响,UDS→named pipe 在 Node `net` 同 API 几乎免费,但 Tray/点透/通知需真机适配,**最大坑=Authenticode 私钥 2023 起强制硬件 token/云 HSM**;量级从「含核心全重写」降为「适配包+独立签名流程」。「切 Electron 但 V1 仍 Mac-only」自洽。详见 `docs/research/electron-recon/portability.md`。
- [宠物悬浮窗:S1 验收项在 Electron 的对标](issues/02-pet-window-parity.md) — 点击穿透**达标**(事件驱动 forward,比 S1 轮询省事,老坑均已关);置顶 level 与 NSWindow.Level 源码级 1:1 **达标**;三处**有坑**:全空间只设 CanJoinAllSpaces+FullScreenAuxiliary、无 S1 用的 `stationary` 位,`visibleOnFullScreen` 隐式藏 dock 图标(需 `skipTransformProcessType` 规避)、mac 透明窗必丢系统阴影+圆角残留(2025-07 仍 closed not planned)、跨屏拖拽跳变非跟手;**最大风险=置顶与全屏 App 抢层级**(2017/2022/2023 三度报告需手动 focus,均 wontfix 类关闭)——正好落在旧回退硬门①的领地,Electron 可能达不到自己的参照水平。真机验收清单与缺口表见 `docs/research/electron-recon/pet-window.md`。
- [常驻成本、系统集成与发布链](issues/04-resident-cost-release.md) — 常驻 RSS **3–5 倍结构性差距**(Electron 空闲 80–300MB/典型 200–400MB vs Swift 菜单栏 30–80MB,`backgroundThrottling`/销毁窗口都消不掉 Chromium 基线);维护税坐实:8 周 major、仅支持最近 3 个(单版本安全窗 ~5.5 月、无 LTS 可蹲);本地无远程内容砍掉大部分 Chromium RCE 面但非零。**签名前提两栈相同**:Electron `Notification` 未签名=静默 failed(比 Swift 崩溃温和,但同样要证书);electron-updater 支持用户确认式更新(对标 Sparkle 成立),Squirrel.Mac 同样强制签名。mihomo:`asarUnpack`/`extraResources`+**必须显式 `mac.binaries` 声明**(builder 不自动重签 extra 二进制),GPL 边界栈无关照旧。体积 90–230MB(含内核)vs Swift 预估 70–100MB。详见 `docs/research/electron-recon/resident-release.md`。
- [本机 Electron 冒烟 spike(E1)](issues/07-local-smoke-spike.md) — **从白板到跑通全程未触碰 Xcode/CLT/sudo**:用户态 Node v24.18.0 装 51s、Electron 33.4.11 装 20s(走代理一次成功、无 Gatekeeper 弹窗);E1a 悬浮窗自检标志全部读回 true、`capturePage` 证实真透明(角像素 alpha=0)、3.5s 自动退出(注:Electron 无 ignoreMouseEvents 读取器,点透留真机验收);E1b 外部 node↔主进程 UDS 往返 33ms、socket 清理干净;**实测 RSS 4 进程共 ≈287MB**(主 119+GPU 59+utility 32+renderer 77,印证 04 票);已知风险:新下载二进制首次执行有 ~33s 一次性系统校验开销,进程内 JS 定时器保证不了硬超时(生产建议外部看门狗)。产物与复现步骤见 `Spikes/E1ElectronSmoke/README.md`。
- [「不够通用 / 不被 Xcode 卡」的确切诉求(HITL)](issues/08-generality-clarify.md) — 「通用」=(a)开发环境+(b)Windows 兼有;ADR 0001 不动(Windows 维持「届时含核心重写」旧承诺,明文放弃 Electron 折扣);Xcode 立场=「接受装,只是不是今天」(堵点是排队阻塞非原则拒绝),安装仪式挂 Phase 0 基建前置、期间只推纸面工作;签名=无账号、暂无分发计划,付费账号+Developer ID 挂 Phase 3 前置。
- [终裁:是否翻案 ADR 0002(HITL)](issues/09-final-ruling.md) — **不翻案,维持 Swift 原生;V1 内封栈**(硬门三战三捷+新动机重评双路径穷尽,此后不再受理)。取舍=接受一次性 Xcode 成本、拒绝结构性重写成本;技术锚点=「宠物窗压全屏之上」定为硬需求(S1 已验 vs Electron wontfix)。产物处置:本图归档、worktree merge 后删、B3 vfsoverlay 装 Xcode 后退役、B4 Tauri 维持出局、E1 43.x 重跑免、ADR 0001–0007 置 accepted(0002 附重评记录)。裁决全文见票内 Answer。
- [Electron 工具链最小面与「免 Xcode」的诚实边界](issues/01-toolchain-xcode-free.md) — 开发循环**零 Xcode 坐实**(预编译二进制,E1 实证);V1 依赖面零原生模块(官方逐项确认;node-gyp 真要用 CLT 也够,唯 CLT 自带 python 3.9.6 已 EOL 属潜在项);**签名+公证是两栈公共环节且成本相同**(TN3147:notarytool 不需 Xcode.app;两栈都缺 Developer ID 证书);Swift 侧三项非完整 Xcode.app 不可(xcodebuild/XCUITest/SPM 清单解析——Apple 维护者确认 CLT 缺陷),vfsoverlay 天花板=裸 swiftc 单文件直编;纠错两条:无签名通知 Swift 崩溃 vs Electron 优雅 failed(不能类比)、electron-builder 26.15.3 已移除 dmg-license 原生依赖;版本口径:Electron latest=43.2.0(E1 实装 33.4.11,镜像滞后,重验点)。两路线「今天能否动工」对照表见 `docs/research/electron-recon/toolchain.md`。

## Not yet specified

(空——本图已到达并终裁(2026-07-28):「若翻案」分支失效;「若不翻案」两项已裁(Xcode 仪式挂 Phase 0 基建前置、vfsoverlay 过渡期保留装后退役);Windows 澄清信号已收(08 票,ADR 0001 不动)。)

## Out of scope

- **实施本身**:真正的栈迁移/重写(或 Xcode 安装仪式)是终裁后的新效fort。
- **ADR 0001(Mac-only)的重开**:本图只澄清「通用性」动机,不裁决平台边界。
- **既有暂缓清单**:TUN、内嵌 Codex、运行时第三方插件、市场、云、App Store、静默更新等,全部维持暂缓。
- **Tauri**:维持出局(03 票裁决,用户不熟 Rust);本图不重开,除非用户明天主动提出。
