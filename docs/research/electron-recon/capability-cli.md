# capability 纵切与 CLI/UDS：S2/S3 在 Electron 的等价形态

> 对应票：`.scratch/electron-recon/issues/03-capability-cli-uds.md`
> 调研日期：2026-07-28；CLI 分发形态一节的现状核实以 2026-07 为准（WebSearch，逐条标注来源与日期）。
> 前置阅读：`Spikes/S2CapabilitySlice/README.md`（Swift 纵切实测，全链 PASS）、`Spikes/S3CodexSandbox/README.md`（沙箱 UDS/TCP 全 EPERM 实测）、`.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md`（Swift 架构裁决）、`docs/research/platform-framework-research.md` §5/§6（栈无关保留章节，本文档只补 Electron 特有差异，不重复）。

## 0. 结论摘要

| 子问题 | 结论 |
|---|---|
| UDS server（Q1） | Node `net` 模块的 UDS 原语与 Swift/POSIX 同源，成熟度对等；S2 踩过的坑（sun_path 长度、废 socket 清理、权限位）在 Node 上原样存在，无框架级简化，也无新增阻塞。 |
| 菜单栏与确认弹窗（Q2） | `Tray` 官方成熟；dangerous 确认**推荐独立小 `BrowserWindow`**而非 `dialog.showMessageBox`（理由见 §2）；无 dock 图标下的前台激活问题在 Electron 生态里有对应已知 issue，走向与 S2 的 `NSApp.activate` 教训一致，需 `app.focus({steal:true})` + 主动 `show()/focus()` 补偿。 |
| `aa` CLI 分发形态（Q3，关键设计题） | **推荐 Node SEA（`--build-sea`，Node ≥22，2026-07 现状活跃在演进中）**，拒绝「要求用户自装 node」「`bun build --compile`」「复用 app 自带运行时 `ELECTRON_RUN_AS_NODE`」三条候选。理由与对照见 §3。 |
| S3 栈无关性（Q4） | **确认成立**，且推导出一条新的必要条件反哺 Q3：CLI 分发形态必须保证最终命令字符串仍是 `aa`，否则 `prefix_rule` 信任失效。完整论证见 §4（可独立引用）。 |
| IPC 安全基线（Q5） | Electron 版进程拓扑与 S2 的「注册表纯逻辑、GUI 确认由宿主注入」同构：注册表/UDS server/dangerous 策略全部落主进程；渲染进程（含 dangerous 确认窗）经 `contextBridge` 窄接口调用，零 Node/系统 API 直达。草图见 §5。 |

---

## 1. UDS server 成熟度（Node `net.createServer`）

S2 在 Swift 上踩的坑，逐条核对 Node 是否有对应问题：

