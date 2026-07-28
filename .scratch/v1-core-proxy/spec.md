# Spec:V1 平台最小核 + 代理插件(Phase 0 基建收尾 + Phase 1)

Status: ready-for-agent
创建:2026-07-28(/to-spec 综合,无新面试)
决策来源:`docs/v1-roadmap.md`(Phase 0/1)、ADR 0001–0007、[07 票·架构映射](../v1-mac-recharter/issues/07-swift-architecture-mapping.md)、[04 票·代理范围](../v1-mac-recharter/issues/04-proxy-plugin-v1-scope.md)、S1/S2/S3 spike 结论(`Spikes/*/README.md`)、[09 票·终裁](../electron-recon/issues/09-final-ruling.md)。

## Problem Statement

我需要一个常驻 Mac 菜单栏的桌面插件平台。当下最迫切的真实需求是代理管理:我自己能在菜单栏一键开关系统代理、切模式、选节点、管订阅;更关键的是能让外部 Agent(Codex)替我操作这一切——「让 Codex 给我设 mihomo」——全程不需要我盯着,只有动到流量信任面(换订阅源)时才需要我亲手确认一次。

目前仓库里只有决策集(ADR 0001–0007)、路线图和三个一次性 spike:方向已锁死(Swift 原生、V1 内封栈),但没有可持续演进的正式代码骨架,平台核不存在,代理插件不存在,门禁脚本不存在。spike 代码是证据不是产品,不能直接长成 V1。

## Solution

在正式工程骨架上落平台最小核,并以代理插件作首个真实纵切:

- **骨架(Phase 0 基建收尾)**:单 SPM 包多 target monorepo、XcodeGen app 壳(菜单栏应用)、`Scripts/check.sh` 一键门禁、最小签名仪式(开发级)。
- **平台最小核(Phase 1 平台侧)**:manifest 与能力注册表正式化(风险三档 + 宿主确认 UI)、UDS server、`aa` 双层命令面 + agent 引导文档、ProcessPort、菜单栏宿主框架。
- **代理插件(Phase 1 插件侧)**:mihomo 子进程壳,系统代理接管/还原/崩溃自愈,订阅/模式/节点/测速,菜单栏轻壳,safe/normal/dangerous 全套能力面。

验收 = 旗舰场景:Codex 经 `aa` 开代理/切节点全程零 GUI 打断;换订阅源必触发宿主 GUI 确认。

## User Stories

### 平台核 · agent 侧

1. 作为外部 Agent(Codex),我想用 `aa capabilities list|describe <id> --json` 发现平台能力并读到参数 schema,以便不靠人类口述就能正确编排调用。
2. 作为外部 Agent,我想用 `aa capabilities call <id> --json` 得到稳定机读输出与明确退出码语义,以便可靠判断每次调用的成败并据此决策。
3. 作为外部 Agent,我想在触发 dangerous 能力时 CLI 立即返回 pending/denied 语义而非交互阻塞,以便我的执行流程永不挂起等待终端输入。
4. 作为沙箱内的外部 Agent,我想有 `aa docs agents-md` 输出的接入片段与 `prefix_rule` 一行信任配置示例,以便用户一次批准后我就能在沙箱外执行 `aa`(S3 实测:沙箱内 UDS/TCP 全被拦,此路是唯一官方姿态)。
5. 作为外部 Agent,我想让「开代理/切节点/更新已有订阅」全程零 GUI 打断(normal 级),以便完成「Codex 替用户设代理」的旗舰场景。

### 平台核 · 用户侧

6. 作为桌面用户,我想要一个常驻菜单栏、不占 Dock 的宿主应用,以便平台随手可及且不打扰。
7. 作为桌面用户,我想让 dangerous 能力的最终确认永远弹在宿主 GUI 且 agent/CLI 无法绕过,以便任何自动化都改不了我的信任面而不经过我。
8. 作为桌面用户,我想用 `aa install-cli` 把 CLI 装进 PATH,以便终端和 agent 都能直接调用 `aa`。
9. 作为桌面用户,我想在宿主未运行时让 `aa` 明确报错并提示如何启动宿主,以便不对着死套接字排障。
10. 作为人类终端用户,我想要人体工学的域子命令(如 `aa proxy on|off`),而不是只有 `capabilities call` 底座,以便手工操作不用背长命令。

### 平台核 · 结构侧

11. 作为插件作者(未来的 AI/自己),我想让插件 target 只能依赖 SDK+Contracts(+UISystem),编译期禁止 import Host*,以便插件边界由编译器强制而非纪律。
12. 作为平台维护者,我想把能力契约、manifest 模型、风险三档、IPC 协议类型全部定在零依赖的 Contracts target,以便宿主、插件、CLI 三方共用同一套词汇且不循环依赖。

### 代理插件 · 用户侧

