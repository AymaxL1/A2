# 桌面插件能力平台：框架调研与架构建议

> 调研日期：2026-07-16  
> 状态：初始化前的决策依据，不是最终实现规范  
> 资料原则：事实优先引用官方文档、规范和源码；“建议”部分是结合本项目约束作出的推论。

## 1. 结论摘要

建议 V1 采用 **Electron + TypeScript + React/Web UI + pnpm workspace**，构建一个桌面优先、Web 为能力子集的本地能力平台。

选择 Electron 的决定性原因不是“流行”，而是本项目几个需求形成了明显合力：

1. 宠物需要透明、无边框、置顶、可忽略鼠标事件的独立窗口；Electron 的 `BrowserWindow` 直接提供透明窗口、置顶和窗口控制能力。[Electron BrowserWindow](https://www.electronjs.org/docs/latest/api/browser-window)、[Electron custom windows](https://www.electronjs.org/docs/latest/tutorial/custom-window-styles)
2. 产品需要后台常驻、托盘、系统通知和 macOS/Windows 更新；Electron 对这些都有官方主进程 API。[Tray](https://www.electronjs.org/docs/latest/api/tray)、[Notification](https://www.electronjs.org/docs/latest/api/notification)、[autoUpdater](https://www.electronjs.org/docs/latest/api/auto-updater)
3. V1 Agent 插件要深度调用用户本机 Codex。OpenAI 官方将 Codex App Server 定位为自有产品深度集成入口，并提供会话、审批、历史与流式事件；官方 TypeScript SDK要求 Node.js 运行时。Electron 主进程与这条路径天然同栈。[Codex App Server](https://learn.chatgpt.com/docs/app-server)、[Codex SDK](https://learn.chatgpt.com/docs/codex-sdk)
4. 用户不熟悉 Rust，项目又计划主要由 AI 持续开发。把 UI、宿主、插件 SDK、CLI 与绝大多数测试统一在 TypeScript，能降低跨语言接口与构建链的认知成本。
5. Web 端可以复用渲染层、设计系统、领域模块和支持 Web 的插件；所有原生能力通过 Host Port 隔离，浏览器不会被伪装成具备桌面能力。

**Tauri 是最有价值的备选，而不是 V1 首选。** 它提供较小的分发体积、Rust 后端和显式 capability/permission 模型，也支持窗口、托盘、通知与更新。[Tauri capabilities](https://v2.tauri.app/security/capabilities/)、[Tauri window customization](https://v2.tauri.app/learn/window-customization/)、[Tauri updater](https://v2.tauri.app/plugin/updater/)。但本项目若采用 Tauri，仍需为 Codex App Server/SDK、CLI 进程管理和复杂桌面行为引入 Rust 命令或 sidecar；这会同时维护 TypeScript、Rust和外部 Agent 进程三层边界。除非 Electron 的内存/包体经过原型验证后不可接受，否则收益不足以抵消 V1 复杂度。

## 2. 已确认的产品边界

- macOS、Windows 为完整宿主；Web 是能力子集。
- 桌面应用登录后常驻，托盘/菜单栏为入口，控制中心按需打开。
- local-first；V1 无账号、无云后端、无跨设备同步。
- 插件是 monorepo 内的可信独立包，构建时集成、开发时热加载；V1 不开放运行时第三方安装或插件市场。
- 首批真实插件：宠物插件、提醒插件、桌面 Agent 插件。
- 插件之间不直接 import 实现，通过宿主的版本化能力注册表协作。
- 所有稳定、用户有意义的领域能力都可由机器调用；GUI、CLI、内置 Agent 和未来协议适配器共用同一契约。
- V1 Agent 插件仅支持桌面端和用户已安装的 Codex；不自研 Agent、不捆绑 Codex、不实现 Web Agent。
- macOS、Windows 的真实 CI 是合并/发布门禁；插件必须通过统一自测套件。

## 3. 框架对比

| 维度 | Electron | Tauri 2 | Wails | Flutter |
|---|---|---|---|---|
| 主语言 | TypeScript/JavaScript + Chromium/Node | Web UI + Rust 宿主 | Web UI + Go 宿主 | Dart |
| Web UI 复用 | 很高；renderer 可作为普通 Web app | 很高；前端仍是 Web app | 高；前端仍是 Web app | 共享 Dart UI，但不是 DOM/Web 组件生态 |
| 宠物悬浮窗 | 官方 `BrowserWindow` 能力直接匹配 | 支持窗口能力，但复杂行为需逐平台验证 | 可做原生窗口，资料与生态较小 | 可做桌面窗口，但高级透明/点击穿透常依赖插件或平台代码 |
| 托盘/通知/更新 | 官方 API 完整 | 官方/官方插件覆盖 | 官方运行时覆盖常见能力 | 依赖 Flutter 桌面及插件生态 |
| Codex 深度集成 | Node/TS SDK 与子进程最直接 | Rust 启动 App Server 或 Node sidecar | Go 启动 App Server，需自写协议层 | Dart 启动进程，需自写协议层 |
| 自动化测试 | Web 测试生态成熟；Playwright 提供 Electron automation API | 单元测试可共享；桌面 E2E 更依赖 WebDriver/平台配置 | Go + Web 测试可行，生态较小 | Flutter 自有 widget/integration test 体系成熟 |
| 主要成本 | 包体、内存、Chromium 安全更新 | Rust 学习/编译、WebView 平台差异、sidecar | Go 新语言与较小桌面生态 | 整套 Dart/Flutter 技术栈，现有 Web/TS 资产复用较弱 |
| 本项目判断 | **推荐 V1** | **保留为 Plan B** | 不推荐 | 不推荐 |

事实依据：

- Electron 将 Chromium 与 Node.js 组合为跨平台桌面运行时，并提供主进程/renderer 架构。[Electron process model](https://www.electronjs.org/docs/latest/tutorial/process-model)
- Electron 官方安全指南要求 renderer 不启用 Node integration、启用 context isolation，并通过受限 preload 暴露能力；采用 Electron 不等于允许插件 UI 直接访问 Node。[Electron security](https://www.electronjs.org/docs/latest/tutorial/security)
- Tauri 2 的 capability 文件用于精确授予窗口和 WebView 可调用的命令权限，这一思想值得移植到本项目自己的插件权限层。[Tauri capabilities](https://v2.tauri.app/security/capabilities/)
- Wails 的核心模型是 Go 方法绑定给 Web 前端；这会把项目主宿主语言从 TypeScript 转向 Go。[Wails how it works](https://wails.io/docs/howdoesitwork/)
- Flutter 官方支持构建 Windows、macOS 与 Web 应用，但 UI 与工具链围绕 Dart/Flutter，而不是复用 DOM 组件。[Flutter supported platforms](https://docs.flutter.dev/reference/supported-platforms)

### 3.1 Electron 的风险及控制方式

1. **内存和包体**：Chromium 带来固定成本。初始化前必须做真实 spike，而不是仅比较官网数字。
2. **renderer 安全**：renderer 只能调用经过类型化 preload bridge 暴露的 Host Port；`nodeIntegration: false`、`contextIsolation: true`，禁止加载不可信远程页面。[Electron context isolation](https://www.electronjs.org/docs/latest/tutorial/context-isolation)
3. **主进程过深**：Electron API、存储、调度、能力注册和 Codex 进程管理要包在深模块后面，业务插件不能 import Electron。
4. **平台差异**：透明、点击穿透、全屏空间、通知权限、签名更新必须在真实 macOS/Windows runner 验证。
5. **更新供应链**：macOS 自动更新要求签名；更新发布必须校验签名并先备份迁移数据。[Electron autoUpdater](https://www.electronjs.org/docs/latest/api/auto-updater)

## 4. 推荐总体架构

```text
┌─────────────────────────────────────────────────────────────┐
│ Applications                                                │
│  Desktop control center  Pet overlay  Web app  Official CLI │
└──────────────┬──────────────────────────────────────────────┘
               │ typed adapters
┌──────────────▼──────────────────────────────────────────────┐
│ Host platform                                               │
│ plugin catalog │ capability registry │ permission/policy    │
│ invocation receipts │ audit/logging │ lifecycle │ storage   │
└──────────────┬──────────────────────────────────────────────┘
               │ public plugin contracts only
┌──────────────▼──────────────────────────────────────────────┐
│ First-party plugins                                         │
│ pet │ reminder │ desktop-agent                              │
└─────────────────────────────────────────────────────────────┘
```

核心原则是 **能力契约只有一个事实来源**：

- GUI 不直接调用插件实现。
- CLI 不重写业务逻辑。
- Agent 插件不拥有私有超级接口。
- reminder 不 import pet；它请求 `notification.presenter` 能力。
- Electron、Web 与测试宿主都实现同一组 Host Ports。

### 4.1 建议的包边界

```text
apps/
  desktop/              Electron composition root
  web/                  Web composition root
  cli/                  local IPC client and machine JSON CLI
packages/
  contracts/            IDs, schemas, errors, receipts, versions
  plugin-sdk/           manifest builder and capability registration
  host-runtime/         lifecycle, registry, policy, invocation
  host-electron/        Electron ports, windows, tray, notifications
  host-web/             browser ports and explicit limitations
  host-testkit/         deterministic fake host and conformance suite
  ui-system/            shared design system and i18n
  plugin-pet/
  plugin-reminder/
  plugin-agent/
```

配合 Matt Pocock skills，应把每个包做成 deep module：包根文件是少量入口，`lib/` 是隐藏实现，测试只通过公共入口。每个变更先形成 spec/issue，在最高可用 seam 做 TDD，完成后执行 code review。项目初始化后再运行相应 setup skills，不在本次 research 中提前生成配置。

## 5. 插件模型

### 5.1 Manifest

每个插件的 manifest 至少包含：

- `id`、显示名 i18n key、版本、所需 Plugin API 范围；
- 支持平台：`macos | windows | web`；
- 生命周期与后台任务声明；
- 请求的宿主权限；
- 提供与消费的 capability；
- 数据 schema 版本与 migration；
- Agent/CLI 可发现的能力摘要；
- 设置页和可选展示 surface。

可以借鉴 VS Code extension manifest 的 `engines`、`activationEvents`、`contributes` 和命令注册方式，但本项目 V1 是构建时可信插件，不应照搬 VS Code 的 Extension Host 进程或 Marketplace 复杂度。[VS Code extension manifest](https://code.visualstudio.com/api/references/extension-manifest)、[VS Code activation events](https://code.visualstudio.com/api/references/activation-events)、[VS Code commands](https://code.visualstudio.com/api/extension-guides/command)

### 5.2 Capability Contract

一个可公开的领域能力必须声明：

- 稳定 ID 与版本；
- 输入/输出 JSON Schema；
- query 或 command；
- 风险等级：safe / normal / dangerous；
- 所需权限；
- 幂等键和重试语义；
- 超时、取消和结构化错误；
- 是否可逆及补偿能力；
- 用户可读摘要与 Agent 可读短描述；
- 成功、校验失败、权限拒绝、幂等和补偿测试样例。

不要把内部函数变成能力。`reminder.create` 是能力，`database.execute` 和 `pet.setFrame` 不是。

### 5.3 隔离策略

V1 不做一插件一进程，但要做强逻辑隔离：

- UI error boundary；
- 后台任务超时、取消、重试和熔断；
- 插件启用失败后安全禁用；
- 插件独立存储命名空间和 migration；
- 能力调用异常不得穿透宿主；
- 故障注入测试覆盖超时、坏数据、缺失 capability 与 renderer 崩溃。

未来开放不受信任第三方插件时，再引入 Worker/utility process、签名与资源配额。当前 API 要避免把 Electron 或数据库对象泄漏给插件，以保留升级空间。

## 6. CLI 与 Agent 可操作性

### 6.1 CLI 设计

CLI 是宿主官方适配器，不是业务插件。推荐稳定机器接口：

```bash
app capabilities list --json
app capabilities describe reminder.create --json
app capability call reminder.create --input '{...}' --json
```

插件可声明可选的人类友好别名，但别名必须转换为同一 capability invocation。stdout 只输出结果 JSON，诊断写 stderr，并使用稳定 exit code。宿主未运行时返回结构化 `host_unavailable`；只有显式 `app start`/`--start-host` 才启动宿主。

CLI 通过当前用户范围的本地 IPC 调用宿主，复用 GUI/Agent 的三级风险策略、会话授权和审计。所有写调用携带 `idempotencyKey`，返回 invocation receipt 与资源 ID。

### 6.2 CLI 与 MCP 的判断

MCP 已提供标准的 tool discovery、JSON Schema 工具参数和客户端/服务器协议；Codex 官方支持把 MCP server 配置为工具来源，也能把 Codex 自身作为 MCP server。[MCP specification](https://modelcontextprotocol.io/specification/latest)、[Codex MCP](https://learn.chatgpt.com/docs/mcp)

建议：

- **V1 必做 CLI**：通用、可调试、适合脚本和所有能运行 shell 的外部 Agent。
- capability contract 必须 transport-neutral。
- **在 registry 稳定后增加薄 MCP adapter**，不要让 MCP 类型进入领域核心。
- MCP adapter 与 CLI 必须跑同一批 conformance cases，验证权限、幂等、错误和结果一致。

原因：仅靠 CLI 时，Agent 要先学会命令发现并解析进程结果；MCP 对动态工具发现更自然。但把 MCP 作为唯一入口会牺牲普通脚本与人工诊断体验，并把项目绑定到仍在演进的协议表面。

## 7. Codex Agent 插件

### 7.1 官方可用集成面

OpenAI 当前提供四条相关路径：

1. **Codex App Server**：官方明确建议用于自有产品的深度集成，覆盖认证、会话历史、审批和流式事件；协议是双向 JSON-RPC 风格，可生成与当前 Codex 版本匹配的 TypeScript/JSON Schema。[Codex App Server](https://learn.chatgpt.com/docs/app-server)
2. **TypeScript SDK**：面向应用内控制 Codex，支持 thread start/resume；要求 Node.js 18+。[Codex SDK](https://learn.chatgpt.com/docs/codex-sdk)
3. **`codex exec --json`**：稳定的非交互接口，输出 JSONL 事件并支持按 session ID resume，适合自动化与降级路径。[Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
4. **`codex mcp-server`**：Codex 作为另一个 Agent 的 MCP 工具，更适合“Codex 是更大编排系统中的专家”场景，而不是本项目的聊天客户端主路径。[Codex as MCP server](https://learn.chatgpt.com/docs/mcp-server)

### 7.2 推荐设计

Agent 插件内部定义通用 `AgentRuntime`，宿主核心完全不知道 Codex：

```text
Agent UI
  -> AgentRuntime
       -> CodexAppServerAdapter (V1 real implementation)
       -> FakeAgentRuntime       (deterministic tests)
       -> FutureBuiltInAgent     (reserved, not implemented)
       -> FutureOtherLocalAgent  (reserved)
```

标准事件只表达产品语义：session started/resumed、message delta、tool requested、tool progress/result、approval required、turn completed/failed、runtime diagnostics。任何 Codex 专属事件都在 adapter 内转换。

**建议先做两周内可完成的 App Server spike，再冻结 V1 选择。** App Server 最匹配产品需求，但官方命令参考仍把 `codex app-server` 标为 experimental；因此必须验证目标 Codex 版本、schema generation、Windows 进程行为、取消、resume 与升级兼容。[Codex CLI reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli)

如果 spike 不稳定，V1 可以退到 `codex exec --json` adapter，牺牲部分交互深度但不改变 Agent UI 或 capability architecture。

内嵌 Codex：

- 由用户安装和登录；应用只发现可执行文件、检查版本与诊断。
- 使用应用管理的隔离工作目录，默认不授予用户项目或任意文件系统访问。
- 只访问本应用公开 capability，使用与外部 Codex 相同的入口与权限。
- 插件保存 Codex session/thread reference 与可展示记录，不伪造模型上下文。
- Web 不注册 Agent 插件。

### 7.3 Multica 源码的启示

Multica 的官方架构由 Web 前端、Go 服务端和用户本机 agent daemon 组成；daemon 自动发现多个 Agent CLI、领取任务、创建隔离工作目录、启动 CLI 并流式回报状态。[Multica repository](https://github.com/multica-ai/multica)、[How Multica works](https://multica.ai/docs/how-multica-works)、[CLI and daemon](https://github.com/multica-ai/multica/blob/main/CLI_AND_DAEMON.md)

适合借鉴：

- discovery 与 execution 分开；
- 一个 Agent 类型一个 adapter，不让上层 UI 解析各家原始输出；
- runtime health/version 检测；
- supervisor 负责取消、超时、心跳、并发和日志；
- 标准任务/事件状态映射；
- 每次执行使用受控工作目录；
- 人类输出与 `--output json` 机器输出分离。

不适合照搬：

- 云服务、任务队列、轮询、团队 workspace 和 PostgreSQL；本项目已经确定 local-first、单用户、无后端。
- 同时支持十余个 Agent；V1 只实现 Codex，第二个真实 adapter 出现前不冻结过度抽象。
- 面向编码仓库的完整 agent 工作目录生命周期；内嵌 Codex V1 只编排本应用能力。

## 8. 首批插件纵向设计

### 8.1 宠物插件

桌面端使用独立透明悬浮窗口；Web 端只在页面内渲染。宠物引擎与一个内置资源包分开，资源声明 idle、notify、happy、warning、error 等语义动作和降级帧。

Codex Pets 的可借鉴点是：用 Running、Needs input、Ready、Blocked 等任务状态驱动表现；保存宠物选择和位置；遵循 reduced-motion；Web 宠物不假装拥有桌面浮层。[Codex Pets](https://learn.chatgpt.com/docs/pets)

对其他插件只暴露高层能力：

- `pet.present(message, options)`
- `pet.emote(emotion)`
- `pet.play(action)`
- `pet.isAvailable()`

不暴露帧、窗口坐标或渲染内部状态。

### 8.2 提醒插件

调度模型只有：

- `once`: timestamp + timezone；
- `cron`: 标准五段 cron + timezone。

桌面宿主运行时准时触发；休眠恢复后至多补发一次；用户彻底退出后不触发。Web 只保证页面/PWA 运行时触发。

呈现方式由 capability 选择：系统通知 provider 或宠物的 `notification.presenter`。宠物不可用/禁用/失败时回退系统通知。提醒数据属于 reminder 的独立存储，绝不读取 pet 数据表。

## 9. 自测与发布门禁

### 9.1 测试层级

1. **纯领域单元测试**：虚拟时钟、cron/DST、权限决策、能力注册、幂等、补偿、migration。
2. **插件契约测试**：manifest、生命周期、权限、能力 schema、成功/失败/拒绝/重试样例。
3. **Host conformance**：同一套测试跑 Electron host、Web host 和 Fake host。
4. **Adapter conformance**：同一能力 case 跑内部调用、CLI 与未来 MCP。
5. **AgentRuntime contract**：Fake Runtime 覆盖流式事件、取消、恢复、崩溃和乱序；Codex adapter 跑版本兼容 smoke。
6. **Web E2E**：控制中心、插件启停、提醒 CRUD、Web pet。
7. **Electron E2E**：托盘、关闭窗口仍常驻、透明宠物窗、点击区域、通知、IPC、Agent 进程。
8. **安装/升级 E2E**：签名产物安装、旧数据迁移、更新失败恢复、卸载。
9. **视觉与可访问性**：关键 UI 截图、宠物透明边缘、中文布局、reduced-motion、键盘和 screen reader 基线。

Playwright 提供 Electron automation API；官方仍将 Electron 支持标注为 experimental，因此不能只靠它验证原生通知与安装器，后两者需要平台脚本/人工可审计 smoke。[Playwright Electron](https://playwright.dev/docs/api/class-electron)

### 9.2 CI 门禁

每次提交：

- format/lint/typecheck/dependency boundaries；
- unit、property、contract；
- 核心基础设施 100% branch coverage；
- 变更不得降低约定覆盖率。

每个 PR：

- Web E2E；
- macOS、Windows Electron E2E；
- 插件 conformance；
- capability/CLI golden schema diff；
- migration from last released fixtures；
- 关键 UI visual regression。

发布前：

- 签名安装器与更新路径；
- 托盘、通知权限、宠物置顶/点击穿透；
- Codex supported-version matrix；
- 冷启动、异常退出恢复、日志导出；
- 安装、升级、回滚、卸载人工可审计 checklist。

每个 bug 先增加失败的回归测试。核心能力层加入 mutation testing，确认测试不仅执行代码，而且能杀死语义变更。

## 10. 初始化前必须完成的 spikes

按顺序做四个 throwaway prototype；它们回答架构问题，不进入产品代码：

1. **Electron pet window**：macOS/Windows 透明、置顶、拖动、交互区域与 click-through、多个显示器、睡眠恢复、reduced-motion。
2. **Codex App Server**：发现用户 Codex、initialize、thread start/resume、stream、interrupt、工具调用、受限 cwd、版本 schema generation；与 `codex exec --json` 对比。
3. **Capability vertical slice**：Fake host 中注册 `pet.present`，通过 generic CLI 调用，再由 reminder capability 消费，验证权限、幂等、补偿和降级。
4. **Updater/migration**：macOS/Windows 签名测试产物从 N-1 升到 N，失败后数据可恢复。

只有 spike 1 或 2 证明 Electron 存在不可接受问题时，才启动 Tauri 对照 spike。不要同时搭两套正式脚手架。

## 11. 分阶段路线

### Phase 0：仓库与决策基础

- 初始化 Git、pnpm workspace、TypeScript strict、统一 check 命令。
- 运行 Matt Pocock skills 的 repo setup，确定 issue tracker、domain docs 和 ADR 位置。
- 写 ADR：Electron、构建时插件、capability single source、AgentRuntime seam、local-first。
- 完成四个 spikes，更新 ADR。

### Phase 1：平台骨架

- contracts、plugin SDK、host runtime、Fake host。
- 插件 manifest、生命周期、隔离存储、权限、能力注册、receipts、审计。
- generic JSON CLI 与本地 IPC。
- contract/conformance CI。

### Phase 2：宠物与提醒

- 宠物引擎、资源包、桌面 overlay、Web 页面宠物。
- once + cron reminder、虚拟时钟、系统通知与宠物 presenter。
- macOS/Windows/Web E2E 与视觉回归。

### Phase 3：Codex Agent 插件

- AgentRuntime + Fake Runtime。
- Codex App Server adapter；若 spike 失败则用 exec JSONL adapter。
- 文本会话、流式输出、工具调用、授权、停止、恢复、诊断。
- 桌面专属 manifest 与 supported-version matrix。

### Phase 4：发布工程

- 签名、notarization、Windows code signing、用户确认更新、迁移备份与恢复。
- 安装/升级测试矩阵和诊断包导出。
- registry 稳定后评估并添加 MCP adapter。

## 12. 最终建议与暂缓项

### 现在决定

- Electron + TypeScript，React/Web renderer；桌面完整、Web 子集。
- 构建时可信插件；能力注册表是唯一业务调用面。
- CLI 是标准平台适配器，generic JSON 接口优先。
- AgentRuntime 留在 Agent 插件；V1 Codex-only，优先验证 App Server。
- macOS/Windows 真实 CI 和插件 conformance 是硬门禁。

### 暂缓

- 运行时第三方插件、Marketplace、进程级沙箱。
- Web Agent、自研 Agent、第二个真实 Local Agent adapter。
- 云账号、同步、服务器 Web Push。
- 应用商店发布。
- 复杂提醒规则、自然语言、日历和节假日。
- 静默自动更新。

### 仍需实测而非文档推断

- Electron 宠物窗在目标 macOS/Windows 版本的点击穿透和全屏行为。
- Codex App Server 的版本兼容与重新登录体验。
- Electron 的真实冷启动、内存和包体是否满足产品目标。
- Windows 通知 identity、签名安装器和 updater 的端到端细节。
- 外部 Codex 使用 generic CLI 与 MCP adapter 的实际工具发现质量。