| 坑（S2 原话/经验） | Node `net` 模块现状 |
|---|---|
| `sun_path` 是 104 字节的 `CChar` 元组，要手写字节填充 | Node 把这层封装掉了——`net.createServer().listen(path)` 直接接受字符串路径，不用手填 `sockaddr_un`。但底层限制没有消失：macOS 的 `sun_path` 上限约 103～104 字节，路径超限时 Node 会在 `listen()` 抛错，不是静默截断。真实项目已踩过这个坑（`vite-node` 在 macOS 上因临时目录路径过长导致 `connect EINVAL`，Anthropic 自家 Claude Code 也报过「Chrome MCP socket 路径超出 macOS unix socket 限制」的 issue）。**落地含义**：`aa.sock` 的路径要像 S2 一样刻意选短路径（如 `~/Library/Application Support/<bundle-id>/aa.sock`），避免落进深层嵌套目录。 |
| UDS 文件不随进程退出自动删，需 `unlink` 再 `bind` | 相同坑，Node 侧解法方向也相同：Node 官方文档确认——若是 Node 自己的 `net.createServer()` 创建的 UDS 文件，`server.close()` 才会 `unlink` 它；进程崩溃或异常退出不会清理，下次 `listen()` 撞见旧文件会报 `EADDRINUSE`。产品实现需在 `listen()` 前主动探测并清理陈旧 socket 文件（先尝试 connect 判活，不活着才 unlink），与 S2 的 `unlink → bind` 顺序同构。 |
| socket 文件权限，S2 用默认（0755 目录 + 默认 umask），标记为「产品化需定鉴权」 | Node 没有 `listen()` 级别的显式 mode 参数；官方模式是靠 `process.umask()` 在 `listen()` 前收紧，或 `listen()` 成功回调里 `fs.chmodSync(path, 0o600)` 显式收紧到仅当前用户可读写。**这一项两边都是「留给产品化」的未决项，不是 Node 独有短板**——S2 的备注原样适用于 Electron 版。 |
| accept 循环后台队列 + 并发处理，弹窗要 `DispatchQueue.main.sync` 切回主线程 | Node 是单线程事件循环，`net.Server` 的 `connection` 事件天然并发处理多条连接、互不阻塞；无需手动线程切换。dangerous 确认需要「暂停这条连接的响应，直到用户在主进程发起的弹窗上做出选择」——用 `async/await` + Promise 挂起即可表达同样的语义，不需要 S2 那种显式跨线程同步原语，**心智模型更简单**，是 Node 单线程模型相对 Swift 多线程模型的一处真实优势。 |

**结论**：Node UDS 路径成熟、无阻塞；S2 的坑集合（sun_path、废 socket、权限位）原样搬到 Node 侧，需要同等注意力，但没有新增的 Electron/Node 特有障碍。

## 2. 菜单栏与确认弹窗

**Tray**：`Tray` + `Menu`/`MenuItem` 是 Electron 官方稳定 API（mac/win/linux 全覆盖），承接 S2 的菜单栏 ⚡ 图标 + 只读能力清单 + 「退出」项，无需额外验证——该部分与本票范围重叠的窗口成熟度细节归 02 票（宠物悬浮窗）覆盖，这里不重复。

**dangerous 确认：`dialog.showMessageBox` vs 独立 `BrowserWindow` —— 推荐独立 `BrowserWindow`**：

1. **无父窗口时的前台/焦点问题是真实存在的已知类目**：`electron/electron#15604`（`dialog.showMessageBox(null, options)` 无父窗口时可失焦、被主窗口盖住）——该 issue 状态为 closed，但关闭时间是 2018 年、无官方修复说明可考，不能确认问题在近版 Electron 已根治，需 E1 冒烟里针对无父窗口/无 dock 图标场景专项复测。`aa` 场景下宿主是纯托盘应用，天然没有一个「正常态」父窗口可挂，命中的正是这个未经清算证实的风险区。
2. **原生 `dialog.showMessageBox` 的内容表达能力弱于需求**：ADR 0004 要求 dangerous 确认展示能力 ID、风险摘要、输入参数等结构化信息；原生消息框的排版/多语言/富文本能力有限，独立 `BrowserWindow` 用 HTML/CSS 能完整还原 S2 `NSAlert` 之外更丰富的确认 UI，且可被 Playwright 的 Electron automation API 驱动做自动化回归（`platform-framework-research.md` §9.1 已把 Electron E2E 覆盖 IPC/通知列为门禁项，原生 dialog 无法被这类工具稳定驱动，独立窗口可以）。
3. **前台激活可控性**：独立窗口可以显式 `setAlwaysOnTop('screen-saver')` + `show()` + `focus()`，并在此之前调用 `app.focus({steal: true})`（macOS 专属，强制夺取前台焦点）——这与 S2 finding #4「accessory app 弹窗前必须 `NSApp.activate(ignoringOtherApps:true)`」是同一形状的补偿动作，且比原生 dialog 的隐式前台策略更可控、可测试。

