# macOS 无头内核 bin 的进程拓扑与分发先例调研

> 调研日期：2026-08-04。决策落点：[ADR 0008：内核 bin 化与 UI 可选壳](../adr/0008-kernel-bin-ui-optional.md)、[ADR 0012：Panel 自足引导](../adr/0012-panel-self-sufficient-bootstrap.md)。
> 资料原则：事实优先引一手来源（Apple 官方文档/本机 man page、各工具官方文档与源码、GitHub issue 中维护者原话）；社区博客/论坛作为补充二手来源标注。每条结论标注确定性档位：
> - **【实测】**：本机在 macOS 15.7.8（24G824）上直接跑出的结果（`man`、`sw_vers` 等只读命令）。
> - **【文档】**：Apple 官方文档 / 官方 man page / 工具官方文档或源码中的原文，非本机验证但来源权威。
> - **【推断】**：基于上述事实的分析或社区共识，未经一手权威来源逐字确认，或存在多方说法冲突。

## 0. 结论摘要

1. **裸 bin 完全不需要 `SMAppService`，也不需要 `.app` bundle 才能常驻。** launchd 本身的注册路径（`Program`/`ProgramArguments` + 手装 plist + `launchctl bootstrap <domain-target> <plist>`）与 `.app` 无关，本机 man page 逐字确认；`SMAppService` 是 Apple 在 macOS 13+ 提供的**更省心但要求 daemon plist 内嵌在 app bundle 里**的新 API，不是唯一路径，也不是 launchd 的硬性前提。**【实测/文档】**
2. **同类「daemon + CLI + 可选 GUI」工具在 macOS 上分两大流派**：(i) 工具自带子命令自行写 plist 装到 `/Library/LaunchDaemons` 并 `launchctl bootstrap`（tailscaled `install-system-daemon`、Homebrew `brew services`）；(ii) 由壳/GUI 的 Process API 按需拉起子进程、不进 launchd 常驻表（mihomo 内核本身、多数 Clash 系 GUI 对内核的管理方式）。GUI 缺席时功能面通常完整，唯一常见缺口是「自动更新」（OrbStack headless 文档明确写了这条例外）。IPC 几乎清一色 Unix Domain Socket 或 `127.0.0.1` REST；只有触达系统级网络能力（Network Extension/System Extension）时才必须挂 Apple 私有框架，那条门槛与「daemon 常驻」本身无关。**【文档】**
3. **裸 bin 与 `.app` 在 Gatekeeper 上的「过不了线上评估」这件事上没有实质差别**——本仓库现状（ad-hoc 签的 `.app`，13 票已实测 `spctl` reject）本就过不了，换成裸 bin 一样过不了（都缺公证票）。但两者的授权稳定性机制不同：**`.app` 的 TCC 授权按 bundle identifier + Designated Requirement 记账，裸 bin 按绝对路径记账**——如果内核未来要接触任何 TCC 敏感能力（通知/自动化等），裸 bin 形态下"路径一变权限清零"叠加 ad-hoc 下"cdhash 一变权限清零"，会比现状更脆弱；如果内核完全不碰 TCC 敏感能力（纯 REST controller + 子进程管理），这一维度对裸 bin 化没有影响。**【实测转引/推断】**
4. **打包位置（内核 bin 旁挂 vs 独立下载）本身不动摇 ADR 0007 的"separate programs / arms-length"结论**——`docs/research/mihomo-integration.md` 已确认的中高确定性判断只依赖"独立子进程 + 外部接口通信"，与目录结构无关。**真正被 headless 拓扑动摇的是义务的呈现位置**：ADR 0007 现将 GPL 文本与源码指引挂在"关于页"，一旦 UI 降为可选壳，必须有一条不依赖 UI 的路径（CLI 子命令输出 / 随 bin 落盘的静态文本文件）来承载这两项义务，否则会出现"用户全程只用 `aa`、从未装 UI 壳，却从未见过 GPL 声明"的合规缺口。**【推断，基于 ADR 0007 原文逻辑延伸】**

---

## 1. launchd 常驻形态：官方口径与坑

### 1.1 Daemon vs Agent 的基本区别

Apple Technical Note TN2083（已归档但仍是最系统的一手说明）**【文档】**：

> "A **daemon** is a program that runs in the background as part of the overall system (that is, it is not tied to a particular user). A daemon cannot display any GUI; more specifically, it is not allowed to connect to the window server."
> "An **agent** is a process that runs in the background on behalf of a particular user. Agents are useful because they can do things that daemons can't, like reliably access the user's home directory or connect to the window server."