13. 作为桌面用户,我想在菜单栏一键开/关系统代理,以便随手接管或退出代理。
14. 作为桌面用户,我想切换代理模式(规则/全局/直连),以便按场景改变分流行为。
15. 作为桌面用户,我想按代理组选择节点,以便手工指定出口。
16. 作为桌面用户,我想保存多个订阅、同一时刻只激活一个、手动触发更新,以便管理多个机场而互不干扰。
17. 作为桌面用户,我想按组做延迟测速(URL test),以便挑出能用的节点。
18. 作为桌面用户,我想看到基础状态(内核运行与否/监听端口/当前模式与节点),以便一眼确认代理在不在工作。
19. 作为桌面用户,我想让应用正常退出时停掉内核并把系统代理还原到接管前状态,以便退出后网络立即恢复直连。
20. 作为桌面用户,我想让应用崩溃/被强杀后,下次启动时检测到系统代理仍指向已死端口就自动恢复接管或还原,以便不滞留在断网态。
21. 作为桌面用户,我想在换订阅源(新增/替换)时必须经过宿主 GUI 确认,以便流量信任面变更永远由我亲手放行(平台 dangerous 模型首个真实用例)。
22. 作为桌面用户,我想在关于页看到 mihomo 的 GPL-3.0 文本、内核版本与源码指引,以便合规义务对将来分发就绪(ADR 0007)。

### 基建 · 维护者侧

23. 作为平台维护者(AI 写码、用户监督),我想要 `Scripts/check.sh` 一条命令跑完 build+test+快照,以便每次改动自动验证、门禁不可绕过。
24. 作为平台维护者,我想让 XcodeGen 的 `project.yml` 入库而生成的 `.xcodeproj` 不入库,以便工程文件可审、可再生、无合并噪声。
25. 作为监督者(不读 Swift 的用户),我想让视图层测试产出可 diff 的快照图片,以便不读代码也能抽查 UI 长什么样。
26. 作为平台维护者,我想完成一次性开发级签名仪式(开发签名 + 首次 TCC/通知授权),以便 UserNotifications 等需签名的 API 不崩、后续开发不被授权弹窗打断。

## Implementation Decisions

以下均为已裁决事项的汇编(07/04 票、ADR、S3 回写),本 spec 不改变任何一条;「归实施」的细节由 ticket/实现定。

**工程形态**
- 单 SPM 包、多 target;跨 target import 必须在清单声明,编译期边界与多包等价。Target:`AAContracts`(零依赖底座)/`AAPluginSDK`/`AAHostRuntime`(纯逻辑)/`AAHostMacOS`(macOS Port 实现)/`AAHostTestKit`(Fake host,测试专用)/`AAUISystem`/`PluginProxy`/`aa`(CLI executable)。AA 前缀暂定,实施可调。本 spec 只建 `PluginProxy` 一个插件 target;Pet/Reminder 是 Phase 2,不建空壳。
- app 壳用 XcodeGen:`LSUIElement` 菜单栏应用,依赖本地 SPM 包;XCUITest target 在 Xcode 工程侧;构建链全脚本化(generate → build/test → 统一重签内嵌二进制)。
- 门禁先落本地脚本(仓库已 git 化,将来上 GitHub 后原样迁 Actions macOS runner,不在本 spec 内)。

**平台核**
- 注册表是唯一业务调用面(ADR 0004):GUI 与 CLI 同源,全部调用经注册表路由与分级确认,确认不可绕过。
- 风险三档:safe(只读)/normal(可逆状态变更)/dangerous(信任面变更,宿主 GUI 最终确认;CLI 永不交互阻塞,返回 pending/denied 语义)。
- CLI = 独立 `aa` 可执行 + UDS 薄客户端;JSON 请求/响应协议类型定义在 Contracts,宿主与 CLI 共用;`aa` 随 .app 打包,`aa install-cli` 建符号链接;宿主未运行明确报错(可选 `--launch` 归实施)。UDS 路径归实施。
- 双层命令面:`aa capabilities list|describe|call --json` 通用底座 + 从注册表元数据映射的域子命令;全命令 `--json` 稳定输出 + 退出码语义;`aa docs agents-md` + `prefix_rule` 信任引导为必做(S3 回写升格)。
- 能力命名 `域.动词`;首批实例即代理插件清单。

**代理插件**
- mihomo 为 PluginProxy 私有资源打进 .app;子进程拉起/健康检查/回收走宿主 ProcessPort(特权面归宿主、业务面归插件);控制面走 mihomo 官方 REST;不做通用「托管内核服务」抽象。
- 内核随应用锁版;集成红线 = 只走子进程 + REST/外部 CLI,永不进程内链接(ADR 0007)。
- 系统代理经 `networksetup`(V1 仅系统代理模式,零特权助手);接管前快照系统代理状态;正常退出停内核+还原;崩溃自愈按 04 票第 2 项(检测指向已死端口 → 恢复接管或还原;快照记录与检测细节归实施)。
- 能力分级清单(04 票第 3 项):safe = `proxy.status`/`proxy.groups.list`/`proxy.latency.test`;normal = `proxy.system.enable|disable`/`proxy.mode.set`/`proxy.node.select`/`proxy.subscription.update`(仅已有源);dangerous = 新增/替换订阅源、直接覆写内核配置。
- 菜单栏轻壳对标 ClashX Meta;GUI 是能力面之上的薄壳。