**无 dock 图标（LSUIElement 等价）**：Electron 侧对应两种做法——构建期在 `electron-builder` 的 `mac.extendInfo` 里静态写 `LSUIElement: true`（等价 Swift 的 Info.plist `LSUIElement`），或运行期调用 `app.dock.hide()` 动态隐藏。两者已知问题：`electron/electron#3498`（`app.dock.hide()` 运行期隐藏时有图标闪烁动画）、`electron/electron#6283`（dock 图标隐藏后应用从 Cmd+Tab 切换器消失，2016 年提出，closed 但同样缺乏官方修复说明可考）。**建议**：优先用构建期静态 `LSUIElement: true`（避免 `#3498` 的运行期闪烁），并把「无 dock 图标下 dangerous 弹窗能否被前台看见」列为 E1 冒烟的必测项——这与 S2 finding #6 遗留的「弹窗前台性」残余风险是同一件事,在 Electron 上不会更轻,需要同等力度的人工验收。

## 3. `aa` CLI 的分发形态（关键设计题）

### 候选与核实（2026-07）

**A. 独立 Node 脚本，要求用户机器装 Node** — **拒绝**。票面已预判「不可接受」；这与本图存在的动机（不让工具链安装门槛卡产品，`map.md`「希望把初版快速开发出来」）直接冲突，等于把 Xcode 门槛换成了 Node 门槛，V1 目标用户不应被要求先装开发者工具链。

**B. `bun build --compile`** — **不推荐**。核实要点（WebSearch，2026-07）：
- Bun 的 `--compile` 能产出内嵌运行时的独立可执行文件，机制成立；但 **macOS 侧现存签名相关问题**：编译产物签名无效（`oven-sh/bun#32159`「Binaries created with bun build --compile have invalid signature on macOS」）；macOS 27 beta 上会崩溃虽然 macOS 26 尚可运行；近期（1.3.12）还出现过编译产物启动即被系统杀死（exit 137）的回归，1.3.11 无此问题。
- 这些是 2026-07 时间点上仍然开放/新近出现的平台相关缺陷，作为要签名分发给终端用户的 CLI 二进制风险偏高。
- 额外代价：为了给一个薄 UDS JSON 客户端引入 Bun 这第二套 JS 运行时/构建链，与 `platform-framework-research.md` §1 第 4 条「统一在 TypeScript/Node，降低跨语言接口与构建链认知成本」的既定原则相悖——Electron 主进程本就跑在 Node 上，CLI 应复用同一条构建链而非新开一条。

**C. `pkg`（打包单二进制）** — **原始 `vercel/pkg` 拒绝，`yao-pkg` fork 列为备选而非首选**。核实要点：
- `vercel/pkg` 已于 2024 年正式 deprecated（5.8.1 为最后一个版本），仓库归档；官方给出的理由正是 Node 原生 SEA 已经能覆盖同样需求。2026-07 不应再选它做新项目的起点。
- `@yao-pkg/pkg` 是活跃维护的 fork，可直接替换 `vercel/pkg`（drop-in），持续跟进 Node 新版本（近期提交里出现对 Node 22.22.3/24.15.0/26.2.0 的支持）。**它是可用的，但既然 Node 已经原生提供等价能力（选项 D），没有理由优先选一个第三方工具再承担一层依赖**——留作 D 方案遇阻时的 Plan B。

