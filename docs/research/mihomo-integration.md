# mihomo 集成面与合规调研（代理插件 V1）

> 调研日期：2026-07-28（对应票：`.scratch/v1-mac-recharter/issues/02-mihomo-integration-survey.md`）  
> 对象版本：mihomo v1.19.29（2026-07-18 发布）；本机实测二进制为 v1.19.28 darwin arm64  
> 资料原则：事实引一手来源（mihomo 官方 wiki 与源码、三个现有壳的源码、Apple 文档/本机 man page、GNU/FSF 官方 FAQ）；法律类问题给分析与建议并标注确定性，不假装定论。

## 0. 结论摘要

1. **不做 TUN 时，可以完全避开特权助手。** 系统代理只需以当前用户身份调用 `networksetup`；Apple man page 原文是"requires at least admin privileges to change network settings"——即调用者是管理员账户（macOS 首账户默认即是）就够，无需 root、无需助手。Clash Verge Rev 正是这么做的（无任何特权组件，直接 shell 出 `networksetup -setwebproxy` 等）。ClashX Meta 与 Clash Party 用特权组件的动机是覆盖**标准（非管理员）账户**、免交互恢复设置，以及同一组件顺带服务 TUN——不是系统代理本身的硬要求。V1 需要设计的只是一个降级路径：标准账户或开启"访问系统范围设置需管理员密码"时 `networksetup` 会失败，届时提示用户（或将该场景移出 V1 支持范围）。
2. **宿主应用不必因捆绑 mihomo 而开源（中高确定性，非法律定论）。** mihomo 是 GPL-3.0（LICENSE 原文确认）。V1 的集成形态——独立二进制、子进程启动、CLI 参数 + REST/WS 通信——正是 FSF FAQ 认定"normally used between two separate programs"的通信机制，属 mere aggregation / "communicate at arms length"。义务仍然存在：随分发提供 GPL-3.0 文本与 mihomo 对应源码的获取途径，不得对 mihomo 本身附加额外限制。**红线是进程内链接**：ClashX Meta 以 `-buildmode=c-archive` 把内核静态链接进应用，因此其整个应用是 AGPL-3.0——我们绝不能走这条路线。现有三壳（AGPL-3.0 / GPL-3.0 / GPL-3.0）全部 copyleft，没有闭源壳的先例可援引；若要零风险，可把代理插件本体开源。
3. **两个栈候选下 mihomo 集成难度无实质差异。** 集成面 = spawn 子进程 + HTTP/WebSocket 客户端 + 调 `networksetup` + 文件/订阅管理，Electron（`child_process` + `fetch`/ws）与 Swift（`Process` + `URLSession`）都是标配能力，且两栈各有完整先例（Clash Party = Electron；ClashX Meta = Swift；Clash Verge Rev = Tauri）。真实差异在打包签名管线（都要给捆绑的 mihomo 重签 + hardened runtime + 时间戳 + 公证）和**将来**做 TUN/标准账户支持时——Swift 对 SMJobBless/SMAppService + XPC 是第一方工具链，Electron 则需像 Clash Party 那样自带一个独立 helper 守护进程（可行，有先例）。此调研不构成栈选择的决定性论据。

---

## 1. external controller API 面