**签名仪式(对 roadmap 的一处收敛)**
- roadmap Phase 0 原文含 `notarytool store-credentials`;终裁(09 票 A4)确认无 Apple Developer 付费账号、暂无分发计划。故本 spec 将仪式收敛为**开发级**:开发签名(免费 Apple ID 开发证书,不足则记录缺口)+ 首次 TCC/通知授权;公证凭据与 Developer ID 随付费账号挂 Phase 3 前置。此为对 roadmap 文本的显式修正,不动 ADR。

**工具链两段式(过程约束,影响拆票)**
- Xcode.app 未装(本机 CLT 损坏,`swift build` 不可信;用户明日安装)。装妥前:纯逻辑代码用 swiftc 直编 + vfsoverlay(S2 已验多文件/多二进制/AppKit)+ assert 式脚本验证;`Package.swift`/XcodeGen/快照/XCUITest 只能写不能验。装妥后:vfsoverlay 退役,全部真值化为 `swift build` + swift-testing。拆票时每张票必须标注验证环:「vfsoverlay 可验」或「需 Xcode」,后者标 blocked 直到环境就绪。

## Testing Decisions

**好测试的标准**:只测外部行为(命令的输出与退出码、Port 收到的调用序列、状态快照的恢复结果),不测实现细节;每张票的红绿循环必须有一条当天就能跑的验证命令。

**三层 seam(2026-07-28 用户确认)**:

1. **主 seam:`aa` CLI 端到端**。CLI 是薄客户端,一条 `aa capabilities call … --json` 穿透 CLI 解析→UDS 协议→注册表路由→能力执行→分级确认全链;E2E 用脚本驱动真宿主进程断言输出与退出码。先例:S2 的 test.sh(7/7 PASS,含 dangerous 确认/拒绝两分支真机点验)。
2. **次 seam:Host Port 协议(AAHostTestKit 假件)**。一切副作用(窗口/通知/networksetup/子进程/mihomo REST)压到 Port 后面;Contracts、Runtime、PluginProxy 域逻辑(接管快照/自愈判定/订阅状态机/分级路由)以 swift-testing 打 Fake host,零 macOS 依赖、零真 mihomo。金字塔主体在这层。
3. **视图层:快照测试**,菜单栏各状态渲染成可 diff 图片(产物供用户抽查);**XCUITest 仅 ~10 条发版冒烟**,不进日常门禁。

**门禁**:`check.sh`(build + test + 快照)每次改动必过;`smoke.sh`(XCUITest)发版前必过。Xcode 就绪前,check.sh 的暂行形态 = vfsoverlay 直编 + assert 脚本(即 S2 模式),就绪后切换为 swift build + swift test,脚本接口(一条命令、非零退出即失败)保持不变。

**被测模块**:AAContracts(协议类型编解码/manifest 校验)、AAHostRuntime(注册表/分级确认策略/路由)、PluginProxy 域逻辑(经 Fake Port)、`aa`(E2E 脚本)、AAUISystem 与菜单栏视图(快照)。

## Out of Scope

- Phase 2:宠物、提醒两插件(含其能力面与 target)。
- Phase 3:Developer ID 分发、公证流水线、Sparkle 自更新、迁移/备份、smoke 十条集齐、发布 checklist。
- 排期外清单全部维持:TUN、仪表盘大窗、流量图表、连接列表、日志查看器、规则编辑、provider 高级特性、订阅定时自动更新、应用内独立升内核、运行时第三方插件、市场、云账号/同步、App Store、静默更新、内嵌 Codex、Windows/Web、MCP adapter。
- CI 上云(GitHub Actions):本地脚本先行,迁移另立。
- 修复本机 CLT / 安装 Xcode 本身:用户动作,非本 spec 工作项(但为部分票的 blocker)。

## Further Notes

- 语言:全部产出(代码注释、文档、票)中文;能力面与命令行文案对 agent 输出为英文 JSON、对人类可中文。
- 先例代码:S1(NSPanel 悬浮窗)、S2(注册表纵切 + UDS + aa + dangerous 确认)、S3(沙箱结论)是**证据不是地基**——正式代码全新起在 SPM 骨架上,可抄思路与坑位(`@main @MainActor` 入口、`fflush(stdout)`),不搬运文件。
- 旗舰场景验收辞:「Codex 经 `aa` 开代理/切节点全程零 GUI 打断;换订阅源必触发宿主确认」——此场景通过即 Phase 1 出口。
- 签名仪式与 TCC 授权需用户在场点头,拆票时标 `ready-for-human` 协作段。
