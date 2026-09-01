# 04 — 决定:内核边界与进程模型

Type: grilling
Status: resolved

Blocked by: 01, 03, 10, 11

## Question

「内核完全是 bin」落成具体拓扑:

1. **内核里装什么**:注册表/`AAHostRuntime`、插件(`PluginProxy`)、mihomo 生命周期、UDS server、(将来)agent-delegation 执行器——全进内核?有没有必须留在壳里的?注意 [12 票](12-mihomo-distribution-form.md)已裁 mihomo 不随包分发:内核职责面改为「脚本安装 / 配置管理 / 开机自启 / 存活检测」,其托管归属(内核托管子进程 vs 系统托管+内核监督)、与用户自装 mihomo 的共存策略,由本票裁。
2. **几个可执行、谁常驻**:`aa`(CLI)与内核合一(单 bin 多模式)还是分离(`aa` 仍薄客户端 + 内核 daemon 常驻)?常驻形态采 03 票哪种(launchd agent / CLI 按需拉起 / GUI 拉起)?崩溃自愈(现由 GUI 宿主承担)归谁?
3. **现有可执行的命运**:`aahost`(现=GUI 宿主)改无头还是废弃重命名?菜单栏壳另立可执行?`aa-agent` 挂哪?
4. **内核语言确认**:01 票已触发跨端语言重议——语言与端范围取 [10 票](10-kernel-language-decision.md)结论,本票在其后裁。

## Answer

2026-08-04 现场面试七问钉死(用户逐项拍板;语言与端范围直接取 10 票结论不重议):

1. **单 bin 多模式**:TS 内核编译为**一个**可执行产物——默认入口是 CLI 子命令,`aa kernel run`(命名归 07 票)进前台常驻模式(调试用)。理由:Bun 产物 60.5MiB 由运行时决定、与代码量无关(11 票实测),拆双 bin 即双倍体积+版本漂移风险;daemon 与 CLI 天然同版本;插件运行时(`BUN_BE_BUN`)也是同一个文件。先例:mihomo/caddy/k3s/bun 自身。
2. **常驻 = 系统托管 + 显式安装**:`a2 service install|uninstall|status`(07 票定名)一次性写 launchd user 域 plist(`launchctl bootstrap` 路径,03 票实测背书)/ systemd user unit;**开机自启与崩溃自愈(`KeepAlive.Crashed`/`Restart=on-failure`)全归系统 supervisor**——现由 GUI 宿主承担的自愈职责就此移交,应用层不再造看门狗。未安装/未运行时 CLI **永不隐式拉起**,返回结构化指引(含精确修复命令,与 05 票「拒绝即指引」同构)。
3. **mihomo = 系统托管 + 内核监督**:脚本安装的 mihomo 挂**自己的** launchd/systemd unit(我们的命名空间,安装脚本一并落下);开机自启、崩溃重拉归系统;内核职责收敛为配置管理+reload、存活探测、经 launchctl/systemctl 启停。落地 10 票「内核是控制面、mihomo 是数据面」定性:**数据面不随控制面起落**,内核崩溃/升级不断用户网络。
4. **共存 = 检测并优先复用,复用到实例级**(用户裁定,并**明确解除**产品层面「不接管用户 mihomo」的约束;注意:agent 在本机施工不动用户 mihomo 的施工红线不受影响)。姿态阶梯:①检测到**运行中实例**(external-controller 可达)→ 经 API 接管配置与存活监督,但**进程生死仍归其原托管方**——实例死了内核只报警+指引,不越权重拉;②仅检测到**二进制** → 只读复用二进制,配置/数据/unit 全套自建;③全无 → 脚本安装,版本由我们发布元数据锁定。复用形态做兼容性下限检查,不达标回退隔离安装;升级永远是显式命令(静默更新在图的 Out of scope)。
5. **旧可执行全换、不设双 daemon 过渡期**:内核内容清单——注册表/`AAHostRuntime` 等价物、插件宿主、mihomo 监督、UDS server、dangerous 三层仲裁(05 票)、将来的 delegation 执行器——**全进 TS 内核**(「主逻辑零 UI 依赖」前提的直接推论)。`aahost` 宿主职责全迁,Swift 侧只留菜单栏壳+确认器(保留范围归 06 票);`aa`(Swift 薄 CLI)由 TS bin 整体接替;`aa-agent`/`AAAgentCore` 挂起,执行器将来在内核内以 TS 重生(05 票仲裁收敛的延续)。重构期用 git 分支隔离,切换原子;10213 行 Swift 逻辑与 4929 行测试**降级为 TS 重写的行为规范参考**(门禁口径归 08 票)。
6. **插件进程模型钉死,细活毕业**:插件 = **进程外 `.ts` 子进程**,内核经自带运行时(`BUN_BE_BUN`,11 票实测)拉起——ADR 0007 独立子进程红线泛化为插件通用边界的落地。协议形态(与 MCP 同构?)、依赖机制(node_modules 怎么进来)、装载审批(与 dangerous 仲裁交接)三件强耦合细活**新开 [13 票](13-plugin-protocol-loading.md)一并裁**(雾区「插件北极星连带面」就此毕业)。
7. **路径约定 = 统一 `~/.a2` 点目录**(原裁 `~/.aa`,07 票 a2 命名定案连动修订):两端同形,环境变量 `A2_HOME` 可覆写;socket 在 `~/.a2/run/kernel.sock`,配置/数据/日志各归子目录;unit 命名空间 `com.a2.*`。取代 `AAPaths.swift` 的 macOS 假设(09 票盘点的纯逻辑区唯一平台绑定点)。安全基线:Bun 的 UDS 权限跟随 umask(11 票实测),内核必须自建 socket 父目录 0700 并在 bind 后显式收紧权限。