来源：[hub/route/server.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/server.go)、[proxies.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/proxies.go)、[groups.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/groups.go)、[configs.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/configs.go)、[upgrade.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/upgrade.go)、[官方 wiki RESTful API](https://wiki.metacubex.one/api/)。

鉴权：除 `/ui`（静态面板托管）外全部端点要求 `Authorization: Bearer ${secret}`；WebSocket 端点额外接受 `?token=` 查询参数（server.go）。

V1 需要的能力全部有官方端点：

| 能力 | 端点（源码为准） |
|---|---|
| 代理/组列举 | `GET /proxies`、`GET /proxies/{name}`；`GET /group`、`GET /group/{name}`（groups.go） |
| 切换节点 | `PUT /proxies/{name}`，body `{"name": "<目标节点>"}`（proxies.go）；`DELETE /proxies/{name}` 取消 URLTest 组的手动固定 |
| 延迟测试 | 单节点 `GET /proxies/{name}/delay?url=&timeout=&expected=`；整组 `GET /group/{name}/delay`（超时返回 408） |
| 实时流（WS） | `GET /logs`、`GET /traffic`、`GET /memory`（server.go 明示支持 WS 升级）；`/connections` 连接表实时流与关闭单个/全部连接（wiki） |
| 配置 reload | `PUT /configs?force=` body `{path|payload}`（path 必须绝对路径且过安全检查；payload 直接内联配置）；SIGHUP 亦可触发重载（main.go） |
| 运行时改配置 | `PATCH /configs`：`mode`、`log-level`、`ipv6`、`allow-lan`、各端口（`port`/`socks-port`/`mixed-port` 等）、`tun` 等字段（configs.go） |
| 模式切换 | 即 `PATCH /configs` 的 `mode`（rule/global/direct） |
| 订阅/规则集管理 | `/providers/proxies`、`/providers/rules` 子路由：更新、健康检查（server.go + wiki） |
| 其他 | `GET /version`；`POST /configs/geo` 更新 GEO 库；`/restart` 重启内核（embed 模式下禁用）；`/dns` 查询；`/cache` |
| 内核自升级 | `POST /upgrade`（见 §7）、`POST /upgrade/ui` 更新面板 |

结论：**UI 壳所需的控制面 100% 由官方 REST/WS 覆盖，无需打补丁或解析日志。**

## 2. 进程管理

来源：[main.go](https://github.com/MetaCubeX/mihomo/blob/Meta/main.go)、[constant/path.go](https://github.com/MetaCubeX/mihomo/blob/Meta/constant/path.go)。

- **启动参数**（每个 flag 均可用 `CLASH_*` 环境变量替代，main.go）：`-d` 配置目录、`-f` 配置文件、`-config` base64 内联配置、`-ext-ctl` 覆盖 external controller 地址、**`-ext-ctl-unix` 以 Unix domain socket 提供控制器**、`-ext-ctl-pipe`（Windows）、`-ext-ctl-tls`、`-secret` 覆盖 API 密钥、`-ext-ui` 面板目录、`-t` 校验配置后退出、`-v` 版本、`-m` geodata 模式、`-post-up`/`-post-down` 钩子脚本。
- **配置目录约定**：默认 `$HOME/.config/mihomo`（不存在时回退 `XDG_CONFIG_HOME/mihomo`），默认配置名 `config.yaml`；`SAFE_PATHS` 环境变量扩展 API 允许读写的路径白名单（path.go）。插件应当用 `-d` 指到自己的数据目录，完全绕开全局默认目录。
- **优雅退出**：SIGINT/SIGTERM → 退出；SIGHUP → 重新解析配置（main.go）。壳侧正常终止就是发 SIGTERM。
- **崩溃重启 / 多实例互斥 / 端口冲突**：内核自身没有守护、重启、单实例锁或端口探测逻辑（main.go 中无此类处理）——这些是壳的职责。分析与先例（标注：设计建议，非上游事实）：
  - 崩溃重启：壳监听子进程退出事件后重拉即可；Clash Party 的做法更重（launchd 守护 + `launchctl kickstart -k`，见 §4）。
  - 互斥：以插件数据目录内的 pid/lock 文件自管；避免依赖全局 `~/.config/mihomo` 即可与用户自装的 mihomo/其他壳共存。
  - 端口冲突：入站端口全部显式写进受管配置并在启动前由壳探测；控制器建议直接用 `-ext-ctl-unix`（无 TCP 端口、可用文件权限管住访问面），或 `-ext-ctl 127.0.0.1:0` 之外的固定探测端口。运行中可用 `PATCH /configs` 热改端口。

## 3. 配置与订阅

来源：[官方 wiki proxy-providers](https://wiki.metacubex.one/config/proxy-providers/)、configs.go、各壳 README。

两条路径都被上游支持：

- **proxy-provider 路径（内核自管订阅）**：`type: http` 时字段包括 `url`、`interval`（自动更新秒数）、`path`（本地缓存，缺省为 URL 的 MD5）、`proxy`（"经过指定代理进行下载/更新"）、`size-limit`、`header`（自定义请求头）；`health-check`（`url`/`interval`/`timeout`/`lazy`，官方示例 `https://cp.cloudflare.com`）；`override`（改名前后缀、正则改名、UDP 等属性覆写、`override-expr` 表达式）；`filter`/`exclude-filter`/`exclude-type` 节点过滤。provider 消费的是 Clash 格式的节点列表（`proxies:` 数组），配合 `/providers/proxies` 端点可手动触发更新与健康检查。
- **完整配置路径（壳自管 profile）**：壳自行下载完整 Clash 配置文件，落盘后 `PUT /configs {path}` 热加载；Clash Verge Rev 的"配置文件管理和增强（Merge 和 Script）"即此模式（README）。
- **与 Clash 生态订阅的兼容性**：mihomo 的配置格式就是 Clash 格式的超集（项目自述"Another Clash Kernel"），机场发的"Clash 订阅"两条路径都能吃。注：机场普遍靠 `subscription-userinfo` 响应头传流量/到期信息，这属于生态约定、由壳解析展示，本次未逐一核对上游对该头的处理（低确定性，V1 实现时以壳侧解析为准）。

建议（分析）：V1 用"壳管 profile + PUT /configs"为主路径（可控、可回滚、便于展示订阅元数据），provider 作为高级用户的配置透传能力，不在 UI 里重复造轮子。

## 4. macOS 系统代理设置的真实权限要求

**Apple 侧事实**（本机 macOS 15 `man 8 networksetup`，原文）：

> "The networksetup command requires at least admin privileges to change network settings. If the "Require an administrator password to access system-wide preferences" option is selected in System Preferences > Security & Privacy, then root privileges are required to change network settings."

即：**管理员账户下无需 sudo、无需任何特权组件**即可改代理；标准账户（或开启上述安全选项）才需要提权。SystemConfiguration 框架的编程路径（`SCPreferences*`）同样受此授权模型约束——需要 root 或经 `SCPreferencesCreateWithAuthorization` 走授权，这正是壳们放特权助手的位置。

**三个壳的源码证据**：

| 壳 | 栈 | 系统代理做法 | 特权组件 | 为何 |
|---|---|---|---|---|
| [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) | Tauri 2 (Rust) | 自维护的 [sysproxy-rs fork](https://github.com/clash-verge-rev/sysproxy-rs/blob/main/src/macos.rs)：写入直接 shell 出 `networksetup -setwebproxy / -setsecurewebproxy / -setsocksfirewallproxy / -set*state / -setproxybypassdomains`，读取用 SystemConfiguration API；权限不足时返回 `Error::RequiresAdminPrivileges` | **系统代理不用任何特权组件**（服务只为 TUN，见 §8） | 证明"管理员账户 + networksetup"路径成立 |
| [ClashX Meta](https://github.com/MetaCubeX/ClashX.Meta) | Swift (AppKit) | [SystemProxyManager.swift](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX/General/Managers/SystemProxyManager.swift) 全部经由特权助手：`helper?.enableProxy(withPort:...)` / `disableProxy` / `restoreProxy`；[PrivilegedHelperManager.swift](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX/General/Managers/PrivilegedHelperManager.swift) 用 `SMJobBless(kSMDomainSystemLaunchd, "com.west2online.ClashX.ProxyConfigHelper", ...)` + `kSMRightBlessPrivilegedHelper` 授权安装，`NSXPCConnection(machServiceName:options:.privileged)` 通信 | 有（SMJobBless 助手，装一次之后免密） | 助手 [ProxyConfigHelper.m](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ProxyConfigHelper/ProxyConfigHelper.m) 暴露的 XPC 方法只有 enableProxy/disableProxy/restoreProxy/getCurrentProxySetting/getVersion——纯为代理设置而生：对标准账户也可用、改动前保存并可恢复原设置、无重复弹窗（动机为分析） |
| [Clash Party（原 Mihomo Party）](https://github.com/mihomo-party-org/clash-party) | Electron | [src/main/sys/sysproxy.ts](https://github.com/mihomo-party-org/clash-party/blob/smart_core/src/main/sys/sysproxy.ts)：Windows/Linux 用 `sysproxy-rs`；**macOS 走自家 launchd 守护 `party.mihomo.helper`**，经 Unix socket `/tmp/mihomo-party-helper.sock` 发 `POST /pac`、`POST /global`；守护失联时 `osascript -e 'do shell script "launchctl kickstart -k system/party.mihomo.helper" with administrator privileges'` 拉起 | 有（launchd system 域守护，安装/拉起需一次管理员授权） | 同一守护同时承担内核/TUN 管理（README 卖点"开箱即用，无需服务模式的 Tun"），系统代理顺路走它（动机为分析） |

**结论（高确定性）**：不做 TUN 的 V1 完全可以零特权助手——直接 `networksetup`，Clash Verge Rev 为证。需要明确的产品决定：标准账户用户怎么办（弹一次提权对话框、引导、或声明不支持）。

## 5. 打包与分发

来源：[GitHub releases API（v1.19.29 资产清单）](https://api.github.com/repos/MetaCubeX/mihomo/releases/latest)、本机实测、[Apple: Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)。

- **体积**：v1.19.29 官方压缩资产 `mihomo-darwin-arm64-*.gz` ≈ 15.9 MB、`mihomo-darwin-amd64-*.gz` ≈ 17.3 MB。解压后实测（本机 `/usr/local/bin/mihomo`，v1.19.28 darwin arm64）**43,418,754 字节 ≈ 41.4 MiB**。插件体积预算按"单架构内核 ~42 MiB（安装后）/ ~16 MB（下载压缩）"计。
- **架构**：官方 darwin 资产只有 amd64 / arm64 单架构（外加 amd64-compatible 与多个 Go 版本变体），**没有 universal 资产**；实测二进制为 `Mach-O thin (arm64)`。Mac-only 发行的两个选择：按架构出两份安装包（Clash Verge Rev / Clash Party 模式），或自行 `lipo -create` 合成 universal（ClashX Meta 对其静态库正是这么做的）——代价是包体 +~40 MiB。
- **签名现状**：官方二进制只有 Go 链接器的 ad-hoc 签名（实测 `codesign -dv`：`Signature=adhoc`、`flags=0x20002(adhoc,linker-signed)`、`Identifier=a.out`），**不能直接随应用分发**，必须用自己的 Developer ID 重签。
- **公证要求**（Apple 文档原文）："You can only notarize apps that you sign with a Developer ID certificate"；hardened runtime 是硬要求（否则报 "The executable does not have the hardened runtime enabled."）；签名须含 secure timestamp（否则报 "The signature does not include a secure timestamp."）；嵌套二进制一并校验（`codesign -vvv --deep --strict`，"the utility checks nested code content"）。落到实操：对捆绑的 mihomo 执行 `codesign --options runtime --timestamp -s "Developer ID Application: …"`，放进 app bundle 的可执行目录（`Contents/MacOS/` 或 `Contents/Resources/` 下按各栈打包器约定），随 app 一起公证并 staple；Gatekeeper 用 `spctl --assess` 预检。
- **陷阱（分析，中高确定性）**：若运行期在 app bundle 内替换内核二进制（独立更新内核），会破坏 app 的签名完整性；要做独立内核更新就必须把内核放到 bundle 外（如 `~/Library/Application Support/<app>/core/`）并对下载物自行验签/重签，见 §7。

## 6. 合规（GPL-3.0）

**事实（高确定性）**：

- mihomo 的 [LICENSE](https://github.com/MetaCubeX/mihomo/blob/Meta/LICENSE) 是 **GNU GPL v3（2007-06-29）原文**，逐字开头："GNU GENERAL PUBLIC LICENSE / Version 3, 29 June 2007 …"。
- [FSF GPL FAQ – MereAggregation](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation) 原文："**pipes, sockets and command-line arguments are communication mechanisms normally used between two separate programs. So when they are used for communication, the modules normally are separate programs.** But if the semantics of the communication are intimate enough, exchanging complex internal data structures, that too could be a basis to consider the two parts as combined into a larger program."（并明言 "This is a legal question, which ultimately judges will decide."）
- [FSF GPL FAQ – GPLInProprietarySystem](https://www.gnu.org/licenses/gpl-faq.en.html#GPLInProprietarySystem) 原文："However, in many cases you can distribute the GPL-covered software alongside your proprietary system. To do this validly, you must make sure that the free and nonfree programs **communicate at arms length**, that they are not combined in a way that would make them effectively a single program."
- 先例：ClashX Meta = **AGPL-3.0**（GitHub API 识别其 LICENSE；与其 [c-archive 静态链接内核](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX/goClash/build_clash_universal.py)（`go build -buildmode=c-archive` + `lipo`，经 [install_dependency.sh](https://github.com/MetaCubeX/ClashX.Meta/blob/master/install_dependency.sh) 进入构建链）的形态自洽——进程内链接必然触发 copyleft）；Clash Party = **GPL-3.0**；Clash Verge Rev = **GPL-3.0**。三者皆 copyleft，**不存在"闭源壳 + 捆绑 mihomo"的头部先例**。

**分析与建议**：

- V1 形态（独立官方二进制、子进程 `exec` + CLI 参数启动、REST/WS 控制、可独立替换）落在 FSF 描述的"separate programs / arms length"一侧：交换的是配置与控制指令（用户可见语义），不是"complex internal data structures"。**结论：宿主应用与其他插件不因此负 GPL 开源义务——确定性：中高。** 依据是 FSF 自己的解释与全行业普遍实践（无数闭源应用捆绑 GPL 工具），但 FSF 明说边界最终由法官裁定，且无针对此形态的判例。这不是法律意见。
- 无论宿主开不开源，**分发 mihomo 二进制本身的义务跑不掉**：附 GPL-3.0 全文与版权声明；提供对应源码的获取途径（指向所捆绑精确版本的上游 tag/commit 即可，稳妥做法是自留一份源码镜像以防上游消失）；不得对用户使用 mihomo 附加额外限制（MereAggregation 的唯一条件）。
- 工程红线（保住"aggregate"定性）：**禁止**任何进程内集成——不 cgo/c-archive、不做 N-API/dylib 封装、不静态嵌资源后内存加载执行；内核以独立文件存在、路径与版本对用户可见、可被替换；插件 UI 明示"内置 MetaCubeX/mihomo 内核（GPL-3.0）"并链接源码。
- 若组织想要零解释成本：把代理插件本体（甚至仅该插件包）以 GPL-3.0 开源，与三壳先例对齐；插件与宿主之间本就是进程/包边界，可以只开源插件而不动平台其余部分（此拆分本身也要满足 arms-length 的同样标准——插件若与宿主同进程深度耦合，则开源边界应划在耦合边界处。确定性：中）。
- 另注：ClashX Meta 是 AGPL-3.0，**不要**从它抄任何代码进非 AGPL 代码库；参考其做法（本文引用的接口形状）不受限。

## 7. 版本策略

来源：[releases.atom](https://github.com/MetaCubeX/mihomo/releases.atom)、upgrade.go、各壳 README。

- **发布节奏**：近期稳定版 v1.19.28（2026-07-08）→ v1.19.29（2026-07-18），约 1–3 周一个 patch；另有滚动更新的 `Prerelease-Alpha`（"Synchronize Alpha branch code updates, keeping only the latest version"，最后更新 2026-07-27）。跟稳定版即可，Alpha 面向尝鲜用户。
- **上游自带内核自升级**：`POST /upgrade`（可带 `channel`、`force` 参数）由内核下载新版替换自身可执行文件并 `restartExecutable` 重启（upgrade.go）——"应用内独立更新内核"有官方机制可用。
- **先例**：Clash Verge Rev 内置内核并"支持切换 Alpha 版本内核"（README 原文）；ClashX Meta 构建期把内核编进应用（随应用发布锁定）；Clash Party 随应用带内核（其 "Smart Core" 为魔改内核变体）。
- **建议（分析）**：V1 **锁定内核随应用发布**——理由：签名/公证完整性（§5 陷阱：bundle 内替换二进制会破签）、可测性（App×Core 版本矩阵不爆炸）、以及 `POST /upgrade` 拉回的官方裸二进制没有我们的 Developer ID 签名。将来若要独立更新通道，把内核落在 bundle 外的数据目录、由插件下载校验（哈希/签名）后自行 `codesign` 重签或接受 ad-hoc 运行的后果——作为 V2 议题。

## 8. 范围外：将来加 TUN 需要什么（仅记录门的形状）

TUN = 创建虚拟网卡接管全部流量（wiki tun 字段：`stack: system/gvisor/mixed`、`auto-route` "自动设置全局路由"、`dns-hijack` 等），在 macOS 上意味着内核进程要有 root 级能力。三壳的门各不相同但都是"root 常驻组件"：Clash Verge Rev 明文"**TUN 模式需要安装服务模式或管理员模式**"（[zh/settings.json](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src/locales/zh/settings.json) 界面原文；配套 `clash_verge_service_ipc` 系统服务）；Clash Party 靠 `party.mihomo.helper` launchd 守护（安装时一次管理员授权）；ClashX Meta 的 SMJobBless 助手模式同理。若走 App Store/无守护路线则是 Network Extension（Packet Tunnel Provider）+ 相应 entitlement，但那要求把数据面搬进扩展进程，与"子进程跑官方 mihomo"模型不兼容（此句为分析）。即：**TUN 之门 = 一个需管理员授权安装的特权组件（SMAppService 守护 / launchd 服务）+ 由它以 root 启动或授权内核**；V1 不做是对的，且系统代理路径的任何设计都不会被这扇门推翻。

---

## 附：来源清单

- mihomo 源码：[LICENSE](https://github.com/MetaCubeX/mihomo/blob/Meta/LICENSE) · [main.go](https://github.com/MetaCubeX/mihomo/blob/Meta/main.go) · [constant/path.go](https://github.com/MetaCubeX/mihomo/blob/Meta/constant/path.go) · [hub/route/server.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/server.go) · [proxies.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/proxies.go) · [groups.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/groups.go) · [configs.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/configs.go) · [upgrade.go](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/upgrade.go)
- mihomo 官方 wiki：[RESTful API](https://wiki.metacubex.one/api/) · [proxy-providers](https://wiki.metacubex.one/config/proxy-providers/) · [TUN](https://wiki.metacubex.one/config/inbound/tun/)
- 发布与实测：[releases/latest API](https://api.github.com/repos/MetaCubeX/mihomo/releases/latest) · [releases.atom](https://github.com/MetaCubeX/mihomo/releases.atom) · 本机 `/usr/local/bin/mihomo`（v1.19.28 darwin arm64）之 `file`/`codesign -dv`/`-v` 输出
- ClashX Meta：[SystemProxyManager.swift](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX/General/Managers/SystemProxyManager.swift) · [PrivilegedHelperManager.swift](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX/General/Managers/PrivilegedHelperManager.swift) · [ProxyConfigHelper.m](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ProxyConfigHelper/ProxyConfigHelper.m) · [install_dependency.sh](https://github.com/MetaCubeX/ClashX.Meta/blob/master/install_dependency.sh) · [goClash/build_clash_universal.py](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX/goClash/build_clash_universal.py) · [LICENSE（AGPL-3.0）](https://github.com/MetaCubeX/ClashX.Meta/blob/master/LICENSE)
- Clash Party（原 Mihomo Party）：[仓库/README](https://github.com/mihomo-party-org/clash-party) · [src/main/sys/sysproxy.ts](https://github.com/mihomo-party-org/clash-party/blob/smart_core/src/main/sys/sysproxy.ts) · LICENSE（GPL-3.0）
- Clash Verge Rev：[仓库/README](https://github.com/clash-verge-rev/clash-verge-rev) · [src-tauri/Cargo.toml](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src-tauri/Cargo.toml) · [sysproxy-rs fork：src/macos.rs](https://github.com/clash-verge-rev/sysproxy-rs/blob/main/src/macos.rs) · [locales/zh/settings.json](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src/locales/zh/settings.json) · LICENSE（GPL-3.0）
- Apple：本机 macOS 15 `man 8 networksetup` · [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues) · [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- GNU/FSF：[GPL FAQ #MereAggregation](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation) · [GPL FAQ #GPLInProprietarySystem](https://www.gnu.org/licenses/gpl-faq.en.html#GPLInProprietarySystem)
