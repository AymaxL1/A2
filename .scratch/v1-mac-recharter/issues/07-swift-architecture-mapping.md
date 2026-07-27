# 07 — Swift 架构映射与工程形态

Type: grilling
Status: resolved
Blocked by: 03

## Question

把原调研文档 §4 的分层思想映射到 Swift 工程实体，与用户逐项定：

1. **SPM 包边界**：contracts / plugin-sdk / host-runtime / host-macos / host-testkit（Fake host）/ ui-system / plugin-pet / plugin-reminder / plugin-proxy 的 Swift 对应物；一仓多包 vs 单包多 target 的取舍；模块边界的编译期强制方式。
2. **app 壳工程**：Xcode 工程生成方式（XcodeGen / Tuist / 手管）；签名、公证、Sparkle 在 CI 的落位（全链路 CLI 化，AI 可自主跑「改-编-测-打包」）。
3. **CLI 形态**：同一二进制子命令 vs 独立可执行；宿主↔CLI 的本地 IPC 选型——须呼应 05 票的最关键 spike（Codex workspace-write 沙箱是否拦本地 IPC）。
4. **agent-first 接口面落地形态**（消费 05 票第 3 项）：能力命名与 schema 约定、发现文档形态（AGENTS.md / `--help` / `capabilities describe --json`）、`prefix_rule` 信任引导的产品化。
5. **mihomo 内核的打包与更新归属**（消费 02 票第 5/7 项）：宿主服务还是插件私有；重签+公证在构建链的位置。
6. **测试策略落地**（重建原文档 §9，Web 层删除）：swift-testing 纯包层 / 快照 / XCUITest 冒烟 / 诊断 CLI 的具体分工与 CI 门禁。

产出：可直接指导 Phase 0 脚手架的架构映射清单；新浮出的实施问题交回地图。

## Answer

**决定（2026-07-28，用户裁决 4 项 + 2 项按既定方向默认落地）：**

**1. 包结构：单 SPM 包、多 target（用户裁决）。** 一个 Package.swift；跨 target import 必须在清单声明依赖，编译期边界强制与多包等价；将来真需独立发版再拆包。Target 清单（AA 前缀为暂定命名，实施可调）：

- `AAContracts` — 能力契约类型、manifest 模型、风险分级枚举、CLI↔宿主 IPC 协议类型；零依赖底座
- `AAPluginSDK` — 插件作者面 API（依赖 Contracts）
- `AAHostRuntime` — 注册表、能力路由、dangerous 确认策略、事件订阅；纯逻辑（依赖 Contracts）
- `AAHostMacOS` — Host Port 的 macOS 实现：窗口/托盘/通知/系统网络设置/ProcessPort/UDS server（依赖 Runtime）
- `AAHostTestKit` — Fake host 与契约测试基建（测试专用）
- `AAUISystem` — 共享 UI 组件
- `PluginPet` / `PluginReminder` / `PluginProxy` — 每插件一 target，只依赖 SDK+Contracts+UISystem，**不得 import Host\***
- `aa` — CLI executable target，薄客户端（依赖 Contracts）

**2. app 壳工程：XcodeGen（用户裁决）。** `project.yml` 入库，`.xcodeproj` 生成物不入库；app target（`LSUIElement` 菜单栏应用）依赖本地 SPM 包；XCUITest target 在 Xcode 工程侧。构建链全脚本化：`xcodegen generate` → `xcodebuild build/test` → 统一重签内嵌二进制（mihomo、Sparkle 组件）→ `xcrun notarytool`。**CI 落位的现实约束**：本仓库当前无 git——门禁先落本地脚本（`Scripts/check.sh`：swift build + swift test + 快照；`Scripts/smoke.sh`：XCUITest 冒烟按需），将来上 git/GitHub 后原样迁移 Actions macOS runner。

**3. CLI 形态与 IPC：独立 `aa` 可执行 + Unix 域套接字（用户裁决）。** `aa` 随 .app 打包，`aa install-cli` 建 /usr/local/bin 符号链接；宿主起 UDS server（路径归实施），JSON 请求/响应协议、类型定义在 Contracts 与宿主共用；所有调用经宿主注册表（分级确认不可绕过）；CLI 永不交互阻塞——dangerous 触发宿主 GUI 确认，CLI 侧返回 pending/denied 语义。宿主未运行时 `aa` 明确报错并提示（可选 `--launch` 拉起，实施定）。**Codex workspace-write 沙箱是否放行 UDS = Phase 0 必做 spike**（排期归 08 票）；若被拦，备选顺位：localhost HTTP 短连（同 spike 验证）→ `prefix_rule` 提权文档化。

**4. Agent-first 接口约定（05 票结论默认落地，用户过目）。** 双层命令面：通用底座 `aa capabilities list | describe <id> | call <id> --json` + 人体工学域子命令（`aa proxy on|off|mode|node|update` 等，从注册表元数据映射）；全命令 `--json` 稳定机读输出 + 退出码语义；`aa docs agents-md` 输出可贴进任意仓库的 AGENTS.md 片段（教 Codex 何时用本 CLI）；文档提供 Codex `prefix_rule` 一行信任配置示例。能力命名 `域.动词`（04 票代理清单为首批实例）。

**5. 内核归属：插件私有资源 + 宿主 ProcessPort（用户裁决）。** mihomo 作为 `PluginProxy` 私有资源打进 .app；子进程拉起/健康检查/回收走宿主 ProcessPort（特权面归宿主、业务面归插件）；构建链统一重签+随 app 公证（见第 2 项）。不做通用「托管内核服务」抽象（YAGNI）。

**6. 测试策略落地（03 票方向默认落地，用户过目）。** 金字塔主体 = swift-testing 于纯逻辑 target（Contracts/Runtime/插件领域 + TestKit 的 Fake host 契约测试）；快照测试为视图层可 diff 的眼睛（产物图片供用户抽查——不读 Swift 也能行使监督）；XCUITest 仅 ~10 条冒烟路径（按需 + 发版前）；`aa` CLI 本身即端到端机器验证口。门禁：`check.sh` 每次改动必过，`smoke.sh` 发版前必过。

**交回地图**：无新雾——包命名细节、UDS 路径、`aa --launch` 等属实施细节，归 Phase 0 spec（本图 Out of scope「实施本身」）。

### S3 spike 结论回写（2026-07-28，用户确认）

第 3 项的沙箱悬念已由 S3 实测落定（`Spikes/S3CodexSandbox/README.md`）：workspace-write 沙箱内 UDS（工作区内外皆然）与 localhost TCP 全部 EPERM——预设的两条技术备选（UDS 直连、localhost 短连）在沙箱内均不成立。裁定：

- `aa` + UDS 设计**不变**（GUI、脚本、danger-full-access agent 均畅通）。
- 面向沙箱内 Codex 的官方姿态 = **`prefix_rule` 提权信任**：模型对 `aa` 命令声明 `require_escalated` + `prefix_rule ["aa"]`，用户一次批准持久化，此后 `aa` 在沙箱外执行。`aa docs agents-md` 输出与产品文档内置此引导——第 4 项「prefix_rule 信任引导的产品化」由候选升为**必做**。
- 远期薄 MCP adapter 优先级上调依据：MCP 工具调用不经 shell 沙箱（ADR 0005 第 5 条方向增强）。