**D. Node SEA（Single Executable Applications，`--build-sea`）** — **推荐**。核实要点（WebSearch + 官方文档，2026-07）：
- 官方文档（`nodejs.org/api/single-executable-applications.html`）标注稳定度为 **`Stability: 1.1 - Active development`**——尚未到 stable，但处于持续演进中：2026-01 发布的 Node 25.5 新增 `--build-sea` 一步构建旗标，把此前「生成 blob → `postject` 注入」的两步流程合并为一步；同月有 Node 核心贡献者（Joyee Cheung）撰文继续改进 SEA 构建体验，说明这条路线是官方在积极投入、而非停滞的实验特性。
- macOS 签名流程官方文档已写明：`codesign --remove-signature` 去签名 → 注入 blob → 用 Developer ID 重新签名 → 走 notarization。这一步骤与 Swift/Electron 主 app 本身的签名+公证流程同构，**不需要额外工具链**（用到的 `codesign`/`notarytool` 在本机已实测健康，见 01 票），只是多了「去签名再重签」这一道工序。
- 原生模块支持存在但笨重（需要把 `.node` 文件放进 `assets`、运行时写临时文件再 `process.dlopen`），且有已知的 Linux arm64 容器构建缺陷——**但这对 `aa` 基本不构成约束**：`aa` 被 07 票定义为「UDS 薄客户端」，S2 的 Swift `aa` 也刻意「纯 Foundation/Darwin，不 import AppKit」，Node 版等价物只需要 `node:net`（unix socket）+ `JSON.parse/stringify`，两者都是 Node 内建模块，不触发原生模块打包问题。
- 无第三方依赖、无第二套运行时、失败时的 Plan B（yao-pkg）路径清楚。

### 推荐与理由

**推荐 Node SEA（`--build-sea`）作为 `aa` 的分发形态；`@yao-pkg/pkg` 作为 SEA 在 E1/Phase 0 实测中若遇到未预见阻塞时的 Plan B；明确拒绝「要求用户自装 Node」「`bun build --compile`」「复用 app 自带运行时」。**

理由收拢：官方一等公民路径、构建链与主 app 复用同一 Node/codesign/notarytool 工具集、`aa` 本身零原生依赖使 SEA 最大的短板不成立、且是四个候选里唯一同时满足「不新增运行时依赖」与「不要求用户预装工具」的选项。

**候选 E. 复用 app 自带运行时（`ELECTRON_RUN_AS_NODE=1 <App>/Contents/MacOS/<App> aa.js`）—— 明确拒绝，且理由比票面预设的「丑陋」更硬**：

- 票面原始顾虑是「可行性与丑陋度」，实测发现的是一个**安全层面的直接冲突**：Electron 提供「fuses」机制（`@electron/fuses`），其中 `runAsNode` 这一 fuse 专门控制 `ELECTRON_RUN_AS_NODE` 环境变量是否被尊重。Electron 官方发过专门声明（`electron.js.org/blog/statement-run-as-node-cves`）：已签名、公证、分发的 app 如果保留这个 fuse 打开，等于给攻击者留了一条「living off the land」执行任意 Node 代码的后门，绕过 hardened runtime 的代码签名保证；官方明确建议**不使用该能力的应用应关闭此 fuse**。
- 本项目的宿主 app 恰恰是「dangerous 能力确认」的信任锚点（ADR 0005 agent-first、S2/S3 全部建立在「确认永远落宿主 GUI」这个信任前提上）——如果为了让 `aa` CLI 复用运行时而特意保留 `runAsNode` fuse 打开，就是主动在这个信任锚点上开一个官方点名警告过的洞，与项目自身的安全立场自相矛盾。
- 若遵循官方建议关闭该 fuse（推荐的、安全的默认），这条分发形态直接失效——CLI 根本调不起来。
- 即便忽略安全问题，§4 会证明这条路径还有一个独立的、足以否决它的理由：它无法保持命令字符串为 `aa`（见 §4 结尾）。
- 结论：三重否决（官方安全声明 + 与项目信任模型自相矛盾 + 破坏 prefix_rule 前提），比原票面预判的「丑陋」更严重，直接排除。

### 与 Swift 路线的诚实对照

Swift 路线的 `aa` 是 `swiftc`/`xcodebuild` 直接产出的原生 Mach-O 二进制——**没有「把脚本打成可执行文件」这一额外构建步骤**，编译产物本身就是可执行文件；这是 Electron/Node 路线在任何分发形态下都无法完全抹平的结构性差异，即便 SEA 最终产物同样是终端用户视角下「双击/命令行直接跑」的单一二进制。差异体现在两处，需要如实交底给裁决者：

