# 10 — 决定:内核语言与跨端范围

Type: grilling
Status: resolved

Blocked by: 09

## Question

拿 [09 票](09-kernel-language-landscape.md)事实与用户面试裁定(01 票已定跨端为当下承诺、语言全重议):

1. **端范围**:当下承诺覆盖 macOS+Linux,还是含 Windows?(01 票明确此项由本票连同语言一起裁。)
2. **内核语言**:Swift 跨端 / 换语言重写(Go/Rust)/ 混合(内核换语言、Mac 壳留 Swift)——含测试资产(428 断言)折算、与 mihomo 生态亲和性的权衡、[ADR 0002](../../../docs/adr/0002-swift-native-stack.md) 的处置(修订 or 废止重立)。
3. **[ADR 0001](../../../docs/adr/0001-mac-only-platform-boundary.md) 重写方向**:Mac-only 边界改为什么表述(哪些端进承诺、哪些留远景)。
4. 结论解锁 [04 票](04-kernel-boundary-process-model.md)(内核边界与进程模型)。

## Answer

2026-08-04 现场面试裁定(用户逐项拍板):

1. **端范围:当下承诺 = macOS + Linux;Windows 明确远景、不设预留约束。** 04 票设计不背「别封死 Windows」的包袱;现有 UDS Transport 缝隙已是将来加 Windows 的天然位置。依据:09 票实测 Windows 是常驻(SCM)/UDS(仅 SOCK_STREAM 无凭据)/POSIX 三处都要重设计的独立一档。

2. **内核语言:TS 重写内核。** 决策路径完整记录:
   - 用户首先明确排除 Swift 做内核(Swift 跨端方案出局,尽管它是唯一免重写路线);Rust/Go/TS 三家展开。
   - 关键定性:**本内核是控制面,不是数据面**(流量在 mihomo 子进程;内核做生命周期/注册表/UDS API/确认仲裁)——Rust 的性能优势兑现不了,TS 的 GC/吞吐短板也大半打不到。
   - 决定性裁定:**插件北极星 =「agent 现场写插件」**(插件≈一个 `.ts` 文本文件,agent 当场写当场装,内核 bin 自带运行时把它作**子进程**拉起,进程外隔离保住 dangerous 仲裁)。此形态只有 TS 内核能做到最轻;Go 只能嵌 goja 折中。安全(进程外隔离)与法律(跨语言天然隔离 mihomo,GPL 维度反超 Go)两关皆过,按 01 票裁决序轮到 agent-first 说话。
   - 落选理由:Go——daemon 工况成熟度最高(tailscaled 同款拓扑、小 bin、peercred 一等公民)但插件北极星只有折中解,且同语言 import mihomo 的 GPL 陷阱需 CI 纪律看守;Rust——控制面用不到其运行时优势,重写最慢、agent 迭代摩擦最大,插件北极星同样要嵌 JS 引擎。
   - **运行时基线:Bun compile 单文件 bin**(含 BUN_BE_BUN 复用自带运行时拉插件),以 [11 票](11-ts-runtime-bun-verification.md)实测背书;若实测翻车,运行时选型(Node SEA / Deno compile)在 04 票复议,**语言裁定不自动重开**。
   - 认下的账单:约 10213 行逻辑 + 4929 行测试(428 断言门禁)全量在 TS 侧重建;bin 约 50–90MB、常驻 RSS 高一档;UDS peer credential 走 FFI 或改 socket 文件权限鉴别;launchd/systemd 集成做品类第一个踩路的人。Mac 菜单栏壳留 Swift,经现成 UDS Transport 边界通信。

3. **ADR 处置:0001 与 0002 皆废止重立。** 新 ADR 记「内核跨端边界:macOS+Linux 当下承诺、Windows 及其他端远景、UI 仅 Mac」替代 0001;新 ADR 记「TS 内核栈(Bun 基线)、Mac 壳 Swift」替代 0002;旧文标 superseded 链新文。**ADR 0007 独立子进程红线语言无关、原样保留**,并泛化为插件通用边界(一切插件进程外隔离)。

4. **04 票解锁**,但新增 11 票(Bun 实测)为其输入,04 的 Blocked by 已补 11。
