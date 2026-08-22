# 内核跨端语言与平台成本盘点：Swift / Go / Rust，macOS / Linux / Windows

> 调研日期：2026-08-04。决策落点：[ADR 0009：内核平台范围](../adr/0009-kernel-platform-scope.md)、[ADR 0010：TS 内核与 Bun 运行时](../adr/0010-ts-kernel-bun-runtime.md)。
> 确定性档位（沿用 [kernel-daemon-topology.md](kernel-daemon-topology.md) 惯例）：
> - **【实测】**：本机在本仓库（macOS 15.7.8 / arm64，`swift-driver version: 1.120.5`、`Apple Swift version 6.1.2`）上用只读命令（`grep`/`wc`/`find`）直接跑出的结果。
> - **【文档】**：swift.org / GitHub 官方仓库或 PR / Microsoft 官方 devblog / Go、Rust 官方文档 / FSF 官方 FAQ 等一手权威来源的原文或转述。
> - **【推断】**：基于上述事实的分析，或来自社区博客/二手转述、未经一手来源逐字确认。

## 0. 结论摘要

1. **Swift 官方口径下 Linux 与 Windows 都是"开发+部署"平台（非仅部署），但两者成熟度不对称**：Linux 因 swift-nio/Vapor/AWS Lambda 多年生产先例而扎实；Windows 是 2026-01 才成立专门 Windows Workgroup 去补 Foundation/Dispatch 的"Windows 语义"缺口，官方口径本身承认"仍有持续投入的必要"，第三方"已生产可用"的说法均来自社区二手信源而非 swift.org。**【文档+推断】**（§1）
2. **本仓库内核相关代码里，真正"平台绑定"的只有 3 个 target、共 2386 行（占 Sources 全部 12599 行的 18.9%）：`AAHostMacOS`、`aahost`、`menu-snapshot`，绑定点仅 `AppKit`**；未发现直接 `import Security`/`UserNotifications`/`ServiceManagement`/`CryptoKit` 的证据。其余 11 个 target、10213 行为「Foundation + 内部模块」纯逻辑代码，其中 4 个 target（`AAAgentSystem`/`AAAgentTestKit`/`aa`/`aa-agent`，合计 3476 行）额外 `import Darwin` 用 POSIX 系统调用（`socket`/`bind`/`posix_spawn`/`kill`/`signal` 等），这批调用在 Linux 上有 Glibc 等价物，可用 `#if canImport(Darwin)/#elseif canImport(Glibc)` 桥接，无需换语言即可移植。**【实测】**（§2）
3. **UI 层已经是"一个模型、两个渲染器"架构**（`AAUISystem` 定义平台无关的菜单模型，`AAHostMacOS` 用 AppKit 渲染，`menu-snapshot` 另渲染成快照产物），且 `AAHostTestKit`（539 行）虽名为 Host 测试工具，实际零 AppKit 依赖——说明现有代码已经在架构层面把"内核/宿主逻辑"和"Mac 壳"分开，这对两条重写路线（保留 Swift 走跨端 / 换语言重写内核）都是有效资产，不因语言裁决而报废。**【实测】**（§2、§4）
4. **daemon+CLI 品类里 Go 是绝对主流先例**（tailscaled、syncthing、mihomo 自身），核心卖点是 `CGO_ENABLED=0` 零依赖单静态二进制 + `GOOS`/`GOARCH` 原生交叉编译，工具链成熟度显著高于 Swift 的 Static Linux SDK（2024 年才发布，且需 musl 而非 Glibc）。Rust 在此品类也有静态二进制先例（如用户态 WireGuard 的 Rust 实现），但生态权重明显小于 Go。**【文档】**（§3）
5. **换 Go 重写内核，恰恰会把 mihomo 库级嵌入的诱惑和风险同时放大，而不是降低**：ADR 0007 的"永不进程内链接"红线是语言无关的物理判据（FSF 官方 FAQ 原文："Linking a GPL covered work statically or dynamically with other modules is making a combined work"；"If the modules are included in the same executable file, they are definitely combined in one program"）。Go 生态里 `import "github.com/MetaCubeX/mihomo/..."` 在语法上和普通库调用毫无二致（无需 Swift 那种 cgo/c-archive 的额外仪式），"同语言"降低的是**误入衍生作品陷阱的门槛**，不是降低陷阱本身——ClashX Meta 正是用 `go build -buildmode=c-archive` 把内核静态链进宿主而被迫转 AGPL-3.0 的先例（`docs/research/mihomo-integration.md` 已引用其 [build 脚本](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX/goClash/build_clash_universal.py)与 [LICENSE](https://github.com/MetaCubeX/ClashX.Meta/blob/master/LICENSE)）。**无论内核用 Swift/Go/Rust 哪个实现，ADR 0007 的"独立子进程 + 外部接口通信"结论都必须原样保留**，"同语言库复用"不能作为重议该红线的理由。**【文档+推断】**（§3.2）
5.5. **重写成本折算**：路线 (a) 保留 Swift 走跨端——12599 行 Sources + 4929 行 Tests 全部保留，只需给 3476 行 POSIX 调用补 Glibc 条件编译分支、给 2386 行 AppKit 绑定代码之外的 10213 行内核逻辑接跨端 CI；路线 (b) 内核换语言、Mac 壳留 Swift——约 10213 行纯逻辑 Sources + 全部 4929 行 Tests（含 [17 票](../../.scratch/v1-core-proxy/issues/17-swift-testing-migration.md)迁移的 swift-testing 资产、182 个 `@Test`）面临整体重写或用新语言等价重建，2386 行 AppKit 壳保留但需新增/巩固一层"内核是外部进程"的 IPC 客户端——这层边界在现状代码里已经存在（`aa`/`aa-agent` CLI 本就通过 UDS `Transport` 与宿主通信，`AAHostMacOS` 与 `PluginProxy`/内核子进程之间也是外部接口而非同进程调用），并非从零新建。**【实测+推断】**（§4）
6. **UDS 在 Windows 上"能用但缩水"**：Windows 自 Build 17063（对应 Win10 1803+）原生支持 `AF_UNIX`，但**只支持 `SOCK_STREAM`**，不支持 `SOCK_DGRAM`/`SOCK_SEQPACKET`、不支持 `socketpair()`、不能像 Linux `SCM_RIGHTS` 那样传递文件描述符/凭据（Microsoft 官方 devblog 原文）；三门语言的运行时对此的封装成熟度也不一致——Go `net` 包已支持（但 `unixgram`/`unixpacket` 在 Windows 上不可用）、swift-nio 有一个 2020 年合入的清理路径实现但上层库（`AsyncHTTPClient`）明确声明 UDS 在 Windows 不可用、Rust 标准库的 Windows UDS 支持至今仍是 nightly-only 未稳定特性。**【文档】**（§5）

---

## 1. Swift 跨端现状：官方口径

### 1.1 平台支持分级（swift.org 官方）

swift.org [Platform Support](https://www.swift.org/platform-support/) 页面（对应 Swift 6.3.3）**不用 Tier 1/2/3 数字分级**，而是两档描述性分类 **【文档】**：

> - **Deployment and Development**："Swift programs can be built to run on this platform and the development tools for Swift — such as the Swift compiler — also run on this platform."——涵盖 macOS、Ubuntu、Debian、Fedora、Amazon Linux、Red Hat Universal Base Image、**Windows**。
> - **Deployment-only**："Swift programs can be built to run on this platform, but the development tools themselves that build those programs may not themselves run on this platform."——涵盖 iOS/watchOS/tvOS/Android。

即官方口径下 **Windows 与 Linux 主流发行版同属"开发+部署"档**（最低版本 Ubuntu 20.04 / Debian 12 / Fedora 39 / Windows 10.0），形式上与 macOS 平级；但"同属一档"不等于"同等成熟度"，见 1.2/1.3。

来源：<https://www.swift.org/platform-support/>

### 1.2 Windows：2026-01 才成立专门 Workgroup，官方自认仍有缺口

- Windows 自 2020 年起是"官方支持平台"，但 2026-01 swift.org 新设 **Windows Workgroup**，其官方 mandate 原文 **【文档】**：
  > "ensure ongoing support for Swift on Windows, enabling users to develop Windows applications using the Swift programming language and its associated tools."
  >
  > 具体职责包括 "Recommend enhancements to core Swift packages such as **Foundation and Dispatch** to work better with **Windows idioms**"、"Identify and recommend best practices for bridging between Swift and the Windows API"。
  
  来源：<https://www.swift.org/blog/announcing-windows-workgroup/>

  **解读【推断】**：专门成立工作组去改进 Foundation/Dispatch 对 Windows 习惯的适配，本身即是官方对"当前 Foundation/Dispatch 在 Windows 上还不够地道"的承认——这与"生产可用"并不矛盾（可用≠完美），但意味着内核侧若要用到 Foundation 的深层 API（进程管理、文件系统权限、通知），在 Windows 上遇到语义差异或缺口的概率高于 Linux。

- 2026-03 *What's new in Swift* 官方博客里，Windows/Linux 相关内容集中在 **Swift Build**（新构建系统）跨平台化，原文措辞是"landing hundreds of patches to improve Swift Build's support across various platforms including Linux and Windows"，且明确邀请开发者"give it a try" / "file bugs"——**属预览性质的措辞，非"已生产就绪"的宣告** **【文档】**。来源：<https://www.swift.org/blog/whats-new-in-swift-march-2026/>

- 第三方信源（非 swift.org 官方）声称"Swift on Windows is production ready, today"，并举 Readdle、The Browser Company 等公司为例 **【推断，二手来源，未经官方逐字确认】**。来源：<https://speakinginswift.substack.com/p/swift-on-windows-a-year-of-refinement>（同一篇明确提醒"You are not going to be building SwiftUI or AppKit UIs directly on Windows"——即便该来源可信，也只覆盖非 UI 的 CLI/服务端场景，与本仓库内核 bin 的形态吻合，但不能覆盖 Mac 壳）。

### 1.3 Linux：swift-nio/Foundation 有多年服务端生产先例，静态链接工具链 2024 年才成熟

- **swift-corelibs-foundation**（Linux 版 Foundation）明确声明"builds for non-Darwin platforms only"，但存在已知空缺：`NSFileHandle` 因依赖 `NSXPCConnection`（Darwin-only）而不可用，`NSSortDescriptor`/`NSPredicate`/`NSExpression` 因依赖 KVC 不可用；且应用需自行管理 ICU 等系统依赖，不像 Darwin 那样预置。**【文档】**。来源：<https://github.com/swiftlang/swift-corelibs-foundation>
- **swift-nio** 是 Linux 侧最成熟的生态支柱：Vapor、AWS SDK Swift、gRPC Swift、Postgres/Redis 客户端均建其上；AWS 官方把 [swift-aws-lambda-runtime 移交给 awslabs](https://aws.amazon.com/blogs/opensource/the-swift-aws-lambda-runtime-moves-to-awslabs) 组织，Lambda 场景下 Swift + NIO 在 Amazon Linux 上的性能"约 1.19ms，与 Node.js（~1.06ms）、Java（~1.16ms）同一量级" **【文档转引，来源为社区 benchmark 文章，非官方 AWS 基准】**。整体上 swift-nio 在 Linux 上的服务端场景属于"实战多年、有商业背书"，是本次盘点里 Swift 跨端最强的证据。
- **静态链接**：[Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html) 用 musl（非 Glibc）实现"可复制到任意发行版直接跑"的完全静态二进制，官方原文列出 musl 的两个选型理由之一是"has excellent support for static linking"。真实先例：Tuist 的 CLI 已用它跑通 Linux 分发（<https://tuist.dev/blog/2026/02/16/linux>）。**【文档】**。但该 SDK **2024 年年中才发布**（AWS Lambda 用例约 2024-06 出现），相比 Go 十余年的静态编译传统，成熟期短得多；且切到 musl 意味着不能直接用 Glibc 专属特性，需要验证依赖链（含本仓库 POSIX 调用面，见 §2.2）在 musl 下的行为一致性——本次调研未做该项本机验证，留给后续 spike。

### 1.4 小结：对本仓库内核逻辑迁移的含义

- 本仓库内核相关代码（§2 已实测）几乎不触碰 Foundation 的 Darwin-only 深水区（`NSXPCConnection`/`NSFileHandle` 高级特性、KVC 系）——主要用到的是 `Foundation` 基础类型 + 手写 POSIX 调用，这部分在 Linux 上迁移成本主要是「Darwin → Glibc」条件编译，而非 Foundation API 缺口。
- Windows 缺口更大：不仅要处理 POSIX→Win32 API 映射（`posix_spawn`/`fork`/`kill`/`sockaddr_un` 均无直接 Win32 等价，需要重新设计进程/IPC 层），还要接受 Foundation/Dispatch 在 Windows 惯用法上的官方自述"仍在打磨"状态。

---

## 2. 本机实测：import 面盘点与代码规模

方法：`grep -rhE '^\s*import' --include='*.swift' Sources Tests` 按 target 去重列出；`wc -l` 统计每个 target 的 `.swift` 总行数。`swift package describe --type json` 在本机因 `Package.swift` 的 `swiftLanguageModes:` 参数与本机 CommandLineTools 的 `PackageDescription` API 版本不兼容而报错退出（`error: extra argument 'swiftLanguageModes' in call`），未产出可用 JSON——此为本机工具链已知问题（非本票范围），故本节全部改用 `grep`/`wc` 直接盘点。**【实测】**

### 2.1 按 target 分类：纯逻辑可移植 vs 平台绑定

| Target | 类型 | 行数 | import 面 | 分类 |
|---|---|---:|---|---|
| `AAContracts` | library | 447 | `Foundation` | 纯逻辑 |
| `AAPluginSDK` | library | 332 | `AAContracts`, `Foundation` | 纯逻辑 |
| `AAHostRuntime` | library | 340 | `AAContracts`, `Foundation` | 纯逻辑 |
| `AAUISystem` | library | 624 | `AAContracts` | 纯逻辑（UI **模型**，不含渲染） |
| `AAAgentCore` | library | 2655 | `AAContracts`, `Foundation` | 纯逻辑 |
| `AAAgentSystem` | library | 866 | `AAAgentCore`, `Darwin`, `Foundation` | 纯逻辑（含 POSIX，需 Glibc 桥接） |
| `AAAgentTestKit` | library | 413 | `AAAgentCore`, `AAAgentSystem`, `Darwin`, `Foundation` | 纯逻辑（含 POSIX） |
| `PluginProxy` | library | 1763 | `AAContracts`, `AAPluginSDK`, `AAUISystem`, `Foundation` | 纯逻辑 |
| `AAHostTestKit` | library | 539 | `AAContracts`, `AAHostRuntime`, `AAPluginSDK`, `AAUISystem`, `Foundation`, `PluginProxy` | 纯逻辑（**零 AppKit**，虽名为 Host 测试工具） |
| `aa` | executable (CLI) | 1003 | `AAContracts`, `Darwin`, `Foundation` | 纯逻辑（含 POSIX） |
| `aa-agent` | executable (CLI) | 1194 | `AAAgentCore`, `AAAgentSystem`, `AAContracts`, `Darwin`, `Foundation` | 纯逻辑（含 POSIX） |
| `registry-tests` | executable | 37 | `AAAgentTestKit`, `AAContracts`, `Foundation` | 纯逻辑 |
| **`AAHostMacOS`** | library | 2167 | `AAContracts`, `AAHostRuntime`, `AAPluginSDK`, `AAUISystem`, **`AppKit`**, `Darwin`, `Foundation`, `PluginProxy` | **平台绑定** |
| **`aahost`** | executable | 31 | `AAHostMacOS`, **`AppKit`** | **平台绑定**（薄入口） |
| **`menu-snapshot`** | executable | 188 | `AAContracts`, `AAHostMacOS`, `AAHostTestKit`, `AAUISystem`, **`AppKit`**, `Foundation` | **平台绑定**（快照渲染器） |

**Sources 合计 12599 行**：平台绑定 3 个 target 共 **2386 行（18.9%）**，纯逻辑 12 个 target 共 **10213 行（81.1%）**；纯逻辑范围内又有 4 个 target（`AAAgentSystem`+`AAAgentTestKit`+`aa`+`aa-agent` = 3476 行）额外 `import Darwin` 用 POSIX 系统调用。

**Tests 合计 4929 行**，三个测试 target 均**不含 AppKit**（`AAContractsTests` 83 行只 `import Testing`；`AAHostTestKitTests` 1923 行；`AAAgentTestKitTests` 2923 行、含 `Darwin`），182 个 `@Test` 函数。**【实测】**

补充语境（非本次实测，转引仓库既有记录）：[docs/v1-roadmap.md:57](../v1-roadmap.md) 与 [16 票](../../.scratch/v1-core-proxy/issues/16-flagship-acceptance.md) 记录门禁 `Scripts/check.sh` 现跑出 **PASS 428**（[13 票](../../.scratch/v1-core-proxy/issues/13-dev-signing-ceremony.md)后 +1 → 429），该数字是 `check.sh` 脚本统计的检查项通过数，口径与本节 `wc -l`/`@Test` 计数不同，不可直接相加或替换。**【文档转引】**

未发现直接 `import Security`/`import UserNotifications`/`import ServiceManagement`/`import CryptoKit`/`import Combine`/`import SwiftUI` 的证据（`grep -rlE` 全仓库扫描零命中）。进一步核实 4 处提及 `NSStatusItem`/`NSWorkspace`/`NSPanel`/`cdhash`/`codesign` 字样的文件：`HostApp.swift`（`NSStatusItem`，属已导入的 `AppKit`）、`AboutWindow.swift`（`NSWorkspace.shared.open` 打开 GPL 许可证文本，同属 `AppKit`）、`MenuBarController.swift`（仅注释提及 `NSStatusItem`）、`PluginProxy/MihomoKernelResource.swift`（`cdhash`/`codesign` 仅出现在**注释**里，描述 `Bundle.module` 与 `codesign` 对 `.app` 布局的一个已知打包坑，代码本身只 `import Foundation`，未见 `Security.framework` API 调用）。**【实测】**——即当前"平台绑定"面比想象中窄：只有 AppKit 一项，没有 Security/UserNotifications/ServiceManagement 等更深的系统集成。

### 2.2 POSIX 系统调用面（Darwin → Glibc 桥接量）

全仓库 `import Darwin` 出现在 17 个文件（含 1 个测试文件）。跨这些文件 grep 常见 POSIX 符号出现次数（用于估计迁移工作量）**【实测】**：

```
write 51  kill 47  read 42  socket 32  signal 32  close 21  waitpid 13
posix_spawn 12  pipe 11  bind 10  accept 9  sockaddr_un 7  fcntl 7
unlink 6  listen 5  fork 4  connect 3  chmod 2  dup2 1
```

这批符号（`socket`/`bind`/`listen`/`accept`/`sockaddr_un` 用于 UDS server；`posix_spawn`/`fork`/`waitpid`/`kill`/`signal` 用于子进程生命周期管理，对应 mihomo 内核子进程与内部 agent 子任务）在 Glibc 下均有等价符号，是 Swift 社区处理跨端可移植代码的标准模式（`#if canImport(Darwin) import Darwin #elseif canImport(Glibc) import Glibc`）——**【推断，基于 Swift 生态通行写法，未在本仓库或第三方逐字验证】**。在 Windows 上则没有直接等价物：`fork`/`posix_spawn`/`sockaddr_un` 均需改用 Win32 `CreateProcess`/`AF_UNIX`（见 §5.2）或改变整体进程模型，迁移成本显著更高于 Linux。

---

## 3. Go/Rust 候选对比

### 3.1 daemon+CLI 品类先例：语言选型与单静态 bin 分发

| 项目 | 语言 | 单静态 bin | 交叉编译 | 来源 |
|---|---|---|---|---|
| tailscaled（Tailscale） | Go | 是——`CGO_ENABLED=0` + `-extldflags '-static'` 产出零依赖静态二进制 | 原生：设 `GOOS`/`GOARCH` 环境变量即可，无需额外工具链 | <https://www.gofaq.org/en/how-to-build-static-binaries-in-go/>、<https://www.gofaq.org/en/how-to-cross-compile-go-programs-goos-and-goarch/> |
| syncthing | Go | 是——约 12–15 MiB 无外部依赖（唯一例外是常见 SQLite C 实现），Windows/macOS/Linux/FreeBSD/Android 均从同一代码库产出原生二进制 | 原生 | <https://docs.syncthing.net/dev/building.html> |
| mihomo（本身） | Go | 是（官方发行本身即单文件） | 原生 | 沿用 [mihomo-integration.md](mihomo-integration.md) 已确认的官方发行事实 |

**【文档】**。三个先例共同点：Go 的 `CGO_ENABLED=0` + `GOOS`/`GOARCH` 组合是**十余年打磨、业界默认**的单文件跨平台分发方案，工具链自带、零额外 SDK 安装，与 Swift 2024 年才发布、依赖 musl 的 Static Linux SDK（§1.3）相比成熟度和易用性有代差。

Rust 侧同品类先例权重较小（本次未找到与 tailscaled/syncthing 同等体量、同品类的 daemon+CLI 头部项目；用户态 WireGuard 的 Rust 实现 boringtun 是相邻品类的静态二进制先例，但非本次核心比对对象）。Rust 静态二进制通常靠 `musl` target（`x86_64-unknown-linux-musl` 等）实现，原理与 Swift Static Linux SDK 相近，但 Rust 工具链对此支持年限（自 2016 年前后 musl target 即存在于 Rust 生态）明显长于 Swift。**【推断，未逐一核实具体年份】**

### 3.2 mihomo 库级复用/嵌入：GPL 风险与 ADR 0007 的关系

**FSF 官方 GPL FAQ 原文**（<https://www.gnu.org/licenses/gpl-faq.html>）关键两句 **【文档】**：

> "Linking a GPL covered work statically or dynamically with other modules is making a combined work based on the GPL covered work."
>
> "If the modules are included in the same executable file, they are definitely combined in one program."

**真实先例（本仓库既有调研已确认，转引自 [mihomo-integration.md](mihomo-integration.md)）**：ClashX Meta 用 `go build -buildmode=c-archive` 把 mihomo 内核**静态链接进同一可执行文件**（[build_clash_universal.py](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX/goClash/build_clash_universal.py)），其仓库 [LICENSE](https://github.com/MetaCubeX/ClashX.Meta/blob/master/LICENSE) 因此是 **AGPL-3.0**（GitHub 识别）——即便宿主本身是 Swift 写的、和 Go 内核"异语言"，静态链接依然触发了 copyleft 传染。**【文档，转引已有调研】**

**对 10 票"换 Go 重写内核"选项的具体含义**（本次新增分析）**【推断】**：

- 若内核换 Go 实现，Go 生态里引用 mihomo 的最省事写法就是 `import "github.com/MetaCubeX/mihomo/xxx"` 后直接调用其 Go API——这在语法上和引用任何普通第三方库完全一样，**没有 Swift 场景下"要走 cgo/c-archive 才能调 Go 代码"这道天然摩擦**。也就是说，"同语言"消除的恰恰是**曾经拦住 Swift 宿主的那道技术门槛**，反而让"顺手 `go get` 一下就把 GPL-3.0 代码编进同一个二进制"这件事变得**更容易无意间发生**，而不是更安全。
- ADR 0007 的红线——"内核只以独立子进程运行，控制面只走其外部接口（REST API / 配置文件），永不进程内链接"——**判据是"是否同一可执行文件"，与实现语言无关**。这条红线在 Go 重写场景下必须**原样保留**，且需要比 Swift 场景更强调团队纪律（因为技术摩擦力更低）：即便内核换 Go，也必须继续 `exec.Command` 拉起官方 mihomo 二进制作为独立子进程，而不是 `import` 其代码。
- 唯一会实质改变 ADR 0007 结论的情形，是**宿主自身也整体开源**（ADR 0007 原文已提及"若要零风险，可把代理插件本体开源"这条备选，但那是产品/商业决策，不因换语言而自动触发或免除）。

---

## 4. 重写成本口径：两条路线折算

基于 §2 实测的行数与 target 分类，[ADR 0010](../adr/0010-ts-kernel-bun-runtime.md) 裁决时采用的两条路线成本对照：

**路线 (a)：保留 Swift 内核，走跨端（Linux 必做，Windows 视裁决）**

- 全部 12599 行 Sources + 4929 行 Tests（182 个 `@Test`）**保留**，无需重写测试断言资产。
- 需要新增的迁移工作：
  - 3476 行 `import Darwin` 代码补 `#if canImport(Glibc)` 分支（§2.2 列出的 POSIX 符号集），Linux 侧证据支持这条路径可行（swift-nio 生态本身就是这么处理跨端 POSIX 差异的）；Windows 侧无直接等价物，需重新设计进程/IPC 层（§5.2）。
  - 2386 行 AppKit 绑定代码（`AAHostMacOS`/`aahost`/`menu-snapshot`）**天然不参与内核跨端**——它们本就是 Mac 壳，内核 bin 的跨端范围只覆盖 10213 行纯逻辑 target，这批代码不需要为了跨端而改动。
  - 需补 Linux（视裁决也需 Windows）CI 矩阵与 Static Linux SDK（或等价工具链）验证，§1.3 已指出该 SDK 2024 年才发布、成熟度低于 Go 方案，需要实测验证期。

**路线 (b)：内核换语言重写，Mac 壳留 Swift（混合拓扑）**

- 面临整体重写/移植的是 10213 行纯逻辑 Sources（`AAContracts`/`AAAgentCore`/`AAAgentSystem`/`AAHostRuntime`/`AAPluginSDK`/`AAUISystem`/`PluginProxy`/`AAHostTestKit`/`aa`/`aa-agent`/`registry-tests`）+ 全部 4929 行 Tests（[17 票](../../.scratch/v1-core-proxy/issues/17-swift-testing-migration.md)刚完成的 swift-testing 全量迁移资产、182 个 `@Test`）——这批测试断言若不能自动转译，需要用新语言等价重建，是两条路线里成本差最大的一项。
- 2386 行 AppKit 壳（`AAHostMacOS`/`aahost`/`menu-snapshot`）**保留**，但内核从"同 SPM 包内的 Swift target"变成"外部进程"，需要巩固一层跨语言 IPC 客户端——**这层边界并非从零新建**：`aa`/`aa-agent` CLI 现状就是通过 UDS `Transport`（[Sources/aa/Transport.swift](../../Sources/aa/Transport.swift)）与宿主通信，`AAHostMacOS` 与 mihomo 内核子进程之间也早已是"外部接口"而非同进程调用（ADR 0007 红线本就要求如此）。换言之，"Mac 壳通过 IPC 说话、不直接 import 内核代码"这条架构原则在现状代码里已经成立，路线 (b) 只是把"内核"这一端的实现语言换掉，边界本身不用重新发明。
- 该路线不影响 §3.2 的 GPL 结论：无论内核换成 Go/Rust，对 mihomo 仍须保持独立子进程。

**【实测+推断】**——行数与 target 分类为实测（§2），"迁移可行/需重建"的定性判断为推断（未实际执行迁移验证两条路线中的任一步）。

---

## 5. 平台差异清单

### 5.1 常驻机制

| | macOS | Linux | Windows |
|---|---|---|---|
| 机制 | launchd（`LaunchDaemon`/`LaunchAgent`，plist + `launchctl bootstrap`），细节见 [kernel-daemon-topology.md §1](kernel-daemon-topology.md) | systemd（unit 文件 + `systemctl`），现代主流发行版（Ubuntu/Debian/Fedora/RHEL 等，含 swift.org 支持列表里的全部 Linux 发行版）事实标准 | Service Control Manager（SCM）——原生服务需实现 Win32 服务协议（`StartServiceCtrlDispatcher` 等），Go 生态有现成封装 `golang.org/x/sys/windows/svc` |
| 权限模型 | daemon 需 root（`/Library/LaunchDaemons`），agent per-user（`~/Library/LaunchAgents`） | systemd 支持 system unit（root）与 user unit（`systemctl --user`），细粒度到 uid/gid、`seccomp` 系统调用过滤、只读/不可达路径隔离 | SCM 服务默认在系统账户（`LocalSystem`/`LocalService`/`NetworkService`）下运行，与登录会话无关；用户级"开机自启"另有任务计划程序（Task Scheduler）路径 |
| 对任意可执行文件的支持 | launchd 原生支持任意 `Program`/`ProgramArguments`，不要求 `.app` | systemd 原生支持任意 `ExecStart=` 路径 | **原生 SCM 要求可执行文件自己实现服务控制协议**，普通 CLI 二进制不能直接注册为服务，需要 `golang.org/x/sys/windows/svc` 这类包装层，或第三方壳（NSSM/WinSW）——这是三平台里唯一"裸 bin 不能直接挂常驻"的一档 |

**【文档+推断】**：systemd/launchd 差异部分沿用 [kernel-daemon-topology.md](kernel-daemon-topology.md) 已实测/已引用的结论；Windows SCM 服务协议要求原生实现、需要包装层这一点，来自 Go 官方 `golang.org/x/sys/windows/svc` 包文档（<https://pkg.go.dev/golang.org/x/sys/windows/svc>）与其 mgr 子包（<https://pkg.go.dev/golang.org/x/sys/windows/svc/mgr>），说明该模式是 Go 生态的通行解法，非 Swift/Rust 独有问题。

### 5.2 UDS / IPC

| | macOS | Linux | Windows |
|---|---|---|---|
| AF_UNIX 可用性 | 原生（BSD socket 家族一部分） | 原生 | 自 Windows 10 Build 17063（约 2018-04，1803 更新）起原生支持，通过 Winsock API 使用 |
| 支持的 socket 类型 | `SOCK_STREAM`/`SOCK_DGRAM`/`SOCK_SEQPACKET` 均可 | 同上 | **仅 `SOCK_STREAM`**；不支持 `SOCK_DGRAM`/`SOCK_SEQPACKET`；不支持 `socketpair()` |
| 凭据/描述符传递 | 支持（`SCM_RIGHTS`/等价机制） | 支持 `SCM_RIGHTS`/`SCM_CREDENTIALS` | **不支持**——Winsock 2.0 无 ancillary data 机制传文件描述符或凭据 |
| 权限模型 | 文件系统权限（socket 文件所在目录的写权限） | 同左 | 同左（微软官方原文："the creation of the new socket file will fail if the calling process does not has write permission on the directory"），行为上与 Unix 对齐 |
| 各语言运行时封装成熟度 | 三语言均原生成熟 | 三语言均原生成熟 | Go `net` 包已支持 `net.Listen("unix", ...)`（`unixgram`/`unixpacket` 在 Windows 上不可用）；swift-nio 有 2020-10 合入的清理路径实现（[PR #1654](https://github.com/apple/swift-nio/pull/1654)），但上层 `AsyncHTTPClient` 明确声明 UDS 在 Windows 不可用；Rust 标准库的 `std::os::windows::net`（`UnixListener` 等）**仍是 nightly-only 未稳定特性**（`windows_unix_domain_sockets` feature gate） |

**【文档】**。来源：Windows AF_UNIX 能力本身——Microsoft 官方 devblog <https://devblogs.microsoft.com/commandline/af_unix-comes-to-windows/>；Go 支持现状——<https://pkg.go.dev/net> 及相关 issue（<https://github.com/golang/go/issues/26072>）；swift-nio——<https://github.com/apple/swift-nio/pull/1654>（已确认 2020-10-05 合并）与 AsyncHTTPClient 文档（DeepWiki 转引 <https://deepwiki.com/swift-server/async-http-client/4.5-unix-domain-socket-support>，非官方一手但指向官方仓库行为，标记为文档级）；Rust——nightly 文档 <https://doc.rust-lang.org/nightly/std/os/windows/net/struct.UnixListener.html>。

本仓库现状（`Sources/AAContracts/AAPaths.swift`）：UDS 路径写死为 `~/Library/Application Support/AA/aa.sock`，即 **macOS 专属目录**，是当前唯一"平台绑定的路径约定"（非框架依赖）。**【实测】**

### 5.3 路径与权限模型

| | macOS | Linux | Windows |
|---|---|---|---|
| 用户级数据目录惯例 | `~/Library/Application Support/<App>` | XDG Base Directory 规范：`$XDG_DATA_HOME`（默认 `~/.local/share`）、`$XDG_CONFIG_HOME`（默认 `~/.config`）、`$XDG_RUNTIME_DIR`（用户级运行时文件，含 socket，通常 `/run/user/<uid>`） | `%LOCALAPPDATA%` / `%APPDATA%`（`known folder` API），无 XDG 对应的"runtime dir"概念 |
| 权限/沙箱模型 | TCC（按 bundle identifier + Designated Requirement 记账，[kernel-daemon-topology.md §?] 已实测 ad-hoc 签名下的脆弱性） | 传统 Unix 权限位 + capabilities（`CAP_NET_ADMIN` 等，TUN 场景相关）+ systemd 的 sandboxing 选项（seccomp、只读路径） | NTFS ACL + UAC（管理员提权走 UAC 弹窗，无 macOS TCC 式的"按签名身份记账"逻辑） |

**【推断，基于三平台惯例的常识性归纳，未逐条查证官方最新文档】**——本节仅作为 10 票裁端范围时的路径设计参考，非严格意义的一手调研，若需要精确落地建议在具体实现阶段针对目标平台单独查证。

### 5.4 两档汇总：macOS+Linux vs 再加 Windows

**macOS + Linux（两端）**：
- 常驻机制均支持"裸 bin 直接注册"（launchd `Program`/systemd `ExecStart=`），无需额外包装层。
- UDS 语义完全对齐（三种 socket 类型、凭据传递均支持），现有 `sockaddr_un`/`socket`/`bind`/`accept` 代码逻辑可直接复用，只需换 `import Darwin`→`import Glibc`。
- 路径约定需要新增一层"XDG vs `~/Library`"的分支，但概念对应关系清晰（社区惯例成熟）。
- Swift 官方口径下 Linux 是"多年生产先例"的一档（swift-nio/Vapor/Lambda）。

**再加 Windows（第三端）**：
- 常驻机制要求原生实现 SCM 服务协议或引入包装层，是唯一"裸 bin 不能直接挂常驻"的平台，Go 生态有现成封装、Swift/Rust 需自行处理或找第三方方案。
- UDS 功能降级（仅 `SOCK_STREAM`，无凭据传递），且三语言运行时封装成熟度均落后于 Linux/macOS（Rust 甚至未稳定）。
- POSIX 系统调用（`fork`/`posix_spawn`/`kill`/`signal`）在 Windows 上无直接等价物，进程/IPC 层需要重新设计而非简单条件编译切换。
- Swift 官方口径下 Windows 是 2026-01 才成立专门工作组、自认"仍需补 Foundation/Dispatch 的 Windows 惯用法"的一档，与 Linux 不同代。

---

## 来源汇总

- Swift 平台支持：<https://www.swift.org/platform-support/>
- Windows Workgroup 公告：<https://www.swift.org/blog/announcing-windows-workgroup/>
- 2026-03 Swift 月报：<https://www.swift.org/blog/whats-new-in-swift-march-2026/>
- swift-corelibs-foundation：<https://github.com/swiftlang/swift-corelibs-foundation>
- Static Linux SDK：<https://www.swift.org/documentation/articles/static-linux-getting-started.html>
- Tuist Linux CLI 先例：<https://tuist.dev/blog/2026/02/16/linux>
- AWS Lambda Swift Runtime 移交 awslabs：<https://aws.amazon.com/blogs/opensource/the-swift-aws-lambda-runtime-moves-to-awslabs>
- Go 静态二进制/交叉编译：<https://www.gofaq.org/en/how-to-build-static-binaries-in-go/>、<https://www.gofaq.org/en/how-to-cross-compile-go-programs-goos-and-goarch/>
- syncthing 构建文档：<https://docs.syncthing.net/dev/building.html>
- FSF GPL FAQ：<https://www.gnu.org/licenses/gpl-faq.html>
- ClashX Meta 静态链接先例（转引自本仓库既有调研）：<https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX/goClash/build_clash_universal.py>、<https://github.com/MetaCubeX/ClashX.Meta/blob/master/LICENSE>，见 [mihomo-integration.md](mihomo-integration.md)
- Windows AF_UNIX：<https://devblogs.microsoft.com/commandline/af_unix-comes-to-windows/>
- Go net 包 Unix socket：<https://pkg.go.dev/net>、<https://github.com/golang/go/issues/26072>
- swift-nio Windows UDS：<https://github.com/apple/swift-nio/pull/1654>
- Rust Windows UDS（未稳定）：<https://doc.rust-lang.org/nightly/std/os/windows/net/struct.UnixListener.html>
- golang.org/x/sys/windows/svc：<https://pkg.go.dev/golang.org/x/sys/windows/svc>、<https://pkg.go.dev/golang.org/x/sys/windows/svc/mgr>
- 本仓库既有调研（内部引用）：[mihomo-integration.md](mihomo-integration.md)、[kernel-daemon-topology.md](kernel-daemon-topology.md)、[docs/v1-roadmap.md](../v1-roadmap.md)