1. **构建链多一道工序**：SEA 需要显式「生成 blob → 注入 → 去签名重签 → 公证」，Swift 侧这些步骤中只有「签名公证」是共有的，「注入」是 Node 特有的额外环节。
2. **冷启动成本**：SEA 二进制内嵌 V8/Node 运行时，启动时有运行时初始化开销；Swift 原生二进制没有这一层。对于 `aa list`/`aa call` 这种一次性短命令行调用，该开销是否用户可感知需要 E1/Phase 0 阶段实测（本票不做实测，只标注为待验证项）。

这两点不构成推荐 SEA 的否决理由（票面裁决动机本身就是接受 Electron 栈的整体代价换取免 Xcode），但裁决者应当带着这份诚实对照做决定，而不是误以为两条路线在 CLI 分发上完全等价。

## 4. S3 结论的栈无关性核查（可独立引用）

**结论：成立。** S3《codex workspace-write 沙箱下 UDS/localhost TCP 全 EPERM，幸存路径 = `prefix_rule` 提权》这一结论与宿主用什么语言/框架实现 UDS 监听端无关；把宿主从 Swift 换成 Electron，S3 的实测表格逐格不变。完整推理链如下。

**第一步：S3 拦截的对象是谁。** S3 README 原话：

> 「`workspace-write` 只放行文件系统写(workdir、/tmp、$TMPDIR)，socket 类操作一律禁止——`connect()` 系统调用层面被 seatbelt 拒绝，与 socket 文件所在目录是否可写无关。」

被拦截的动作是 **`connect(2)` 系统调用**，且拦截点在 **发起连接的一方**（S3 场景里就是运行在 codex sandbox 内、试图连宿主 socket 的探针/客户端进程）。macOS Seatbelt 的沙箱 profile 是挂在被 `exec` 出来的那个进程本身，由内核在该进程发起系统调用时逐次检查——这是 Seatbelt 的标准工作方式：策略作用于"谁在打这个系统调用"，而不是检查"这个调用要连去哪个具体服务、对方进程是什么语言写的"。S3 原文已经验证了这一点对"路径位置"这一维度的无关性（"与 socket 文件所在目录是否可写无关"）；同一条推理对"监听端实现语言"这一维度同样成立——**Seatbelt 看到的只是一次 `connect()` 系统调用尝试，它不会、也没有渠道去检查这次调用最终会连到一个 Swift 写的 UDS server 还是一个 Node 写的 UDS server。监听端换成 Electron/Node 的 `net.createServer`，从被拦截进程的视角看，仍然只是「我试图对某个 `AF_UNIX` 地址发起 `connect()`」——这次调用本身在系统调用层面无法区分对端实现，因此没有任何机制能让 Electron 宿主获得比 Swift 宿主更好或更差的待遇。**

**第二步：三行实测表格为什么原样成立。** S3 的三个端点（工作区外 UDS / 工作区内 UDS / TCP localhost）全部 EPERM，覆盖的是「沙箱内进程能否发起任意 socket 连接」这一问题，与端点另一侧listen 的是谁完全正交。把宿主实现从 Swift `S2Host` 换成 Electron 主进程的 `net.createServer` 监听同一类 UDS 地址，客户端（无论是 S3 的 `probe.py`，还是产品里的 `aa` CLI）在沙箱内发起 `connect()` 时命中的仍是同一条 Seatbelt 规则，结果仍是 `EPERM`。

**第三步：幸存路径的构成要件同样不因宿主语言而变。** S3 原文：

