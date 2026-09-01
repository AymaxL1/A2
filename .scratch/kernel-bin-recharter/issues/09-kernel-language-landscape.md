# 09 — 调研:跨端内核的语言与平台成本盘点

Type: research
Status: resolved

## Question

[01 票](01-premises-confirm.md)已裁:内核跨端是当下承诺,语言重议全开(Swift/Go/Rust 都在桌上),端范围连同语言由 [10 票](10-kernel-language-decision.md)一起裁。产出 10 票裁决所需事实:

1. **Swift 跨端现状**:Swift on Linux(Foundation/NIO 成熟度、静态链接、交叉编译、发行版支持)与 Swift on Windows 的真实生产可用度;本仓库内核侧逻辑(UDS server、进程/mihomo 生命周期、注册表)迁 Linux 的 API 缺口——先在本机实测盘点内核相关 target 实际 import 了哪些 Apple 专属框架(AppKit/UserNotifications 等),分「纯逻辑/可移植」与「平台绑定」两栏。
2. **候选语言对比**(Go/Rust 为主):daemon+CLI 工具先例的语言选型(tailscaled=Go、syncthing=Go、mihomo 自身=Go 等)、单静态 bin 分发难易、三端成熟度;与 mihomo(Go)生态的亲和性——库级复用/嵌入是否因同语言而可行,及其对 [ADR 0007](../../../docs/adr/0007-mihomo-subprocess-gpl-compliance.md) GPL 独立子进程结论的影响(嵌入=衍生作品风险,须标注)。
3. **重写成本口径**:现有 Swift 代码与测试资产(428 断言门禁、swift-testing 全量迁移)按两条路线折算——(a) 保留 Swift 内核走跨端;(b) 内核换语言重写、Mac 壳留 Swift(混合拓扑,IPC 边界先例)。
4. **平台差异清单**:常驻机制(launchd/systemd/Windows 服务)、UDS 可用性(含 Windows AF_UNIX 现状)、路径/权限模型——按「macOS+Linux」与「再加 Windows」两档分列,供 10 票裁端范围。

结论落 `docs/research/kernel-language-cross-platform.md`(中文,来源带 URL,区分实测/文档/推断;本机可实测项直接实测)。

## Answer

调研全文见 [kernel-language-cross-platform.md](../../../docs/research/kernel-language-cross-platform.md)(来源带 URL,区分【实测】/【文档】/【推断】)。要点:

1. **Swift 跨端口径:Linux 扎实、Windows 仍在补课。** swift.org 官方把 Linux 主流发行版与 Windows 同列"Deployment and Development"档,但 Windows 2026-01 才成立专门 Workgroup 去补 Foundation/Dispatch 的"Windows 惯用法"缺口,官方博客措辞本身承认这块仍需持续投入;第三方"已生产可用"说法均为二手来源,非 swift.org 原话。Linux 侧 swift-nio/Vapor/AWS Lambda 有多年生产先例,静态链接靠 2024 年才发布的 Static Linux SDK(musl,非 Glibc),成熟度不及 Go 十余年的 `CGO_ENABLED=0` 传统。
2. **本机实测:平台绑定面比想象窄,只有 AppKit 一项。** `grep` 全仓库 Sources/Tests 的 import 面:15 个 Sources target 里只有 `AAHostMacOS`/`aahost`/`menu-snapshot` 三个(共 2386 行,占 Sources 全部 12599 行的 18.9%)绑定 `AppKit`;其余 12 个 target、10213 行为纯逻辑(`Foundation` + 内部模块),其中 4 个 target(`AAAgentSystem`/`AAAgentTestKit`/`aa`/`aa-agent`,合计 3476 行)额外 `import Darwin` 用 POSIX 系统调用(`socket`/`bind`/`posix_spawn`/`kill`/`signal` 等),Linux 侧可用 Glibc 桥接、Windows 侧无直接等价物。全仓库未发现 `import Security`/`UserNotifications`/`ServiceManagement`/`CryptoKit` 的证据(4 处 `cdhash`/`NSWorkspace` 等命中均为 AppKit 用法或纯注释)。Tests/ 合计 4929 行、182 个 `@Test`,三个测试 target 均零 AppKit 依赖。UI 层已是"一个模型(`AAUISystem`)、两个渲染器(`AAHostMacOS`/`menu-snapshot`)"架构。
3. **Go 是 daemon+CLI 品类的绝对先例,但换 Go 重写内核会放大而非降低 mihomo 嵌入的 GPL 风险。** tailscaled/syncthing/mihomo 自身均为 Go、`CGO_ENABLED=0` 单静态二进制 + `GOOS`/`GOARCH` 原生交叉编译,工具链成熟度显著高于 Swift 方案。但 ADR 0007"永不进程内链接"红线是语言无关的物理判据(FSF FAQ 原文:静态或动态链接进同一可执行文件"definitely combined in one program");Go 生态里 `import` mihomo 包和普通库调用毫无区别,没有 Swift 场景下 cgo/c-archive 那道天然摩擦,"同语言"降低的是**误入陷阱的门槛**而非风险本身——ClashX Meta 正是用 `-buildmode=c-archive` 静态链接内核而被迫转 AGPL-3.0 的先例。**无论内核换哪种语言,ADR 0007 的独立子进程结论都必须原样保留**,不因同语言库复用可行而重议。
4. **重写成本两条路线折算(基于实测行数):** (a) 保留 Swift 走跨端——12599 行 Sources + 4929 行 Tests 全部保留,只需给 3476 行 POSIX 调用补 Glibc 条件编译、2386 行 AppKit 壳天然不参与内核跨端;(b) 内核换语言、Mac 壳留 Swift——约 10213 行纯逻辑 Sources + 全部 4929 行 Tests(含 17 票刚完成的 swift-testing 全量迁移资产)面临整体重写或等价重建,2386 行 AppKit 壳保留但需巩固一层跨语言 IPC 客户端——该边界现状代码里已存在(`aa`/`aa-agent` 本就经 UDS `Transport` 与宿主通信),非从零新建。
5. **平台差异清单(两档):** macOS+Linux 两端常驻机制均支持裸 bin 直接注册(launchd/systemd 均可 `ExecStart=`/`Program` 任意可执行文件)、UDS 语义完全对齐(三种 socket 类型 + 凭据传递均支持)、路径约定有清晰的 `~/Library` ↔ XDG 对应关系。再加 Windows:常驻是唯一"裸 bin 不能直接挂"的一档(SCM 要求原生服务协议或包装层,如 `golang.org/x/sys/windows/svc`);UDS 自 Win10 Build 17063 起可用但**仅 `SOCK_STREAM`**、不支持凭据/描述符传递,且三语言运行时封装成熟度不齐(swift-nio 2020 年有基础实现但上层库仍禁用、Rust 标准库 Windows UDS 至今 nightly-only 未稳定);POSIX 系统调用(`fork`/`posix_spawn`/`kill`)在 Windows 无直接等价物,进程/IPC 层需重新设计而非简单条件编译切换。
6. **本仓库当前唯一的平台绑定路径约定:** `AAContracts/AAPaths.swift` 把 UDS socket 路径写死为 `~/Library/Application Support/AA/aa.sock`,是纯逻辑代码里唯一残留的 macOS 专属假设(非框架依赖,是路径字符串约定),10 票裁跨端范围时需连带处理。