— 来源：[Technical Note TN2083: Daemons and Agents](https://developer.apple.com/library/archive/technotes/tn2083/_index.html)

安装位置：daemon 的 plist 放 `/Library/LaunchDaemons`（系统级、root 运行、开机即起、不依赖任何登录）；agent 的 plist 放 `~/Library/LaunchAgents` 或 `/Library/LaunchAgents`（per-user、用户登录后由该用户的 launchd 实例加载）。来源同上，及 [Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) **【文档】**。

对内核 bin 的含义：若要求"无需任何人登录即常驻"（如机器重启后立刻可用），只有 **LaunchDaemon** 这条路，代价是必须以 root 或指定系统账户运行、且不能碰 window server；若接受"用户登录后才起"，**LaunchAgent** 就够，且能力上不受 window server 限制（虽然内核本身也不该碰 GUI）。

### 1.2 登录会话依赖：`LimitLoadToSessionType` 与 launchctl 的 domain 模型

本机 `man 5 launchd.plist`（macOS 15.7.8）**【实测】**：

> `LimitLoadToSessionType <string or array of strings>` — "This configuration file only applies to sessions of the type(s) specified. This key only applies to jobs which are agents. There are no distinct sessions in the privileged system context."

社区资料补充四种取值 **【推断/社区共识】**：`Aqua`（GUI 登录会话，不指定时的默认值）、`Background`（per-user 但不依赖 GUI，用户登出后仍可存活）、`LoginWindow`（登录前的预登录上下文）、`StandardIO`（SSH 等非 GUI 会话）。来源：[TN2083](https://developer.apple.com/library/archive/technotes/tn2083/_index.html) 附带的会话类型讨论，及多篇二手技术笔记的交叉引用（未找到 Apple 现行文档逐字重申这四个值，故此条降级为推断/社区共识而非纯文档）。

本机 `man 1 launchctl`（macOS 15.7.8）逐字确认 **launchctl 的 domain-target 模型**，这决定了内核 bin 常驻在"是否需要人登录"这件事上的实际选择面 **【实测】**：

> `system/[service-name]` — "targets the system domain... considered a privileged execution context"
> `user/<uid>/[service-name]` — "A user domain may exist independently of a logged-in user."
> `login/<asid>/[service-name]` — "A user-login domain is created when the user logs in at the GUI"
> `gui/<uid>/[service-name]` — "Another form of the login specifier... targets the domain based on which user it is associated with"

结论：**`system` 域（LaunchDaemon）和 `user` 域天然不依赖登录**；只有 `login`/`gui` 域（对应 `LimitLoadToSessionType=Aqua` 的传统 Agent）才绑定 GUI 登录会话。若内核要在"用户没登录 GUI（比如只用 SSH，或 Fast User Switching 切到别的账户）"时也能跑，选 `system` 域的 LaunchDaemon，或 `user` 域（非 `login`/`gui`）的 Agent。

### 1.3 按需拉起：Sockets / WatchPaths / QueueDirectories

本机 `man 5 launchd.plist` **【实测】**，`Sockets` key 原文：

> "This optional key is used to specify launch on demand sockets that can be used to let launchd know when to run the job. The job must check-in to get a copy of the file descriptors using the `launch_activate_socket(3)` API."

Socket 支持 `SockFamily=Unix` + `SockPathName`，即**本仓库已经在用的 UDS server 模式天然支持 launchd socket activation**——第一个连接到 socket 的客户端会把 launchd 尚未启动的 daemon 拉起来，这正是 systemd socket activation 在 launchd 世界的等价物（launchd 早于 systemd，此机制是 Apple 原创，2005 年随 Mac OS X 10.4 引入，来源同 TN2083 的历史背景段落）。

其余按需触发键：`WatchPaths`（路径变更触发，man page 明确 **不推荐**："filesystem event monitoring is highly race-prone"）、`QueueDirectories`（目录非空时触发并保持存活）、`StartInterval`/`StartCalendarInterval`（定时）。**【实测，本机 man page 原文】**

### 1.4 KeepAlive 常驻与崩溃自愈

本机 `man 5 launchd.plist` **【实测】**：

> `KeepAlive <boolean or dictionary>` — 默认 `false`（仅按需启动）；设 `true` 无条件常驻；也可用字典细化条件，包括：
> - `SuccessfulExit <boolean>` — "If true, the job will be restarted as long as the program exits...with an exit status of zero."（隐含 `RunAtLoad=true`）
> - `Crashed <boolean>` — "If true, the job will be restarted as long as it exited due to a signal which is typically associated with a crash (SIGILL, SIGSEGV, etc.)."
> - `PathState`/`OtherJobEnabled` — 文件系统信号量/其他 job 联动，man page 明确警告 race-prone，"highly discouraged"。

节流（防止崩溃循环耗尽资源）：`ThrottleInterval <integer>` — "jobs will not be spawned more than once every 10 seconds"（默认值），可调大调小。**【实测】** 社区补充：反复崩溃会被 launchd 判定为异常并暂停重启（Creating Launch Daemons and Agents 原文："If your daemon shuts down too quickly after being launched, launchd may think it has crashed. ... To avoid this behavior, do not shut down for at least 10 seconds after launch."）**【文档】**。

结论：**launchd 原生就是完整的崩溃自愈方案**（`KeepAlive.Crashed` + `ThrottleInterval`），不需要额外的看门狗层；这与本仓库现状"崩溃自愈由 GUI 宿主承担"是两种不同的实现路径，headless 化后可以直接把这层责任移交给 launchd 本身。唯一要注意的行为：`KeepAlive` 隐含 `RunAtLoad`，即 daemon 会在 plist 被 load 时立即尝试起一次——需要确认 04 票裁的常�instant启动语义能否接受这一点。

### 1.5 日志去向

`StandardOutPath`/`StandardErrorPath` 可显式指定重定向文件路径 **【实测，本机 man page】**。未设置时的历史行为（TN2083 原文）**【文档】**：

> "Prior to Mac OS X 10.5, your program's stdout and stderr will be connected to /dev/null. In Mac OS X 10.5 and later, launchd will capture any output to these streams and redirect it to ASL [Apple System Log]."

现代 macOS（Big Sur 起）ASL 已被 unified logging（`os_log`/`log show`）取代，但 launchd 对未设置 `StandardOutPath` 时是否仍旧兜底捕获进统一日志、还是回落 `/dev/null`，本次调研没有找到 Apple 现行文档逐字重申——**这条标【推断，需 04 票后 spike 实测验证】**：建议内核不依赖这层隐式行为，显式设置 `StandardOutPath`/`StandardErrorPath` 或自行走 `os_log`，不要假设"什么都不配置也能在 Console.app 里看到日志"。

### 1.6 `SMAppService` 的边界，与裸 bin 的独立注册路径

`SMAppService`（macOS 13 Ventura 引入，取代 `SMJobBless`/`SMLoginItemSetEnabled`）的核心约束，来自 Apple 官方文档摘要与社区技术笔记交叉印证 **【文档】**：

> "Launch daemons and their associated plist files are expected to be within the application bundle itself" —— 具体是 `Contents/Library/LaunchDaemons`（daemon）/ `Contents/Library/LaunchAgents`（agent），不会被挪到 `/Library/Launch*`。

— 来源：[SMAppService | Apple Developer Documentation](https://developer.apple.com/documentation/servicemanagement/smappservice)、[macOS Service Management - The SMAppService API](https://theevilbit.github.io/posts/smappservice/)、Apple Developer Forums 相关帖（[installing a SMAppService based LaunchDaemon](https://developer.apple.com/forums/thread/771162)）。

**本机 man page 给出了决定性的一条交叉证据**（`man 5 launchd.plist`，`BundleProgram` key）**【实测】**：

> `BundleProgram <string>` — "This key maps to the first argument of execv(3) and is an app-bundle relative path to the executable for the job. **This key is only supported for plists that are installed using SMAppService.**"
> `Program <string>` — "...This key is required in the absence of the ProgramArguments and BundleProgram keys."

即：**`BundleProgram`（app-bundle 相对路径）是 `SMAppService` 专属的新键；传统的 `Program`/`ProgramArguments`（绝对路径）完全独立存在，从来没有被废弃**。裸 bin 走的正是后者：把可执行的绝对路径写进 `Program`，plist 手装到 `/Library/LaunchDaemons`（或 `~/Library/LaunchAgents`），执行

```
sudo launchctl bootstrap system /Library/LaunchDaemons/<label>.plist   # 系统级
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/<label>.plist      # 用户级
```

本机 `man 1 launchctl` 逐字确认这条子命令的存在与语义（"Bootstraps or removes domains and services... Paths may point to XPC service bundles, launchd.plist(5)s, or a directories containing a collection of either."）**【实测】**。这条路径今天（macOS 15）**仍然是官方 man page 记录在案、未标废弃的一等公民路径**，`tailscaled install-system-daemon`（见 §2.1）就是这条路径的真实先例。

**权限与授权流程差异（这是 SMAppService 存在的真正意义）**：

| | 裸 bin + `launchctl bootstrap`（传统路径） | `SMAppService`（新 API） |
|---|---|---|
| 是否要求 `.app` bundle | 否 | 是（plist 必须内嵌 bundle 内） |
| 用户授权 UI | 无内建授权流程；LaunchDaemon 靠 `sudo` 一次性获得 root，之后静默常驻 | 用户需在「系统设置 → 登录项与扩展」批准，daemon 场景还会二次弹认证（因为装 daemon 本身要 root） |
| 卸载/清理 | 手动 `launchctl bootout` + 删 plist；系统不追踪来源 | 系统统一管理，应用卸载时随 bundle 一起失效更干净 |
| 命令行可编排性 | 完全可编排（CLI 首次调用时自装 plist 是可行的工程模式） | Apple Developer Forums 上工程师原话（[thread 771162](https://developer.apple.com/forums/thread/771162)）："SMAppService 的设计目的是由应用程序调用，不是直接的 CLI 工具"；**没有 CLI 方式绕过用户交互批准环节**——首次注册必须有人在 GUI 里点一下 |

**对 04 票的直接输入**：如果内核要做到"CLI 首次调用时自拉起 daemon、全程零 GUI 交互"，`SMAppService` 这条路本身就与该目标冲突（它设计上要求至少一次 GUI 批准）；**唯一与"agent-first、CLI 唯一必需交互面"自洽的路径是裸 bin + 手装 plist + `launchctl bootstrap`**——用户执行 `aa` 某个子命令时若检测到 daemon 未注册，由 `aa` 自己写 plist 到 `~/Library/LaunchAgents`（用户级不需要 root，`system` 级 LaunchDaemon 才需要 `sudo`/权限提示）并 `launchctl bootstrap` 一次即可，全程在终端完成，无需 Finder、无需 `.app`。

**已知的现实坑（社区报告，非官方文档，中等确定性）** **【推断】**：macOS Sonoma 起，`launchctl bootstrap` 偶发返回 `"Bootstrap failed: 5: Input/output error"`，多个开发者论坛帖子（[developer.apple.com/forums/thread/748205](https://developer.apple.com/forums/thread/748205)、[thread/768324](https://developer.apple.com/forums/thread/768324)）报告与 plist 文件属主/权限（需 `root:wheel`、`644`）、以及沙盒签名有关；没有 Apple 官方文档给出根因，属于"能用但偶有摩擦"的状态，04 票若定这条路径需预留排障预算。

---

## 2. 先例拆解：daemon + CLI + 可选 GUI 的真实拓扑

### 2.1 tailscaled（Tailscale）

Tailscale 官方文档明确列出 **macOS 上三种拓扑** **【文档】**（来源：[Three ways to run Tailscale on macOS](https://tailscale.com/docs/concepts/macos-variants)）：

1. **App Store 版**：GUI app + sandboxed Network Extension，两个沙盒进程，功能受沙盒限制。
2. **独立 App（Standalone）版**：GUI app + System Extension（root 权限但仍受系统级沙盒），功能最完整，不经 App Store 审核所以更新更快。
3. **开源 `tailscaled` + CLI（无 GUI）**：原文 "does not include a graphical user interface (GUI); all functionality must be managed from the command line"，官方定位是 **"only recommended for unattended installs managed by experienced macOS system administrators"**。

第三种形态的常驻机制，来自官方 [tailscaled daemon 参考文档](https://tailscale.com/docs/reference/tailscaled) **【文档】**：

> "On macOS, `tailscaled` (when not using a GUI build, as mentioned above) runs as a `launchd` service."

且社区/官方 wiki 记录了具体安装子命令 **【推断，来自 GitHub wiki 交叉印证，非 tailscale.com 一手文档逐字确认，但与 §1.6 的裸 bin 路径完全吻合】**：`sudo tailscaled install-system-daemon` 会把二进制拷到 `/usr/local/bin`、写 plist 到 `/Library/LaunchDaemons/com.tailscale.tailscaled.plist` 并 `bootstrap` 启动——**这是本调研中"CLI 子命令自行完成 daemon 注册"最直接的真实先例**，与 §1.6 结论完全吻合。

CLI（`tailscale`）与 `tailscaled` 的 IPC 细节本次未取得官方文档逐字确认（一手文档只写了 launchd 常驻本身，未展开 socket 路径），**标【未验证/待补】**：社区代码走向普遍认知是本地 Unix socket（`/var/run/tailscaled.socket` 一类路径），但未在本次调研中逐字核对 tailscale 源码，不作为定论引用。

### 2.2 colima / lima

Lima 提供 Linux VM，Colima 是其上层的容器运行时封装 **【推断，来自社区技术文章交叉引用，非项目一手文档逐字确认】**。launchd 集成方式（来源：[colima issue #1346](https://github.com/abiosoft/colima/issues/1346) 与 [colima.run FAQ](https://colima.run/docs/faq/)）：

- Colima **前台模式**（`colima start -f`）被设计为可以直接塞进 launchd agent 的 `ProgramArguments`，前台运行以便正确接收 launchd 发的 `SIGTERM`（这与 §1.4 man page "SHOULD handle SIGTERM" 的要求对应）。
- GUI 完全缺席，Colima 从来没有官方 GUI；纯 CLI + launchd agent 的拓扑，用户手动写 plist 或用 `brew services start colima`。

### 2.3 Ollama

官方 macOS 发行版是 **GUI app（含菜单栏图标）**，双击安装后常驻；社区文档描述其 launchd 集成方式为**用户自行**写 plist 跑 `ollama serve`（非官方内建）**【推断，来自社区教程，非 Ollama 官方文档】**（来源：[Setting Up Ollama as a Background Service on macOS](https://medium.com/@anand34577/setting-up-ollama-as-a-background-service-on-macos-66f7492b5cc8)）。一个值得注意的运维细节：launchd 启动的进程不读 shell profile，环境变量必须用 `launchctl setenv` 显式传递——这是所有 launchd 常驻服务的共性坑，不止 Ollama 特有，内核 bin 化后若依赖任何环境变量配置也要走这条路径而非 `.zshrc`。第三方 GUI（如 "Ollama Bar"）作为独立菜单栏客户端存在，印证"GUI 是可选、可替换客户端"这一拓扑模式的可行性。

### 2.4 syncthing

两条路径并存，无强制先后关系 **【文档，来源官方 autostart 文档】**（[Starting Syncthing Automatically](https://docs.syncthing.net/users/autostart.html)）：

- **daemon 路径**：`brew services start syncthing`，Homebrew 生成 `~/Library/LaunchAgents/homebrew.mxcl.syncthing.plist` 并 `launchctl` 管理；控制面是内置 Web GUI（`127.0.0.1:8384`），浏览器即客户端，不需要任何原生应用。
- **原生 GUI 路径**：官方维护一个独立的 macOS `.app` wrapper，纯粹是"把网页套一层原生壳 + 登录自启选项"，功能上不比直接开浏览器多什么。

这是"GUI 纯粹是可选客户端、且用 Web/CLI 也能覆盖 100% 功能面"的一个干净先例。

### 2.5 OrbStack

官方 headless 文档明确 **【文档】**（[Command line & CI usage](https://docs.orbstack.dev/headless)）：

> "OrbStack can be used exclusively from the command line, without the GUI app... This is useful for CI, automation, and headless servers."
> 唯一缺口："Auto-update is currently not supported without the GUI. This should not be an issue for CI environments."（需手动 `brew upgrade --greedy orbstack`）

值得记录的张力：2023 年有用户在 [issue #194](https://github.com/orbstack/orbstack/issues/194) 请求"像 Tailscale 一样支持纯 daemon 模式"，该 issue 最终标记 **"not planned"** 关闭，但官方后续仍然上线了上述 headless 文档——**说明"headless 可用"与"官方长期支持无 GUI 生命周期管理"是两件事**：当前 OrbStack 的 headless 能力更像"GUI 装过一次之后，daemon 可以不靠 GUI 常驻运行"，而不是"从未装过 GUI 也能独立生成 daemon"。**这条张力本次调研未找到该 issue 完整评论区（维护者回复）逐字核实，标【推断，需要 04 票视需要再核实】**——如果 04 票要援引 OrbStack 作为"纯裸 bin 也能完整拉起 daemon"的先例，建议不要照单全收，先确认这条边界。

### 2.6 mihomo 自身（对照组，已有一手调研）

`docs/research/mihomo-integration.md` §2「进程管理」已用源码（`main.go`）实测/确认 **【文档，转引已有调研，未重复验证】**：mihomo 内核**没有任何守护、重启、单实例锁或端口探测逻辑**——它就是最纯粹的"裸前台进程 + 外部 REST controller"，进程存活、崩溃重启、常驻形态**完全是壳的责任**，内核自己不管。这与 §2.5 OrbStack 的"内核层不管生命周期，交给上层（launchd 或调用方）"是同一模式；与本仓库现有 `AAHostRuntime` 管 mihomo 生命周期的现状一致。

Homebrew 生态上，`mihomo` 有[官方 formula](https://formulae.brew.sh/formula/mihomo)（`brew install mihomo`），按 Homebrew 政策 **formula 必须"build from source or install portable output"**（来源：[Homebrew Acceptable Formulae](https://docs.brew.sh/Acceptable-Formulae)）**【文档】**——即 Homebrew 分发 mihomo 时用户拿到的要么是本地编译产物、要么其"源码"就是 formula 脚本本身指向的官方 tag，GPL 源码获取义务在这条分发链路上是自然满足的（细节见 §4）。

### 2.7 归纳

| | 谁装 daemon | 谁拉起谁 | GUI 缺席时功能面 | IPC |
|---|---|---|---|---|
| tailscaled 无头变体 | CLI 子命令自装 plist | launchd（`system` 域） | 100%（官方定位就是给无 GUI 场景用） | 本地 socket（细节未核实） |
| colima | 用户/`brew services` 写 plist | launchd（agent，前台模式） | 100%（从无 GUI） | Docker socket 转发 |
| Ollama | 用户手装（非官方内建）或双击 GUI app | launchd 或 GUI app | 100%（`ollama serve` 本身就是全部功能） | `127.0.0.1` REST |
| syncthing | `brew services`（agent）或官方 `.app` | launchd 或 GUI app 自拉起子进程 | 100%（Web GUI 本就是控制面） | `127.0.0.1` REST/Web |
| OrbStack | 官方安装器（含 GUI 一次性引导） | GUI 首次装，之后 headless 可脱离 | 除自动更新外 100% | forwarded socket |
| mihomo 自身 | 壳负责（无自带机制） | 壳的 Process API | N/A（内核本无 GUI 概念） | UDS / `127.0.0.1` REST（`-ext-ctl-unix`） |

结论：**没有一个先例要求"必须先跑 GUI 才能有 daemon"作为长期稳态**（OrbStack 是最接近的例外，且这条例外本身有争议，见 §2.5）；**IPC 选型清一色是 UDS 或 loopback REST**，只有触达 Apple 私有网络扩展框架（Network Extension/System Extension，本项目明确不做 TUN）时才会引入 XPC/系统级授权流程。本仓库现有的 UDS server 模式与整个生态的通行做法一致，headless 化不需要换 IPC 机制。

---

## 3. 裸 bin 与 `.app` 在 Gatekeeper / 公证 / quarantine / TCC 上的差异

### 3.1 Gatekeeper 触发条件：只认 quarantine 标记

社区高质量来源（Howard Oakley《The Eclectic Light Company》，macOS 安全领域公认权威二手来源，本次未找到 Apple 官方文档逐字重申此机制细节，标 **【推断/高质量二手】**）：

> "When an app has its quarantine flag set, it undergoes full first run checks by Gatekeeper. ... If you say yes, the quarantine flag is cleared, and the app doesn't have to go through first run checks again."

— 来源：[App first run, quarantine and translocation](https://eclecticlight.co/2022/09/09/app-first-run-quarantine-and-translocation/)、[Explainer: Quarantine](https://eclecticlight.co/2021/12/11/explainer-quarantine/)

更关键的一条（HackTricks 安全知识库，社区共识，**【推断】**，未逐字核对 Apple 源码/文档）：

> "Gatekeeper only verifies executables which are run with the `open` command or the user double-clicks on first run, and it won't verify files that are executed through other means like directly executing a binary `./myapp` regardless of the quarantine attribute."

— 来源：[macOS Gatekeeper / Quarantine / XProtect - HackTricks](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-gatekeeper.html)

**若此条属实**（社区高度一致但非 Apple 一手确认），对内核裸 bin 化是重要利好：CLI 场景下用户是**直接执行**（`./aa` 或 PATH 里的 `aa`），而不是走 Finder 双击/`open`，Gatekeeper 的"first run"评估链路可能根本不触发（不论有没有 quarantine 标记）。这与本仓库 13 票已实测的"ad-hoc `.app` 双击会被 `spctl` reject"形成对照——**同一签名状态下，`.app` 的双击路径过不了，但裸 bin 的终端执行路径可能压根不过 Gatekeeper 这一关**。这条结论建议 04 票采纳前先做一次本机 spike 实测（本票未做，因为需要真正下载/构造一个带 quarantine 标记的裸可执行体来验证，属于新实测，超出本票"文档调研"范围）。

### 3.2 quarantine 标记的来源：curl/Homebrew 不打标

多方来源交叉确认（Homebrew Cask 官方 issue 讨论）**【文档，转引官方项目讨论】**：

> "Homebrew uses curl as its download strategy... curl does not set the [quarantine] attribute... No Homebrew user is covered by quarantine protection."

— 来源：[Add quarantine attribute to downloads · Issue #22388](https://github.com/Homebrew/homebrew-cask/issues/22388)、[Deprecation of --no-quarantine flag discussion](https://github.com/orgs/Homebrew/discussions/6537)

浏览器下载（Safari/Chrome）会打 `com.apple.quarantine`；`curl`/大多数命令行下载工具不会。本仓库自己的实测（13 票，见 `docs/runbooks/signing-and-authorization.md` §6.1）也确认：**本地构建的 `.app` 不带 quarantine（只有 `com.apple.provenance`）**，人工打上 quarantine 后 `spctl` 判定不变（仍 reject）、但 `codesign --verify --strict` 仍通过——**quarantine 与签名有效性是独立的两件事**，这条本仓库已实测的结论同样适用于裸 bin。

### 3.3 独立可执行体的公证限制

Apple 官方文档（[Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)，已被 `docs/research/mihomo-integration.md` §5 引用）确认公证要求 Developer ID 证书 + hardened runtime + secure timestamp。二手技术文章（Scripting OS X，长期被 macOS 打包社区当作可靠参考）补充了**裸可执行体特有的限制** **【推断/高质量二手】**：

> "If your app is a standalone Mach-O executable, you're completely done! This is because it's not possible to staple tickets to standalone executables. In this case, Gatekeeper will find the ticket online when the user runs the tool (assuming internet connectivity)."

— 来源：[Notarize a Command Line Tool – Scripting OS X](https://scriptingosx.com/2019/09/notarize-a-command-line-tool/)

含义：即使未来内核 bin 真的走 Developer ID + 公证这条路（Phase 3 议题，本票不判断时点），**裸可执行体无法像 `.app` 一样把公证票据 staple 进产物本身**——Gatekeeper 校验裸 bin 的公证状态时需要联网查询 Apple 服务器，离线首次运行会失败（`.app` staple 后离线也能过）。这是"裸 bin 分发"相对"`.app` 分发"在**未来若要正式公证**时的一条真实劣势，04 票若考虑长期分发形态应记入权衡。

### 3.4 TCC：路径记账 vs bundle identifier 记账

社区技术讨论（结合 macOS TCC 数据库结构的公开分析）**【推断，非 Apple 官方文档逐字确认，但与本仓库 13 票已实测的 ad-hoc cdhash 机制高度吻合】**：

> "TCC uses a `client_type` column where 0 indicates a bundle and 1 indicates an executable_path... For a bare (non-bundle) executable, TCC keys the grant by absolute path."
> "macOS does not offer a non-MDM way to grant TCC by code-signing requirement to a bare CLI binary."

— 来源：GitHub 讨论与 Apple Developer Forums 交叉引用（[How does TCC rely on the bundle ID esp. with multiple targets?](https://developer.apple.com/forums/thread/698337)）

对照本仓库 13 票已实测的结论（`docs/runbooks/signing-and-authorization.md` §5）：ad-hoc `.app` 下，TCC 授权按 Designated Requirement（本质是 cdhash）记账，**任何重新编译都会作废授权**。裸 bin 若同样按绝对路径记账，则叠加了**第二层不稳定性**——路径变化（版本号进路径、Homebrew 升级换 Cellar 版本目录等常见模式）本身就会使授权失效，与"内容变化（cdhash）"是两个独立的失效触发器。**结论（§0 已给出，此处是依据）**：内核若完全不碰 TCC 敏感能力（通知中心之外，本项目 GPL 义务与内核控制面走的都是 REST/CLI，不涉及 TCC），这条差异不影响 04 票裁决；若未来要加通知/自动化能力，裸 bin 形态需要专门设计"稳定路径"（如 symlink 一个不带版本号的固定路径）来缓解。

### 3.5 对本仓库现状的启示

`docs/runbooks/signing-and-authorization.md` 记录的现状是「Phase 1 = 本机自用 + ad-hoc 签名 + 手工组 `.app`」。裸 bin 化不会让这个现状变得更差或更好——**两者在"过线上 Gatekeeper 评估"这件事上本来就都不合格**（ad-hoc 缺证书链、都缺公证票）；真正的差异点是：

1. **绕过路径的操作成本不同**：`.app` 被 Gatekeeper 拦下时，用户有「系统设置 → 隐私与安全性 → 仍要打开」这条 GUI 兜底路径；裸 bin 若真的触发评估（§3.1 待验证），用户能做的是 `xattr -d com.apple.quarantine` 或 `spctl --add`，都需要终端，对"完全不装 GUI 壳"的用户反而更自然（本来就在终端里）。
2. **Homebrew 分发**本身对内核 bin 是现成可用的分发信道，且如 §3.2 所述，Homebrew 的下载路径天然不打 quarantine，规避了 §3.1/§3.3 讨论的大部分摩擦——但要注意 Homebrew 近期treated Cask 更严（[Homebrew no longer allows bypassing Gatekeeper for unsigned/unnotarized software](https://www.weaving.news/news/019a7a17-7132-71ef-bdf2-1ad29c64432b)，2026 年的政策变化），**这条收紧目前只影响 Cask（`.app`/`.pkg` 类图形化分发），不影响 Formula**（源码构建或官方 tarball 直装的命令行工具），来源：[Homebrew formula vs cask 政策讨论](https://github.com/Homebrew/brew/issues/20755)。即：**如果内核走独立裸 bin 分发，Homebrew Formula 路线目前受到的签名合规压力明显小于走 `.app`/Cask 路线**——这是支持"内核裸 bin 化 + Homebrew 分发"的一条积极信号，但政策仍在变动中，04 票裁决时建议以 Homebrew 官方文档当时的最新状态为准，不要把本票这条时间戳固化为长期结论。

---

## 4. GPL 子进程（mihomo）打包位置对 ADR 0007 义务的影响

### 4.1 现状回顾

[ADR 0007](../adr/0007-mihomo-subprocess-gpl-compliance.md) 的决定（结合 `docs/research/mihomo-integration.md` 的一手调研）：mihomo 作为 `PluginProxy` 私有资源随 `.app` 打包，构建链统一重签、随 app 公证；**义务履行位置写的是"关于页/发布说明"**。这是在"UI 是常驻必需面"的前提下做出的自然选择——GUI 宿主本来就有一个"关于"入口。

### 4.2 打包位置本身：不影响 GPL 分类结论

`mihomo-integration.md` §6 已用 FSF GPL FAQ 原文确认（[MereAggregation](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation)、[GPLInProprietarySystem](https://www.gnu.org/licenses/gpl-faq.en.html#GPLInProprietarySystem)）：判定"是否构成同一程序"的标准是**通信语义的耦合程度**（pipe/socket/命令行参数 = separate programs 的证据），与**文件在磁盘上放在哪个目录**无关。因此：

- 内核 bin 旁挂 `mihomo` 可执行（同级目录）；
- 或运行时从独立 URL 下载 mihomo 到数据目录；
- 或用户自行 `brew install mihomo` 后内核只是 `exec` 一个 PATH 里的路径；

**这三种打包位置在"是否触发 copyleft 传染"这条红线上是等价的**——只要仍然是独立子进程 + REST/CLI 通信，都留在 arms-length 一侧。**【推断，直接沿用 mihomo-integration.md 已有的中高确定性结论，本票不重新论证，只论证"打包位置"这一新变量不改变该结论】**

### 4.3 真正被 headless 拓扑动摇的：义务的呈现位置

ADR 0007 的两项硬义务——「附 GPL-3.0 文本」「提供源码获取途径」——原本挂在"关于页"，这是一个 **UI 概念**。一旦 UI 降为可选壳（本效fort的前提），必须回答："一个从未装过 UI 壳、只用 `aa` 的用户，怎么才能看到这两项义务的履行？"

三个候选落点，按实现成本排序：

- **候选 A：CLI 子命令**（如 `aa about` / `aa license`）直接打印 GPL 全文摘要 + mihomo 版本 + 源码获取链接。优点：与 ADR 0005"CLI 是最高必需交互面"的宗旨完全自洽，agent-first 拓扑下必然存在。**【推断，基于 ADR 0005/0007 原文的直接推论】**
- **候选 B：静态文本文件**，随内核 bin 同目录落一份 `LICENSES/mihomo-GPL-3.0.txt` + 版权声明/来源指引（build 时机械生成，纯文件系统层面，不需要运行任何程序即可读到）。FSF GPL FAQ 本身对"随分发提供"的呈现形式没有限定——文件旁附与网页呈现在 GPL 合规意义上是等价的。**【推断，依据是 FSF FAQ 原文对呈现形式未作限定，属合理延伸而非另有一手来源逐字确认】**
- **候选 C：借力 Homebrew 生态**（若走 Homebrew 分发内核 bin）：mihomo 官方已有 Homebrew formula 且遵循"build from source"政策（见 §2.6），若最终选择让内核依赖用户自行 `brew install mihomo`（而非随内核 bin 打包），则"mihomo 本身的源码获取义务"在这条分发链路上由 Homebrew 生态自然满足。**但这不能替代宿主分发物自身的义务**——ADR 0007 原文的逻辑是"义务不因宿主开源与否而消失"，同理也不因"内核依赖的 mihomo 恰好能从别处装到"而消失：只要宿主的发布物（内核 bin 本身或其安装说明）里包含/驱动了 mihomo 这个 GPL 组件，宿主分发物层面仍需独立完成"附文本 + 源码指引"两项义务，不能把责任转嫁给 Homebrew。**【推断，基于 ADR 0007 原文逻辑延伸】**

### 4.4 对 04 票的建议输入

打包位置这个变量本身**不需要**04 票重新裁决 GPL 分类问题（§4.2 已经说明与位置无关）；**需要**04 票裁决的是把"义务呈现"钉成一条硬约束——建议：**候选 A + 候选 B 同时做**（CLI 子命令是给交互场景看的，静态文件是给"连 CLI 都懒得跑、直接看 bin 旁边有什么"的场景兜底，两者成本都很低），并写进 04 票的裁决或直接修订 ADR 0007，把"关于页"改为"关于页（若 UI 存在时）/ `aa about` 子命令 / 随包静态文件（至少一条必须始终存在）"。

---

## 对 04 票裁决的输入摘要

1. **常驻形态选型不受 `SMAppService` 限制**：裸 bin 走 `Program`/`ProgramArguments` + 手装 plist + `launchctl bootstrap` 是官方 man page 记录在案的一等公民路径，tailscaled 是真实先例；`SMAppService` 反而因为要求至少一次 GUI 授权交互，与"CLI 首次调用零 GUI 自拉起"的目标冲突，**不建议采用**。
2. **常驻域三选一，按"是否要求人登录"分层**：不依赖登录 → `system` 域 LaunchDaemon（root，需 `sudo` 装一次）；用户级但不依赖 GUI → `user` 域 Agent；依赖 GUI 会话 → `gui`/`login` 域（传统 `LimitLoadToSessionType=Aqua`）。建议默认选 **`user` 域 LaunchAgent**（无需 root、不强制 GUI），除非有明确的"用户未登录也要跑"的需求。
3. **崩溃自愈可以直接甩给 launchd**（`KeepAlive.Crashed` + `ThrottleInterval`），不需要在应用层重新发明看门狗；这部分职责可以从"现由 GUI 宿主承担"直接迁移到 plist 配置，与常驻形态选型是同一批工作。
4. **IPC 沿用现有 UDS 方案完全合理**：全行业先例（tailscaled/mihomo/OrbStack）都用 UDS 或 loopback REST；UDS 还额外能吃 launchd 的 socket activation（按需拉起）。
5. **签名/分发现状不因裸 bin 化而变差**：现状（ad-hoc `.app`）本就过不了线上 Gatekeeper，裸 bin 同样过不了；但裸 bin 若走 Homebrew Formula（非 Cask）分发，目前受到的平台合规压力明显更低，且终端直接执行可能压根不触发 Gatekeeper 首次评估链路（§3.1，建议 04 票前做一次本机 spike 实测确认这条）。TCC 层面裸 bin 比 `.app` 更脆弱（双重记账：路径 + 内容），但仅在内核触碰 TCC 敏感能力时才相关——当前控制面（REST/CLI）不触碰。
6. **GPL 义务必须挂一条不依赖 UI 的落点**：建议 04 票（或直接修订 ADR 0007）把"CLI 子命令 + 随包静态文本文件"钉为至少一条必须始终存在的义务呈现路径，"关于页"降级为"有 UI 时的锦上添花"，避免出现纯 CLI 用户从未见过 GPL 声明的合规缺口。打包位置本身（内核 bin 旁挂 vs 独立下载/依赖 Homebrew）不改变 GPL 分类结论，只改变义务呈现的工程实现。

---

## 附：来源清单

**Apple 官方文档 / 本机 man page（实测环境：macOS 15.7.8 / 24G824）**

- [Technical Note TN2083: Daemons and Agents](https://developer.apple.com/library/archive/technotes/tn2083/_index.html)
- [Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- 本机 `man 5 launchd.plist`（`Sockets`/`KeepAlive`/`RunAtLoad`/`ThrottleInterval`/`LimitLoadToSessionType`/`Program`/`BundleProgram`/`StandardOutPath`/`StandardErrorPath` 等 key 定义）
- 本机 `man 1 launchctl`（`bootstrap`/`bootout`/domain-target 模型：`system`/`user`/`login`/`gui`/`pid`）
- [SMAppService | Apple Developer Documentation](https://developer.apple.com/documentation/servicemanagement/smappservice)
- Apple Developer Forums：[installing a SMAppService based LaunchDaemon](https://developer.apple.com/forums/thread/771162) · [launchctl I/O error on sandbox](https://developer.apple.com/forums/thread/748205) · [LaunchDaemon not loading after Sonoma update](https://developer.apple.com/forums/thread/768324) · [TCC bundle ID discussion](https://developer.apple.com/forums/thread/698337)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)（已在 `mihomo-integration.md` 引用）

**工具官方文档/源码**

- Tailscale：[Three ways to run Tailscale on macOS](https://tailscale.com/docs/concepts/macos-variants) · [tailscaled daemon reference](https://tailscale.com/docs/reference/tailscaled)
- Colima：[FAQ](https://colima.run/docs/faq/) · [issue #1346](https://github.com/abiosoft/colima/issues/1346) · [issue #490](https://github.com/abiosoft/colima/issues/490)
- Syncthing：[Starting Syncthing Automatically](https://docs.syncthing.net/users/autostart.html)
- OrbStack：[Command line & CI usage](https://docs.orbstack.dev/headless) · [Architecture](https://docs.orbstack.dev/architecture) · [issue #194](https://github.com/orbstack/orbstack/issues/194)
- mihomo：[formulae.brew.sh/formula/mihomo](https://formulae.brew.sh/formula/mihomo)；进程管理事实转引自本仓库 `docs/research/mihomo-integration.md` §2/§6/§7（未重复验证，直接复用其一手结论）
- Homebrew：[Acceptable Formulae](https://docs.brew.sh/Acceptable-Formulae) · [homebrew-cask issue #22388（quarantine）](https://github.com/Homebrew/homebrew-cask/issues/22388) · [Deprecation of --no-quarantine discussion](https://github.com/orgs/Homebrew/discussions/6537) · [issue #20755（Cask Gatekeeper 收紧）](https://github.com/Homebrew/brew/issues/20755) · [Homebrew no longer allows bypassing Gatekeeper 报道](https://www.weaving.news/news/019a7a17-7132-71ef-bdf2-1ad29c64432b)

**高质量二手来源（macOS 安全/打包社区，未逐字对照 Apple 一手文档，标注为【推断】的条目多引自此类来源）**

- The Eclectic Light Company：[App first run, quarantine and translocation](https://eclecticlight.co/2022/09/09/app-first-run-quarantine-and-translocation/) · [Explainer: Quarantine](https://eclecticlight.co/2021/12/11/explainer-quarantine/)
- [macOS Gatekeeper / Quarantine / XProtect - HackTricks](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-gatekeeper.html)
- [Notarize a Command Line Tool – Scripting OS X](https://scriptingosx.com/2019/09/notarize-a-command-line-tool/)
- [macOS Service Management - The SMAppService API – theevilbit blog](https://theevilbit.github.io/posts/smappservice/)
- [Setting Up Ollama as a Background Service on macOS](https://medium.com/@anand34577/setting-up-ollama-as-a-background-service-on-macos-66f7492b5cc8)

**本仓库既有文档（转引，未重复验证的部分已在正文标注）**

- [ADR 0007](../adr/0007-mihomo-subprocess-gpl-compliance.md)
- [docs/research/mihomo-integration.md](mihomo-integration.md)（§2 进程管理、§5 打包与分发、§6 合规、§7 版本策略）
- [docs/runbooks/signing-and-authorization.md](../runbooks/signing-and-authorization.md)（§2 cdhash 机制、§5 TCC 失效表、§6.1 quarantine/Gatekeeper 实测）