> 「幸存路径 = 提权信任：从 codex 二进制 strings 证实机制——模型可为命令声明 `sandbox_permissions: "require_escalated"` 并附 `prefix_rule`（如 `["aa"]`），Codex 把它作为「可持久化的允许规则」呈现给用户，一次批准、后续会话复用；受信命令在**沙箱外**执行，IPC 畅通。」

这条提权机制的判定依据是 **codex 侧对即将执行的 shell 命令字符串做 `prefix_rule` 匹配**，命中后把这条命令整体挪到沙箱外执行——一旦挪到沙箱外，前面两步讨论的 Seatbelt 拦截根本不适用（不是"放行"，是"压根没经过那层检查"）。这个匹配发生在 codex 自己的进程里、在命令被 `exec` 之前，同样与宿主语言无关。

**第四步（反哺 Q3 的新发现）：prefix_rule 匹配的是字面命令字符串，这对 CLI 分发形态构成一条隐含约束。** `prefix_rule: ["aa"]` 匹配的是用户/模型将要执行的命令前缀字面量。这意味着：
- 若 §3 推荐的 SEA 方案落地为 PATH 上一个名为 `aa` 的可执行文件，Codex 提议执行的命令就是 `aa ...`，与用户已批准的 `prefix_rule ["aa"]` 直接匹配——S3/07 票建立的信任引导故事原样成立。
- 若采用被 §3 否决的候选 E（`ELECTRON_RUN_AS_NODE=1 /Applications/X.app/Contents/MacOS/X aa.js`），Codex 提议执行的命令字面量会是 `ELECTRON_RUN_AS_NODE=1 /Applications/...` 或 `node`，**不是** `aa`——用户此前对 `aa` 批准的 `prefix_rule` 不会匹配这条命令，每次调用都会重新触发审批，S3/07 建立的「一次批准、后续复用」体验直接失效。这是候选 E 在安全顾虑之外的第二条独立否决理由，同时也印证了 Q3/Q4 两节结论互相咬合、不是孤立的。

**结论重申**：S3 的沙箱结论（UDS/TCP 全 EPERM，`prefix_rule` 提权为唯一幸存路径）是 codex 沙箱设计与 `aa` **客户端**进程行为的性质，与宿主监听端的实现语言正交，**换成 Electron 后原样成立**；唯一需要注意的是 CLI 分发形态必须保证暴露给 Codex 的命令字面量仍是干净的 `aa` 前缀，这一点已经在 §3 的推荐里满足（SEA 产出单一 `aa` 可执行文件），在被否决的 `ELECTRON_RUN_AS_NODE` 候选里不满足。

## 5. IPC 安全基线与进程拓扑

Electron 官方安全指南的三条硬约束（`platform-framework-research.md` §3.1 已引用，此处落到本票的注册表/UDS 语境）：渲染进程 `contextIsolation: true`、`nodeIntegration: false`、`sandbox: true`；渲染进程只能经 `contextBridge` 暴露的窄类型化接口调用主进程能力。对照 ADR 0004「能力契约只有一个事实来源」与 S2「注册表是纯逻辑、零 AppKit，GUI 确认由宿主注入回调实现」的分层经验，Electron 版进程拓扑：

```
外部调用方（宿主进程之外，独立 OS 进程）
  aa CLI（UDS 客户端，SEA 单二进制）──UDS(JSON lines)──┐
  Codex 沙箱内子进程（经 prefix_rule 提权，沙箱外执行）─┤
                                                        ▼
                                          Electron 主进程（Node 上下文）
                                          ├─ Capability Registry（纯逻辑，零 Electron/系统 API 依赖，可单测）
                                          ├─ UDS server（node:net，同一 Registry 实例）
                                          ├─ Dangerous 确认策略（决策逻辑）
                                          ├─ Tray + 菜单（Electron API）
                                          └─ contextBridge IPC 面（ipcMain.handle，窄类型化）
                                                        │  仅供内部渲染进程，contextIsolation+sandbox 双开
                                                        ▼
                                          渲染进程（壳，零业务逻辑）
                                          ├─ 控制中心窗口 —— 只读展示 + 发起调用请求，逻辑全部经 contextBridge 转发
                                          └─ Dangerous 确认窗口（§2 推荐的独立 BrowserWindow）
                                               —— 宿主自有 surface，与控制中心同信任层级，仍强制 contextIsolation
                                                  （内容来自本地打包文件，非远程页面）
```

