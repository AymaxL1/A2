# 03 — capability 纵切与 CLI/UDS:S2/S3 在 Electron 的等价形态

Type: research
Status: open

## Question

S2 纵切(注册表→菜单栏→`aa` CLI→UDS→dangerous 宿主确认弹窗,Swift 全链已通)与 S3 结论(codex 沙箱)在 Electron+Node 上的等价与差异:

1. **UDS server**:Node `net.createServer` 监听 unix socket 的成熟度(权限位、sun_path 长度限制、废 socket 清理——S2 在 Swift 踩过的坑对应过来)。
2. **菜单栏与确认弹窗**:`Tray` + 菜单;dangerous 确认用 `dialog.showMessageBox` 还是独立小 `BrowserWindow`;无 dock 图标(LSUIElement 等价)下弹窗的前台激活问题。
3. **`aa` CLI 的分发形态**(关键设计题,列选项+推荐):独立 Node 脚本(要求用户机器有 node?不可接受则——)/打包单二进制(bun build --compile、pkg、Node SEA 的 2026 现状)/复用 app 自带运行时(`ELECTRON_RUN_AS_NODE=1 <app>/Contents/MacOS/... aa.js` 的可行性与丑陋度)。对比 Swift 路线 `aa` 是原生二进制这一优势。
4. **S3 结论的栈无关性核查**:S3 实测 codex workspace-write 沙箱内 UDS/localhost TCP 全 EPERM,幸存路径=`prefix_rule` 提权(命令在沙箱外执行)。论证:被拦的是 codex 侧客户端进程的 connect(2),与宿主 app 用什么语言监听无关;宿主换 Electron 后 `prefix_rule` 信任的对象仍是 `aa` 前缀,结论原样成立——确认或推翻,写明推理与证据。
5. **IPC 安全基线**:contextIsolation/sandbox 下渲染进程与主进程分工(注册表逻辑放主进程,渲染只做壳)——对照 ADR 0004(注册表唯一调用面)给出 Electron 版进程拓扑草图。

## Context

- S2 经验:`Spikes/S2CapabilitySlice/README.md`(线程切换、sun_path 等实施经验);S3:`Spikes/S3CodexSandbox/README.md`;07 票架构映射:`.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md`(CLI=UDS 薄客户端、双层命令面、`aa docs agents-md`)。
- 原调研文档 §5(插件模型)/§6(CLI 设计)是栈无关保留章节,Electron 版直接沿用,本票只补 Electron 特有的实现差异。

## Output

`docs/research/electron-recon/capability-cli.md`(中文;CLI 分发形态一节必须给出明确推荐+理由,这是明天裁决要用的)。
