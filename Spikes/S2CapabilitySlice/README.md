# S2 — capability 纵切 spike（PROTOTYPE，抛弃式，不进产品）

> PROTOTYPE。本目录是 Phase 0 的探路原型，验证一条链在 Swift 上能否走通，**代码不进产品**、可整目录删除。
> 对应路线：`docs/v1-roadmap.md` §Phase 0「S2 capability 纵切 spike」。结论喂 `.scratch/v1-mac-recharter/issues/07-swift-architecture-mapping.md`（CLI 形态与本地 IPC）。

## 回答的问题

**能力注册表 → 菜单栏 → `aa` CLI → Unix 域套接字（UDS）→ dangerous 宿主确认，这条链在 Swift 上能否走通？**

结论：**能。** 全链打通，四项无人值守断言全 PASS（见下 Findings）。

## 构成

两个 swiftc 直编二进制（无 SPM），产物在 `.build/`：

- **`S2Host`**（GUI，菜单栏 ⚡）：极简能力注册表（硬编码 `demo.echo` safe / `demo.wipe` dangerous）+ POSIX UDS server + dangerous 宿主 `NSAlert` 确认。
  - socket：`~/Library/Application Support/S2Spike/aa.sock`（目录自建）。
  - 协议：每连接一行 JSON 请求 `{"capability":"demo.echo","input":{...}}` → 一行 JSON 响应 → 关连接。
  - 内置 `_list` 查询返回能力清单。
  - 环境变量 `S2_AUTO_DENY_SECONDS=<数字>`：dangerous 弹窗于 N 秒后自动拒绝（无人值守测试用，夜里不留挂着的对话框）。
- **`aa`**（CLI 薄客户端，纯 Foundation/Darwin，不 import AppKit）：
  - `aa list`：友好打印能力清单。
  - `aa call <capability> [--input '<json>'] [--timeout <秒,默认60>]`：stdout 只打响应 JSON，诊断走 stderr。
  - 退出码：`0`=成功 / `2`=denied / `3`=超时 / `4`=host 不可达 / `1`=用法或其它错误。
  - CLI 自身**永不交互提问**——确认只在宿主 GUI（产品原则）。

## 一条命令

```bash
# 编译两个二进制
bash Spikes/S2CapabilitySlice/run.sh

# 无人值守自测（编译→起 host→四断言→清场，全 PASS 才算过）
bash Spikes/S2CapabilitySlice/test.sh
```

`test.sh` 结束会 `pkill` 清场，不留 S2Host 进程。运行中 dangerous 弹窗会在屏幕闪现几秒（自动拒绝），属正常。

## 明早人工验收清单（真人交互，test.sh 不覆盖的部分）

前台起 host（不设自动拒绝，才能真点）：

```bash
bash Spikes/S2CapabilitySlice/run.sh
./Spikes/S2CapabilitySlice/.build/S2Host      # 前台运行，看日志；另开一个终端跑 aa
```

1. **菜单栏清单**：顶部栏出现 ⚡ 图标；点开菜单看到两条只读能力项（`demo.echo · safe · …`、`demo.wipe · dangerous · …`）+「退出」。
2. **safe 直通**：`aa call demo.echo --input '{"hello":"world"}'` → stdout 打回显 JSON（含 `echo` 与 `timestamp`），退出码 0，**不弹窗**。
3. **dangerous 确认（approve）**：`aa call demo.wipe` → 宿主弹出 critical `NSAlert`（应被 activate 带到前台）→ 点「确认执行」→ CLI 拿到 `{"ok":true,"result":{"approved":true}}`，退出码 0。
4. **dangerous 拒绝（deny）**：再 `aa call demo.wipe` → 点「取消」→ CLI 拿到 `{"ok":false,"error":"denied"}`，退出码 2。
5. **host 不可达**：菜单栏「退出」关掉 host → `aa call demo.echo` → stderr 报不可达，退出码 4。

（若弹窗偶尔藏在别的窗口后：cmd-tab 或点一下 ⚡ 即可带到前台；见 Findings 备注。）

## Findings（实测结果，2026-07-28）

**test.sh：PASS=7 FAIL=0，ALL PASS，退出码 0。** 四断言：`aa list` 含两能力(exit0) / `aa call demo.echo` 回显(exit0) / `aa call demo.wipe --timeout 10` 自动拒绝(exit2) / host 关闭后 `aa call` 不可达(exit4)。host 日志完整记录了 `_list`、`demo.echo`、`demo.wipe`（5s 自动拒绝计时到 → denied）的请求/响应。

**踩坑与解法（直接可喂 07 票实施）：**

1. **overlay 旗标对纯 Foundation 也必需**——不止 AppKit。
   `aa` 完全不 import AppKit（纯 Foundation/Darwin），仍报 `redefinition of module 'SwiftBridging'`（CLT 的 `module.modulemap` 与 `bridging.modulemap` 重复定义），并连带 `failed to build module 'Foundation'`。加 `-vfsoverlay …/S1PetOverlay/toolchain-workaround/overlay.yaml` 后即过。
   → **结论：本机所有 swiftc 直编都要挂这份 overlay，与是否用 AppKit 无关；这是 CLT 层坏 modulemap。** 上了正常 Xcode/SPM 后该旗标可整体移除。