关键点：

- **外部 UDS 路径与内部 `contextBridge` 路径，最终都调用同一个 Capability Registry 实例**——GUI 菜单栏触发的调用与 `aa` CLI 触发的调用在主进程里走同一段代码，不存在「GUI 走一套逻辑、CLI 走另一套」的分叉，直接满足 ADR 0004。
- Registry 保持「纯逻辑」意味着它不 `import electron`/不碰 `BrowserWindow`/`Tray`，与 S2 里 `AAHostRuntime`（Swift 侧纯逻辑 target）对应；Electron 特有的 API（Tray、UDS server 生命周期、dangerous 确认窗口）扮演 S2 里 `AAHostMacOS`（Host Port 实现）的角色，通过依赖注入把「如何弹窗确认」这个能力喂给 Registry，而不是让 Registry 反向依赖 Electron。
- Dangerous 确认窗口虽然是渲染进程，但它是宿主自己的 surface（非插件 UI），仍然全程 `contextIsolation`/`sandbox` 打开——防御纵深不因为"是自己人"而放松，插件将来若引入运行时不受信第三方（`platform-framework-research.md` §5.3 标注为暂缓项）时，这条基线不需要重新设计。

## 附：证据来源（WebSearch/WebFetch，核实日期 2026-07-28）

- [Node.js Single Executable Applications 官方文档](https://nodejs.org/api/single-executable-applications.html) — Stability 1.1、macOS 签名步骤、原生模块限制、`--build-sea`。
- [Improving Single Executable Application Building for Node.js（Joyee Cheung，2026-01）](https://joyeecheung.github.io/blog/2026/01/26/improving-single-executable-application-building-for-node-js/)
- [Node.js 25.5 Adds --build-sea（2026-01）](https://progosling.com/en/dev-digest/2026-01/nodejs-25-5-build-sea-single-executable)
- [Bun 官方文档：Single-file executable](https://bun.com/docs/bundler/executables)
- [oven-sh/bun#32159：macOS 签名无效](https://github.com/oven-sh/bun/issues/32159)
- [oven-sh/bun#29151：1.3.12 macOS 启动即被杀死回归](https://github.com/oven-sh/bun/discussions/29151)
- [vercel/pkg 仓库（已归档，deprecated）](https://github.com/vercel/pkg)
- [yao-pkg/pkg（活跃 fork）](https://github.com/yao-pkg/pkg)
- [Electron Fuses 官方文档](https://www.electronjs.org/docs/latest/tutorial/fuses)
- [Electron 官方声明：runAsNode CVEs](https://www.electronjs.org/blog/statement-run-as-node-cves)
- [Node.js net 模块文档](https://nodejs.org/api/net.html) — UDS 清理语义。
- [nuxt/nuxt#35253：macOS 104 字节 sun_path 限制导致 EINVAL](https://github.com/nuxt/nuxt/issues/35253)
- [anthropics/claude-code#17658：macOS unix socket 路径超限](https://github.com/anthropics/claude-code/issues/17658)
- [electron/electron#15604：`dialog.showMessageBox` 无父窗口失焦（closed，2018，无修复说明可考）](https://github.com/electron/electron/issues/15604)
- [electron/electron#3498：`app.dock.hide()` 运行期隐藏图标闪烁](https://github.com/electron/electron/issues/3498)
- [electron/electron#6283：dock 图标隐藏后从 Cmd+Tab 切换器消失（closed，2016，无修复说明可考）](https://github.com/electron/electron/issues/6283)