2. **UDS 在 Swift 走通，`sockaddr_un.sun_path` 是唯一别扭点。**
   `socket(AF_UNIX,SOCK_STREAM,0)` → `unlink`(清旧文件，UDS 文件不随进程退出自动删) → `bind` → `listen` → `accept` 全部用 `import Darwin` 的 POSIX 原样可用。`sun_path` 被导入成 104 长的 `CChar` 元组，只能 `withUnsafeMutablePointer(to:&addr.sun_path)` + `withMemoryRebound(to:UInt8.self)` 逐字节填 + 补 `\0`；并设 `addr.sun_len`。路径 `~/Library/Application Support/S2Spike/aa.sock` 约 60 字符，远低于 104 上限，无截断。bind/connect 需把 `sockaddr_un*` rebind 成 `sockaddr*` 传入。

3. **线程切换模型（关键，产品可直接沿用）：**
   - `accept` 循环跑在专用后台串行队列；每条连接派发到**并发**队列独立处理——这样一条连接卡在 dangerous 确认时，不拖住 accept 与其它连接。
   - 连接处理线程（后台）需要弹窗时，经注册表注入的 `confirmDangerous` 回调 `DispatchQueue.main.sync { NSAlert().runModal() }` **同步**切回主线程，阻塞本连接直到用户/自动决定，再把 Bool 结果带回后台线程写响应。无死锁（主线程空闲时 run 该 block，进入嵌套模态循环）。
   - 注册表是纯逻辑、零 AppKit：GUI 确认由宿主注入回调实现——正好落 07 票「AAHostRuntime 纯逻辑可单测 / AAHostMacOS 提供 GUI 确认」的分层。

4. **dangerous 弹窗 activate + 自动拒绝定时器：**
   - accessory app（无 Dock 图标）弹 `NSAlert` 前必须 `NSApp.activate(ignoringOtherApps:true)` 才能把窗带到前台。
   - `S2_AUTO_DENY_SECONDS` 的定时器**必须加进 `.modalPanel` run-loop 模式**（`RunLoop.main.add(t, forMode:.modalPanel)`），否则 `runModal()` 的模态循环里 `.default` 模式的 Timer 不触发、弹窗永不自动关。到点用 `NSApp.stopModal(withCode:.alertSecondButtonReturn)` 把 `runModal()` 唤回并判为拒绝。实测 5s 精准触发。

5. **stdout/退出码语义（CLI↔宿主契约雏形）：**
   - 响应约定 `{"ok":true,"result":{…}}` / `{"ok":false,"error":"denied"}` / `{"ok":false,"error":"<码>","detail":…}`；CLI 据此映射退出码。
   - 超时用 `setsockopt(SO_RCVTIMEO)`，read 返回 `EAGAIN/EWOULDBLOCK` → exit 3；`connect` 失败（文件不存在=ENOENT / 无监听=ECONNREFUSED）→ 统一 exit 4。
   - stdout 只放响应 JSON / 清单，诊断（`→ 调用 …`）全走 stderr，便于机读。
   - `print` 后一律 `fflush(stdout)`（stdout 重定向到文件时块缓冲，不 flush 看不到实时日志）。

6. **swiftc 直编工程形态（沿用 S1）：** `@main @MainActor struct S2Main { static func main() }` 做入口（顶层代码不是 MainActor 上下文，不能在 main.swift 顶层构造 @MainActor 对象）；GUI 端多 .swift 文件（无 main.swift）；CLI 端单 `main.swift` 用顶层代码即可。统一 `-swift-version 5`（Swift 5 语言模式，并发检查为 minimal，`main.sync` 里调 `@MainActor` API 不报错）。

**无关紧要的观察：** test.sh 输出里的 `Terminated: 15 … S2Host` 是 shell 对被 `pkill` 的后台作业的作业控制提示，非错误。日志时间戳为 UTC（ISO8601 默认 `Z`），与本地日期差 8 小时属正常。

**遗留问题（超出本 spike 范围，留给 Phase 1 / 07 票）：**

- 沙箱放行未验：**Codex workspace-write 沙箱下 `aa` 连宿主 UDS 是否被拦 = S3 spike**（本 spike 只在无沙箱下证明链路可通）。若被拦，备选顺位 localhost HTTP 短连 → `prefix_rule` 提权（见 roadmap Phase 0 回退硬门③）。
- 协议健壮性简化：单行 JSON、单字节读到 `\n`、无 framing/长度前缀、无并发压测、socket 文件权限用默认（0755 目录 + 默认 umask）。产品化需定 framing、鉴权（同用户 UDS 已隔离到 home，但多用户/越权需评估）、超大 payload。
- 契约要素未落全：ADR 0004 要求的 schema/幂等键/重试/结构化错误码/版本号本 spike 只给了最小响应形状，未做 JSON Schema 校验与版本协商。
- 类型未共享：两个二进制各自用 `JSONSerialization` 处理线格式（无共享 Swift 类型）。产品里协议类型应落 `AAContracts` target 供宿主与 `aa` 共用（07 票第 1 项）。
- 弹窗前台性：accessory app 的 `NSAlert` 偶有被其它窗口盖住的可能；产品或需更强的置前策略（临时切 `.regular` 激活策略 / 专用确认窗）。
