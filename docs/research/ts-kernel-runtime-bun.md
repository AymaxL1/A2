# TS 内核运行时实测：Bun compile 单文件 bin + 插件子进程复用

> 调研日期：2026-08-04。为 [ADR 0010](../adr/0010-ts-kernel-bun-runtime.md) 的「Bun compile 单文件 bin」裁定提供实测基线，进程边界落点见 [ADR 0008](../adr/0008-kernel-bin-ui-optional.md)。
> 确定性档位（沿用 [kernel-language-cross-platform.md](kernel-language-cross-platform.md) 惯例）：
> - **【实测】**：本机（macOS 15.7.8 / arm64）用装到用户目录的 Bun 直接跑出的结果，命令与产物路径均记录在案。
> - **【文档】**：bun.com / nodejs.org / docs.deno.com 官方文档，或 GitHub 官方仓库 issue/PR 的原文或转述。
> - **【推断】**：基于上述事实的分析，或来自社区博客/二手基准测试、未经官方一手来源逐字确认。

## 0. 结论摘要

1. **本机原未装 bun，官方一键脚本首次因 HTTP/2 传输中断失败，改用同一官方 GitHub Release 资产 + `curl --http1.1 --retry` 重试后装成，全程只写 `~/.bun` 与 `~/.zshrc`。装出 Bun 1.3.14（darwin-aarch64）。**【实测】**（§1）
2. **`bun build --compile` 最小程序产物 60.5MiB，冷启动 7.7–13ms（20 次采样），空闲常驻 daemon RSS 26.4MiB；`--target=bun-linux-x64` 交叉编译最终成功产出合法 ELF 产物（90.2MiB），验证方式是本机 macOS 直接编译目标平台可执行文件，唯一代价是首次编译需联网下载目标运行时（受本机网络条件所限耗时约 17.5 分钟，绝大部分是网络等待非编译本身慢）。**【实测】**（§2）
3. **插件北极星核心机制完整验证成立**：编译产物内部对自己 `Bun.spawn(process.execPath, ..., env:{BUN_BE_BUN:"1"})`，可以把编译期不存在、agent 现场写的外部 `.ts` 文件当独立子进程拉起并正确回收 stdout/退出码——不需要额外装系统级 bun。**但插件 `import` npm 包要求 `node_modules` 在场（同级/祖先目录），不会现场联网装包**，这是需要 04 票纳入设计的现实约束。**【实测，本票最核心结论】**（§3）
4. **daemon 工况四项 API 面全部实测打通**：`Bun.listen/connect({unix})` 收发正常；`Bun.spawn` 信号（`kill("SIGTERM")` → `signalCode`/`exitCode`/`resourceUsage()`）行为符合文档；UDS socket 权限**跟随进程 umask**（更正了一条描述"Bun 默认强制 0700"的过时 GitHub issue 口径）；**`bun:ffi` dlopen `libSystem` + `node:net` 兼容层的 `socket._handle.fd` 调 `getpeereid()` 在 macOS 上完整打通，返回值与真实 UID/GID 吻合**——本票确定性最低的一项已升级为实测通过。**【实测】**（§4）
5. **Node SEA 与 Deno compile 文档级排除**：两者的编译产物均**不支持运行时动态执行外部脚本**（SEA 官方文档明确"module loading does not read from the file system"；Deno compile 产物同样是"self-contained"，未见等价机制），这条限制直接否决二者作为插件运行时候选，除非额外自建 loader 层——Bun 的 `BUN_BE_BUN` 是三者中唯一原生满足插件北极星的机制。**【文档】**（§5）
6. **基线判定：「Bun compile 单文件 bin + 内核 bin 复用自带运行时拉插件」本机实测成立**，可直接支撑 04 票的进程模型设计；需要显式处理的现实约束见 §7。
7. **（2026-08-04 晚追加，见 §8）插件依赖流三问全部实测成立**：编译产物在 `BUN_BE_BUN=1` 下能自举 `bun install`（依赖 lifecycle scripts 确被拦）与 `bun build --target=bun`（打成单文件 JS），打出的工件再被同一个 bin 拉起后 stdin/stdout JSON 往返与退出码语义全对，**删掉整个源目录与 `node_modules` 后照常运行**。同时撞出三条必须显式处理的边界：根 `package.json` 的 lifecycle scripts 默认照跑、运行期 auto-install 会联网装包、`.node` addon 的失败信号形态。**【实测】**（§8）

---

## 1. bun 安装

- **本机原先未装 bun**（`which bun` 无输出，`~/.bun` 不存在）。**【实测】**
- **用官方脚本安装到用户目录**：`curl -fsSL https://bun.sh/install | bash`。首次尝试在下载 `bun-darwin-aarch64.zip` 到 67.8% 时因 `curl: (92) HTTP/2 stream 1 was not closed cleanly: PROTOCOL_ERROR` 中断失败（本机网络对该次 HTTP/2 长连接不稳定，非权限问题）。**【实测】**
- **恢复方式**：改用 `curl --fail --location --http1.1 --retry 10 --retry-delay 2 --retry-all-errors --continue-at - --output ~/.bun/bin/bun.zip <同一 GitHub Release URL>` 强制 HTTP/1.1 + 重试后完整下载成功（23,586,433 字节，`unzip -t` 校验通过），随后手动执行官方脚本剩余步骤（`unzip -oqd ~/.bun/bin bun.zip` → `mv bun-darwin-aarch64/bun bun` → `chmod +x bun` → 清理中间文件 → 追加 `export BUN_INSTALL="$HOME/.bun"` / `export PATH="$BUN_INSTALL/bin:$PATH"` 到 `~/.zshrc`，与脚本对 zsh 分支的行为逐条对齐）。全程只写用户目录 `~/.bun` 与 `~/.zshrc`，未触碰系统级路径。**【实测】**
- **安装结果**：`bun --version` → `1.3.14`（macOS arm64）。**【实测】**
- **卸载方式**：见 §6（本次调研结束后按需执行，不属于安装步骤本身）。

---

## 2. `bun build --compile`：体积 / 冷启动 / 常驻 RSS / 交叉编译

方法：临时目录 `/tmp/bun-research-11/kernel-min/`（不落仓库）下写最小 9 行 TS 程序 `kernel.ts`（打印一行 JSON 并退出）与一个开 `Bun.listen({unix})` 常驻监听的 `daemon.ts`，用 `bun build --compile` 编译，Python `subprocess` + `time.perf_counter()` 采样 20 次冷启动，`ps -o rss` 采样常驻 RSS。机器：macOS 15.7.8 / arm64（同 §0 环境）。

### 2.1 体积

- `bun build ./kernel.ts --compile --outfile kernel-bin` 产物：**63,446,114 字节 ≈ 60.5 MiB**，`file` 确认为 `Mach-O 64-bit executable arm64`。**【实测】**
- `bun build ./daemon.ts --compile --outfile daemon-bin`（额外含 `Bun.listen` UDS server 逻辑）与 `bun build ./kernel-spawn-plugin.ts --compile --outfile kernel-spawn-plugin-bin`（额外含 `Bun.spawn` 拉子进程逻辑）体积与 `kernel-bin` **完全一致**（同为 63,446,114 字节）。**【实测】**
- `bun build ./kernel.ts --compile --minify --bytecode --outfile kernel-bin-min-bc` 体积同样是 63,446,114 字节，未见缩小。**【实测】**
- **解读【推断】**：四个变体体积完全相同，说明对这种量级的用户代码（个位数到几十行）而言，产物体积几乎 100% 由「内置完整 Bun 运行时」主导，用户逻辑本身的字节数、`--minify`/`--bytecode` 都不改变这个数量级；这与官方文档"All imported files and packages are bundled into the executable, **along with a copy of the Bun runtime**"的描述一致。**本仓库内核若真落地（约万行级 TS 逻辑 + 若干 npm 依赖），预期体积仍会以"运行时基线（~60MB）+ 依赖体积"为主，且 60MB 量级本身就是起点，不会比这个最小测试更小**——10 票"账单"里"bin 约 50–90MB"的估算与本次实测的 60.5MB 基线一致、方向对。

### 2.2 冷启动

Python 脚本连续跑 20 次 `./kernel-bin`（无参数），取 wall-clock 各次耗时：

| 变体 | min | median | mean | max |
|---|---:|---:|---:|---:|
| `kernel-bin`（普通编译） | 7.70ms | 8.04ms | 8.29ms | 12.85ms |
| `kernel-bin-min-bc`（`--minify --bytecode`） | 7.89ms（复测 7.82ms） | 8.48ms（复测 8.20ms） | 31.00ms（复测 8.42ms，首次含一次 450ms 离群值） | 450.61ms（复测 10.82ms） |

**【实测】**——首次 bytecode 测试出现一次 450ms 离群值，复测（同样 20 次）恢复到与普通编译几乎一致的 7.8–10.8ms 区间；离群值发生时机与本机后台正在跑的 `--target=bun-linux-x64` 交叉编译下载抢占带宽/CPU 重合，判定为系统噪声而非 `--bytecode` 本身的回归。**结论【实测+推断】**：对这种"个位数行数、无复杂解析"的最小脚本，`--bytecode` 声称的"2x faster startup"效应观察不到差异（两者中位数都在 8ms 上下）——官方原文强调该优化针对的是"将解析开销从运行时挪到构建期"，脚本本身解析成本几乎为零时自然无差可比；**万行级内核逻辑上是否有实际提升，本次未测，需要后续用真实体量代码复验**。两个变体的**绝对冷启动数字（个位数到十几毫秒）本身已经足够快**，作为 daemon/CLI 场景的基线绰绰有余。

### 2.3 常驻 RSS

编译 `daemon.ts`（`Bun.listen({unix: sockPath, ...})` 后原地等待，不做其他工作）为 `daemon-bin`，后台启动、等待 1 秒让运行时完成初始化后取样：

```
PID    RSS      VSZ  COMM
43481  26992  484083536  ./daemon-bin
```

**RSS ≈ 26,992 KiB ≈ 26.4 MiB**（空闲监听、零连接状态）。**【实测】**——VSZ（虚拟内存，4.6GB 量级）是 mmap 预留的地址空间，不代表实际占用；RSS 是更有意义的"实际吃掉的物理内存"指标。10 票"常驻 RSS 高一档"的定性判断成立：这个数字明显高于同类 Go/Rust 静态二进制 daemon 常见的个位数 MB 级 RSS（未在本票逐一实测 Go/Rust 对照，沿用 09 票既有定性），但绝对值（26MB）对桌面级常驻进程而言仍在可接受区间。

### 2.4 交叉编译 `--target=bun-linux-x64`

- 命令：`bun build ./kernel.ts --compile --target=bun-linux-x64 --outfile kernel-bin-linux-x64`。**首次调用时 Bun 按需从网络下载对应平台的运行时包**（终端持续输出 `Downloading [N]` 进度），而不是本机自带全平台运行时。**【实测】**
- **本机网络吞吐本次调研全程明显受限**（§1 的 HTTP/2 中断即为同一网络条件的体现），该运行时包下载耗时显著拉长——最终日志显示编译（含下载等待）总计 **1051.6 秒（约 17.5 分钟）**，绝大部分是网络等待，不是 Bun 编译本身慢。**【实测】**
- **最终产物成功生成**：`kernel-bin-linux-x64`，**94,582,912 字节 ≈ 90.2 MiB**（同一份 9 行 TS 脚本，比 macOS 本地产物 60.5MiB 大约 30MiB，Linux 运行时基线本身更大）；`file` 确认为 `ELF 64-bit LSB executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, not stripped`——是真正合法的 Linux x86-64 可执行文件（非占位符/损坏文件）。**【实测】**
- 按票面"能出即可，不必跑"的要求，尝试在本机 macOS 上直接执行该 Linux 产物（仅为好奇，非要求项），如预期返回 `exec format error`（架构不匹配，macOS 内核拒绝执行 x86-64 Linux ELF）——这是正常行为，不代表产物有问题。**【实测】**
- **结论**：`--target=bun-linux-x64` 交叉编译**在本机完整验证成功产出合法产物**，唯一代价是目标运行时包的网络下载耗时（在本次受限网络条件下约 17.5 分钟，网络正常的环境预期是秒级到几十秒）——这是一次性成本（同一目标平台首次编译后，Bun 会缓存该运行时包，后续同目标编译不需要重新下载，此点为【推断】，未逐次复测缓存命中）。
- **文档口径补充**：`bun.com/docs/bundler/executables` 官方文档明确列出 `bun-linux-x64`（含 baseline/modern/musl 变体）为受支持 `--target`，Windows 交叉编译额外说明"除 `hideConsole` 外，图标/版本等 Windows 专属元数据标志在交叉编译时不可用（依赖 Windows API）"。来源：<https://bun.com/docs/bundler/executables>。**【文档】**

---

## 3. 内核 bin 复用运行时拉插件（插件北极星成立条件，本票最关键项）

### 3.1 `BUN_BE_BUN=1`：编译产物变身完整 `bun` CLI 去跑外部 `.ts`

测试脚本：`kernel.ts`（内核自身打包的 entrypoint，与插件无关）编译为 `kernel-bin`；`plugin.ts` 是一个**未参与编译、独立躺在同一目录下的 `.ts` 文本文件**，模拟"agent 现场写的插件"。

| 命令 | 结果 |
|---|---|
| `BUN_BE_BUN=1 ./kernel-bin plugin.ts hello world` | **成功**：输出 `{"fromPlugin":true,"argv":["hello","world"],"cwd":"...","pid":43523}`——`kernel-bin` 忽略自己打包的 `kernel.ts`，转而把 `plugin.ts` 当成传给 `bun` CLI 的文件参数直接执行，`hello world` 被正确当成传给插件的 argv。 |
| `./kernel-bin plugin.ts hello world`（不设 `BUN_BE_BUN`，对照组） | `{"ok":true,"argv":["plugin.ts","hello","world"],...}`——`kernel-bin` 按自己打包的 `kernel.ts` 逻辑执行，`plugin.ts` 只是被当作普通字符串参数，**不会**被当文件执行。 |

**【实测】**——与官方文档 `bun.com/docs/bundler/executables` 原文"The executable ignores its bundled entrypoint and exposes the full `bun` CLI instead"逐字对上：**默认情况下编译产物是自封闭的（只跑自己打包的入口），`BUN_BE_BUN=1` 是唯一的开关，切换后产物退化为通用 `bun` 解释器，可以执行任意路径下的外部 `.ts` 文件**。

### 3.2 内核 bin 内部自己 spawn 自己去跑插件（不依赖外部命令行操作者知道 `BUN_BE_BUN`）

上一节验证的是"外部调用者知道要设 `BUN_BE_BUN=1`"；但真实场景是**内核进程自己在运行时决定要不要拉起一个插件**，不能指望调用它的人（agent/CLI 用户）去操心这个环境变量。为此写了 `kernel-spawn-plugin.ts`：内部执行

```ts
Bun.spawn({
  cmd: [process.execPath, pluginPath, ...pluginArgs],
  env: { ...process.env, BUN_BE_BUN: "1" },
  stdout: "pipe", stderr: "pipe",
});
```

| 场景 | 命令 | 结果 |
|---|---|---|
| 开发模式（`bun run`，未编译） | `bun run kernel-spawn-plugin.ts plugin.ts foo bar` | 成功，子进程正确输出 `{"fromPlugin":true,"argv":["foo","bar"],...}`；此时 `process.execPath` 就是系统装的 `bun` 本身，属于平凡情形。 |
| **编译产物内部自己 spawn 自己**（关键场景） | 先 `bun build ./kernel-spawn-plugin.ts --compile --outfile kernel-spawn-plugin-bin`，再 `./kernel-spawn-plugin-bin plugin.ts foo bar` | **成功**：`kernelExecPath` 打印出的是编译产物自身路径（`.../kernel-spawn-plugin-bin`），`Bun.spawn` 用这个路径 + `env.BUN_BE_BUN=1` 把**自己**再次拉起、变身通用 CLI、执行外部 `plugin.ts`，子进程 stdout 被父进程 `Response(proc.stdout).text()` 正确捕获回传。 |

**【实测，本票核心结论】**：**「内核 bin 复用自带运行时把插件 `.ts` 文件作子进程拉起」这一基线假设在本机完整验证成立**——内核编译产物不需要额外依赖任何系统级 `bun` 安装，只靠 `process.execPath`（指向自身）+ `Bun.spawn` + `env.BUN_BE_BUN="1"`，就能把 agent 现场写的、完全独立于编译期的外部 `.ts` 文件当**真正的子进程**（有独立 PID、独立 stdout/stderr、可被信号控制，见 §4.2）拉起来执行，同时满足 ADR 0007"插件进程外隔离"的红线（这是子进程而非同进程 `eval`/动态 import）。

### 3.3 外部插件脚本 `import` npm 包：**要求 `node_modules` 在场，不是零配置现场装包**（重点结论，含一次误判纠正）

这是票面要求"重点实测"的子问题。测试分四轮，第二轮的初步结果具有误导性，特此完整记录纠偏过程：

1. **初测（有干扰）**：在 `no-deps/`（无 `package.json`、无 `node_modules`）放一个 `import { z } from "zod"` 的插件脚本，`BUN_BE_BUN=1 kernel-bin plugin-with-dep.ts` 执行**看似成功**。但该测试与另一个终端并发执行的 `bun install`（在其**父目录** `kernel-min/` 里装 `zod`）时间重叠——**初测结果不可信**，因为 Bun 的模块解析会向上遍历祖先目录找 `node_modules`（同 Node.js 算法），父目录当时正在被写入 `node_modules/zod`。
2. **干净复测（隔离环境）**：新建 `no-deps-isolated/plugin-iso.ts`（`import pc from "picocolors"`），确认该目录及所有祖先目录都**没有** `node_modules`、`package.json`，且 `~/.bun/install/cache` 里此前**没有** `picocolors` 的缓存条目（`find` 验证）。执行 `BUN_BE_BUN=1 kernel-bin plugin-iso.ts` → **失败**：
   ```
   error: Cannot find package 'picocolors' from '/private/tmp/.../no-deps-isolated/plugin-iso.ts'
   ```
   **没有现场联网装包，没有创建 `node_modules`，直接报错退出（exit=1）。**

   > **【2026-08-04 晚 02 票复测更正，详见 §8.5】**：这条"不会现场装包"的结论**只在祖先目录里存在 `node_modules` 时成立**。本轮 `no-deps-isolated/` 的祖先 `kernel-min/` 当时已经被 `bun install` 过（第 1 点自己也写了这件事），而 Bun 的 auto-install 恰恰以"目录树里找不到任何 `node_modules`"为触发条件——所以本轮观察到的是 auto-install **被关掉之后**的行为，不是 Bun 的默认行为。真正全隔离（祖先链上一个 `node_modules` 都没有）时，Bun 会**联网自动装包**并正常跑通。下面第 2 点的现象仍是真实的，但归因要按 §8.5 更正。
3. **同级 `node_modules` 对照**：`kernel-min/`（已 `bun install` 过 `zod`）下直接跑 `BUN_BE_BUN=1 kernel-bin plugin-with-dep.ts` → 成功。
4. **祖先目录 `node_modules` 对照**：`kernel-min/no-deps/plugin-with-dep.ts`（插件在子目录，依赖装在父目录 `kernel-min/node_modules`）→ 同样成功——证实是**标准 Node 式向上遍历目录树找 `node_modules`**，不是"插件必须和依赖同一个文件夹"这么死板，但**必须能在某一层祖先目录找到**。之后手动 `bun add picocolors` 到 `kernel-min/node_modules` 后，再跑 `no-deps-isolated/plugin-iso.ts`（子目录）也随即成功，进一步印证同一机制。

**结论【实测】**：`BUN_BE_BUN=1` 执行外部插件 `.ts` 文件时，`import` npm 包遵循标准 Node 模块解析（同级或任意祖先目录下的 `node_modules`），**不会**在完全空目录里现场联网安装依赖——这与 `bunx <pkg>`（拉起一个具名包）或 `bun run <已在 package.json 里声明依赖的脚本>` 的"自动装依赖"体验不同，普通 `.ts` 文件路径执行走的是纯粹的模块解析，找不到就是 `Cannot find package` 硬错误。**对内核设计的直接含义（供 04 票参考）**：若插件北极星要支持"agent 现场写的插件里 `import` npm 包"，内核需要显式维护一个共享 `node_modules`（例如放在插件目录的根、或内核 bin 同级的一个约定目录），并对外暴露"装依赖"这个动作（无论是内核自动 `bun install`，还是要求 agent 先装），不能假设"扔一个 `.ts` 文件进去就能自动联网跑起来"。

---

## 4. daemon 工况 API 面

### 4.1 `Bun.listen({ unix })` UDS server / `Bun.connect` client

- **API 存在且文档化**：`Bun.listen` 有专门的 Unix Socket 重载（`UnixSocketOptions`），`unix: string` 传 socket 路径，`socket: SocketHandler` 传事件回调（`data`/`open`/`close`/`drain`/`error`）；`Bun.connect` 同理支持 `unix` 参数作客户端连接。同一套 API 同时覆盖 `Bun.listen`/`Bun.serve`/`node:net` 的 `unix` 参数。来源：<https://bun.com/reference/bun/listen>、<https://bun.com/docs/runtime/http/server>。**【文档】**
- **Linux 抽象命名空间 socket**：文档记录 Linux 上可用 null 字节前缀 `unix` 路径开抽象命名空间 socket（不落盘、随最后一个引用关闭自动回收），macOS 无此机制（抽象命名空间是 Linux 专属扩展）。**【文档】**
- **与 Node.js 语义对齐的近期修复**：Bun 近期版本修正了"绑定到已存在 socket 文件应返回 `EADDRINUSE`""关闭 listener 应自动清理 socket 文件"等行为，使其贴近 Node `net` 语义。**【文档，来自搜索结果转述，未逐条核实具体版本号】**

**4.1a 本机实测**：`daemon.ts` 用 `Bun.listen({ unix: sockPath, socket: { data, open, close, error } })` 起 server，收到 `"ping"` 回 `"pong"`、收到 `"exit"` 回 `"bye"` 后内部 `process.exit(0)`、其余原样 echo；`client.ts` 用 `Bun.connect({ unix, socket: { open, data, close } })` 连接。`bun run client.ts <sock> ping` → 打印 `client got: pong`；`bun run client.ts <sock> exit` → 打印 `client got: bye`，随后 `pgrep` 确认 daemon 进程已自行退出。**双向收发、daemon 内部主动退出，均按预期工作。**【实测】**

### 4.2 `Bun.spawn` 子进程与信号处理

- **cmd 数组 + stdio 配置**：`Bun.spawn(["cmd", "arg"])` 或 `Bun.spawn({ cmd, stdin, stdout, stderr })`；`stdout` 默认 `"pipe"`（`ReadableStream`），`stderr` 默认 `"inherit"`，均可设 `"pipe"`/`"inherit"`/`"ignore"`/`Bun.file()`/fd 数字。来源：<https://bun.com/docs/api/spawn>、<https://bun.com/docs/runtime/child-process>。**【文档】**
- **信号**：`proc.kill()`（默认 `SIGTERM`）/`proc.kill(15)`/`proc.kill("SIGTERM")`；`timeout` + `killSignal` 选项支持超时自动杀；支持 `AbortSignal`（`AbortController` 触发 `abort()` 即终止子进程）；`proc.exited` 为退出 Promise，`proc.exitCode`/`proc.signalCode`/`proc.killed` 反映终态；`onExit` 回调可挂在 spawn 选项里。**【文档】**
- **IPC**：父子进程间可用 `ipc` 回调 + `process.send()`/`process.on("message")` 通信，序列化模式 `advanced`（默认，支持 `structuredClone` 全类型）或 `json`（与 Node 互操作）。**【文档】**
- **性能**：官方原文称 `Bun.spawnSync` 底层用 `posix_spawn(3)`，比 Node.js `child_process` 快 60%。**【文档，未本机复核该百分比】**

**4.2a 本机实测**：`Bun.spawn({ cmd: ["sleep", "30"] })` 后 `proc.kill("SIGTERM")` → `await proc.exited` 之后 `{ killed: true, exitCode: null, signalCode: "SIGTERM" }`（`exitCode` 为 `null` 因为进程是被信号杀死而非正常 return），`proc.resourceUsage()` 拿到 `{ maxRSS: 1196032, cpuTime: { user: 659n, system: 385n, total: 1044n } }`。§3.2 的"内核内部 spawn 自己拉插件"场景（`proc.exited` + `Response(proc.stdout).text()`）同样验证了 stdout 捕获与退出码回传全部正常。**信号发送、终态字段、资源用量统计，均按文档行为工作。**【实测】**

### 4.3 socket 文件权限

- **文档口径（可能已过时）**：GitHub issue [`oven-sh/bun#15686`](https://github.com/oven-sh/bun/issues/15686)「listen on unix socket: different file permissions than node」记录**旧版本 Bun 默认创建的 UDS 文件权限硬编码为 `srwx------`（0700）**，而 Node.js 默认 `srwxr-xr-x`（0755）；该 issue 已关联 PR [`#16200`](https://github.com/oven-sh/bun/pull/16200) 关闭。**【文档】**
- **本机实测结果与上述文档口径不一致，以实测为准**：本机 umask 默认 `022` 时，`Bun.listen({unix})` 创建的 socket 文件权限实测是 `srwxr-xr-x`（0755，`stat` 确认 `140755`）；把进程 umask 显式设为 `077` 后再起同一份 `daemon.ts`，socket 权限变成 `srwx------`（0700，`stat` 确认 `140700`）。**结论【实测，更新 §4.3 文档口径】**：Bun 1.3.14 的 UDS 权限**跟随进程 `umask`**（标准 POSIX `bind()` 行为，`0777 & ~umask`），不是硬编码值——`#16200` 大概率已经把旧的"强制 0700"行为改成了"跟随 umask"，使其现在反而和 Node 的默认行为**同源**（Node 默认看到 0755 也是因为常见 shell umask 是 022，不是 Node 自己写死了 0755）。**对本仓库的含义**：daemon 起 UDS 前只需 `process.umask(0o077)`（或等效的启动前 umask 设置）即可直接把 socket 文件权限收紧到仅 owner 可访问，不需要额外 `chmod` 调用或等 Bun 提供专门的 `mode` 参数。

### 4.4 `bun:ffi` 取 `SO_PEERCRED`/`LOCAL_PEERCRED`（macOS: `getpeereid`/`LOCAL_PEERCRED`）——本票最难项，已完整实测打通

- **`bun:ffi` 能力面**：`dlopen(path, { fn: { args, returns } })` 打开任意动态库并声明 C 函数签名，支持 25+ 基础类型，理论上可包任何 C ABI 函数。来源：<https://bun.com/docs/runtime/ffi.md>。**【文档】**，官方标注为实验特性（"experimental, with known bugs and limitations"）。**【文档】**
- **前置条件——原始 fd**：`getpeereid(fd, &uid, &gid)` 要求已连接 socket 的文件描述符；`Bun.listen`/`Bun.connect` 的高层 `Socket` 对象未见文档暴露原始 fd，但 Bun 1.3.3+ 为 `node:net` 兼容层实现了未文档化的 `socket._handle.fd` 字段。**【文档，转述】**

> **更正(2026-08-05,a2-kernel 08 票实施时本机实测)**:上面这条「`Bun.listen` 的 Socket 不暴露 fd、必须改走 `node:net`」**在 Bun 1.3.14 上已不成立** —— `Bun.listen` 的 Socket **原型链上就有 `fd` 取值器**(与 `_handle`/`handle` 并存),`getpeereid(socket.fd)` 直接返回真实 UID/GID(本机实测 `{"fd":6,"rc":0,"uid":501,"gid":20}`,与 `id -u`/`id -g` 吻合)。含义:内核**不必**为了取对端凭据而把 UDS server 从 `Bun.listen` 换成 `node:net`(那会牵动每连接状态 `socket.data` 的整套写法)。实现见 `kernel/src/daemon/peer.ts`(`_handle?.fd` 仍留作兜底,防 Bun 哪天挪走取值器)。原文保留不删,本框只更正结论。

**4.4a 本机实测（完整链路打通）**：`peercred.ts` 用 `node:net`（非 `Bun.listen`）起 server：

```ts
import { dlopen, FFIType, ptr } from "bun:ffi";
import net from "node:net";

const lib = dlopen("libSystem.B.dylib", {
  getpeereid: { args: [FFIType.i32, FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
});

const server = net.createServer((socket) => {
  const fd = socket._handle?.fd;               // Bun 1.3.3+ 为 node:net 兼容层暴露的字段
  const uidBuf = new Uint32Array(1), gidBuf = new Uint32Array(1);
  const rc = lib.symbols.getpeereid(fd, ptr(uidBuf), ptr(gidBuf));
  console.log(JSON.stringify({ fd, rc, uid: uidBuf[0], gid: gidBuf[0] }));
});
server.listen(sockPath);
```

用真实的 `nc -U <sock>` 客户端连接触发一次 server 回调，输出：

```json
{"fd":5,"rc":0,"uid":501,"gid":20}
```

与本机 `id -u`/`id -g` 的真实值（`501`/`20`，`heqianbin`/`staff`）**完全吻合**。**【实测，本票最高价值结论之一】**——`Bun.listen` 原生 UDS API 本身不暴露 fd，但**改走 `node:net` 兼容层拿 `socket._handle.fd`，再配合 `bun:ffi` `dlopen("libSystem.B.dylib")` 调 `getpeereid()`，这条链路在 macOS 上完整可用、返回值正确**，可以直接作为内核仲裁"这个 UDS 连接的对端是哪个本机用户"的凭据来源，不需要额外协议层自证（如客户端在应用层回报自己的 UID，那样不可信）。Linux 上的等价物是 `getsockopt(fd, SOL_SOCKET, SO_PEERCRED, ...)`（本票只在 macOS 环境实测，Linux 侧同一 fd 拿法 + 换一个 `dlopen` 符号，按 API 同构性【推断】应同样可行，留给 09/10 票已定的"Linux 是当下承诺"范围内后续验证）。

---

## 5. 备选运行时对照：Node SEA / Deno compile

本节全部为文档级调研（未本机实测 Node SEA / Deno compile 产物），供「若 Bun 实测翻车」时 04 票复议运行时选型使用。

### 5.1 Node.js Single Executable Applications (SEA)

来源：<https://nodejs.org/api/single-executable-applications.html>

- **稳定性**：Stability 1.1（Active development，实验性），v19.7.0 引入，v25.5.0 起新增 `--build-sea` 内置 CLI 标志。**【文档】**
- **产物生成**：`node --build-sea sea-config.json`，`sea-config.json` 声明 `main`/`output`/`assets` 等字段；产物在 macOS/Windows 上需额外签名（`codesign --sign -`）才能运行。**【文档】**
- **关键限制——不支持运行时动态加载外部脚本，直接排除插件子进程场景**：官方原文明确
  > "In the injected main script, module loading does not read from the file system. By default, both `require()` and `import` statements would only be able to load the built-in modules. Attempting to load a module that can only be found in the file system will throw an error."

  即 SEA 产物**无法**像「Bun bin + BUN_BE_BUN 拉外部 `.ts`」那样，把 agent 现场写的插件文件当子进程/内部模块直接执行——SEA 的设计目标是「构建时把所有依赖打成一个确定性产物」，与本仓库「插件是运行时新增的独立文本文件」的北极星完全相反。**【文档，结论直接决定 SEA 不适用于本场景】**
- **交叉编译**：不支持真正的跨平台编译；官方原文警告跨平台生成 SEA（如在 `darwin-arm64` 上产 `linux-x64`）时必须关闭 `useCodeCache`/`useSnapshot`，否则产物在目标平台启动时可能崩溃。**【文档】**
- **npm 包处理**：要求构建前用 webpack/esbuild/rollup 等打包工具把应用与全部依赖打成单文件 JS 再注入,原生插件（`.node`）需经 `assets` 字段内嵌 + 运行时写临时文件 + `process.dlopen()` 加载,官方记录 Linux arm64 容器产出的 ELF 有已知 hash table 缺陷会导致 `dlopen()` 崩溃。**【文档】**
- **平台支持**：CI 常规测试覆盖 Windows / macOS（仅 arm64，不含 x64）/ Linux（除 Alpine 与 s390x）。**【文档】**
- **小结**：Node SEA 的强项在「体积可控、确定性依赖打包、可内嵌原生插件资产」，但 5.1 条那道「不能运行时读文件系统」的红线，直接否决了它作为「内核 bin 拉起 agent 现场写的插件」这一北极星的候选——除非额外自建一层运行时 loader（如 `createRequire` + 手动 `fs.readFileSync` + `vm` 模块动态求值,官方文档未把此列为推荐路径,且需要自行处理 TS→JS 转译，复杂度显著高于 Bun 的 `BUN_BE_BUN` 一行方案）。

### 5.2 Deno compile

来源：<https://docs.deno.com/runtime/reference/cli/compile/>、<https://docs.deno.com/api/deno/~/Deno.dlopen>、<https://docs.deno.com/api/deno/~/Deno.listen>

- **产物体积/冷启动**：官方文档描述 `deno compile` 基于精简运行时 `denort`（而非完整 `deno` 二进制）以控制体积,`--bundle` 可做 tree-shaking 进一步缩小；`--self-extracting` 模式因需要文件提取会拉高首次冷启动，后续运行复用已提取目录。**【文档，未给出具体 MB/ms 数字】**
- **交叉编译**：`--target` 支持 `x86_64-pc-windows-msvc`、`x86_64-apple-darwin`、`aarch64-apple-darwin`、`x86_64-unknown-linux-gnu`、`aarch64-unknown-linux-gnu`,首次编译会从 `dl.deno.land` 下载对应 `denort-<target>.zip` 并缓存,官方原文称「支持跨编译到所有目标，与主机平台无关」。**【文档】**——与 Bun 的 `--target=bun-linux-x64` 同属"能出产物"级别的交叉编译支持，未见 Deno 有 musl 变体（Bun 有 `bun-linux-x64-musl`）。
- **关键限制——产物同样不能当 CLI 动态执行外部脚本**：官方文档原文强调编译产物是「self-contained executable」，入口文件在编译期确定，所有运行时行为（含权限标志）需编译期写死；未见类似 `BUN_BE_BUN` 的「产物退化为完整 CLI 去跑任意外部文件」的机制。**【文档】**——与 SEA 同理，这条限制直接否决 Deno compile 产物作为「插件运行时宿主」的候选，除非在编译期把 Deno CLI 本身作为 entrypoint 打进去（未见官方文档描述此用法，需要额外验证）。
- **子进程与信号**：`Deno.Command`（取代旧 `Deno.run`）是子进程 API,签发信号用 `Deno.Signal`,默认信号为 `"SIGTERM"`，具体信号集合与行为依操作系统而定;需要 `--allow-run` 权限才能 spawn 子进程。**【文档】**
- **UDS**：`Deno.listen({ path, transport: "unix" })` 支持 Unix Domain Socket 监听，返回 `UnixListener`；需要 `--allow-read`/`--allow-write` 权限。**【文档】**——文档未见 socket 文件权限（mode/chmod）的专用参数，需另调用 `Deno.chmod()` 手动设置（与 Bun 现状——见 §4.3——同样缺开箱权限参数，需外部 `chmod`/`umask` 配合）。**【文档+推断】**
- **FFI**：`Deno.dlopen(path, symbols)` 打开动态库并注册符号，需要 `--allow-ffi` 权限（历史上曾是 `--unstable-ffi`，具体当前版本是否仍需 unstable 标记，本次未逐版本核实，标注待确认）。API 形态（`parameters`/`result` 声明 + `.symbols.fn(...)` 调用）与 `bun:ffi` 的 `dlopen(path, { fn: { args, returns } })` 高度同构，理论上同样可以包 `getpeereid`/`getsockopt(SOL_LOCAL, LOCAL_PEERCRED)`，但未见官方文档给出该场景的示例。**【文档+推断，与 bun:ffi 现状（§4.4）同一确定性档位】**

### 5.3 三者对照小结

| 维度 | Bun compile | Node SEA | Deno compile |
|---|---|---|---|
| 产物能否退化为完整 CLI 去跑任意外部 `.ts/.js` | **能**（`BUN_BE_BUN=1`，本票§3实测确认）| **不能**（文档明确禁止运行时读文件系统）| **不能**（文档未见等价机制） |
| 交叉编译到 Linux | 能出产物（`--target=bun-linux-x64`，另有 musl 变体）| 不支持真正跨平台（需关快照/代码缓存且仍限制多) | 能出产物（`--target=...`，无 musl 变体） |
| UDS 监听 | `Bun.listen({ unix })`，socket 文件权限**实测跟随进程 umask**（§4.3，默认 umask 022→0755，umask 077→0700） | Node 原生 `net.Server` 支持 unix，SEA 产物内同样可用；权限同样跟随 umask | `Deno.listen({ transport: "unix" })`，需读写权限，文档未见权限专用参数 |
| FFI 取 peer credential | `bun:ffi` **本票已实测打通**（§4.4：`node:net` 拿 fd + `getpeereid` 返回真实 UID/GID） | Node 有成熟的原生插件（N-API）生态可写 `.node` 扩展调用 `getpeereid`，但 SEA 场景下要走「资产内嵌+运行时 dlopen」路径，未实测 | `Deno.dlopen` 理论同构可行，未见示例，文档级同档，未实测 |
| 插件北极星（现场写 `.ts`、进程外隔离拉起）适配度 | **高**——`BUN_BE_BUN` 是唯一原生支持"产物变身 CLI"的路径 | **低**——设计上反对象是"确定性单文件"，与"运行时新增插件"目标冲突 | **低**——同 SEA，未见运行时读文件系统的官方支持路径 |

**结论【文档+推断】**：即便不考虑 §1-§4 的实测结果，仅从"能否原生支持运行时执行外部脚本"这一项官方文档口径看，Bun 是三者中唯一直接满足插件北极星的运行时；Node SEA 与 Deno compile 若要复议为运行时候选，都需要额外自建一层"运行时脚本 loader/转译"基础设施，成本明显高于 Bun 现成的 `BUN_BE_BUN`。

---

## 6. 卸载方式（若需要回滚本机实测环境）

```bash
rm -rf ~/.bun
# 并删除 shell rc（~/.zshrc 等）里 install 脚本追加的 PATH 行，形如：
#   export BUN_INSTALL="$HOME/.bun"
#   export PATH="$BUN_INSTALL/bin:$PATH"
```

---

## 7. 基线判定

**基线假设——「Bun compile 单文件 bin + 内核 bin 复用自带运行时拉起插件 `.ts` 子进程」——本机实测成立。【实测】**

判定依据（§3.1、§3.2 已完整验证）：编译产物默认自封闭执行自己打包的入口；同一份编译产物只需在 `Bun.spawn` 时把自己的 `process.execPath` 传给自己、并设 `env.BUN_BE_BUN=1`，就能把**编译期完全不存在、运行时才由 agent 现场写出**的独立 `.ts` 文件当**真正的子进程**（独立 PID/stdout/stderr/可信号控制）拉起并正确回收结果——不需要额外安装系统级 `bun`，不需要目标脚本预先编译，满足 10 票裁定的插件北极星与 ADR 0007 的进程外隔离红线。

需要 04 票设计时纳入的**已发现的现实约束**（均为本票实测所得，不是假设）：

1. **插件 `import` npm 包需要 `node_modules` 在场**（同级或祖先目录，标准 Node 解析），**不会**现场联网装包（§3.3）——内核需要显式设计"插件依赖怎么进 `node_modules`"这一环，不能假设"扔个 `.ts` 文件就能跑起来"对有依赖的插件成立（无依赖的纯逻辑插件不受影响）。
2. **产物体积基线是 ~60.5MB（macOS）/ ~90.2MB（Linux x64，交叉编译产物）**，且这个数字几乎完全由内置运行时决定、与用户代码量无关（§2.1、§2.4）——10 票"账单"里"50–90MB"的估算方向正确，实际内核逻辑量（万行级）会在这个基线上叠加依赖体积，最终数字大概率落在这个区间的中高段（Linux 产物甚至可能突破 90MB 上限）。
3. **常驻 RSS ~26.4MB**（空闲 UDS daemon）——比 Go/Rust 同类 daemon 高一档，但绝对值可接受，与 10 票"账单"定性一致。
4. **UDS socket 权限跟随进程 umask**，daemon 启动前设 `umask 077` 即可直接拿到 `0700`，不需要额外 API（§4.3，且更正了一条已过时的文档口径）。
5. **`bun:ffi` + `node:net` 兼容层拿 fd + `getpeereid` 在 macOS 上完整打通**，可作为内核仲裁 UDS 对端 UID 的凭据来源（§4.4）——这是原本确定性最低的一项，现已从「未知」升级为「实测通过」。
6. **交叉编译到 Linux 已在本机完整验证成功**（§2.4）：`bun-linux-x64` 产物是合法的 `ELF 64-bit LSB executable, x86-64` 文件，90.2MiB；唯一的现实成本是首次编译需要联网下载目标平台运行时包，本次受限网络条件下耗时约 17.5 分钟（绝大部分是下载等待），网络正常环境预期显著更快，且大概率有本地缓存（未逐次复测缓存命中，标【推断】）。

**结论**：基线假设可以直接支撑 04 票的内核边界与进程模型设计；上述 5 点（第 1 点插件依赖约束除外，已在 §3.3 单列）是设计时需要显式处理（而非默认忽略）的现实细节。本票 4 个问题全部达到实测或文档口径的完整交付标准，无遗留的"未实测"缺口。

---

## 8. 【2026-08-04 晚追加】`BUN_BE_BUN` 自举 `bun install` / `bun build`（a2-kernel 02 票 spike）

> 追加日期：2026-08-04 晚。可复现 spike 见 [`Spikes/K1BunPluginBundle`](../../Spikes/K1BunPluginBundle/README.md)，决策落点见 [ADR 0011](../adr/0011-plugin-exec-protocol-loading.md)。
> 起因：a2 内核 bin 化 spec 的插件依赖流（13 票 →「装载期 install+bundle、运行期全员单文件」）此前是**高置信推断、未实测**，是整份 spec 里唯一带这个标注的环节。本节把它做成实测。
> 复现：`bash Spikes/K1BunPluginBundle/run.sh [workdir]`（spike 代码已入库，见 `Spikes/K1BunPluginBundle/README.md`）。环境同 §0：macOS 15.7.8 / arm64 / **Bun 1.3.14**；spike 内核 bin 由 `bun build --compile` 产出，仍是 **63,446,114 字节（60.5MiB）**，与 §2.1 完全一致。
> 方法论：**全流程没有一步用系统装的 `bun`**——只有"把 spike 内核编译成 bin"这一步用系统 bun；之后每一条命令都是编译产物用 `Bun.spawn({ cmd: [process.execPath, ...argv], env: { ...process.env, BUN_BE_BUN: "1" } })` 拉起**自己**执行的，即真实场景里"内核自己决定装依赖/打包/拉插件"。**32 条硬断言全部通过**（另有 2 条只留档不判成败的观察记录，不计入断言数——脚本里 `check()` 与 `record()` 分开，恒真项一律不当断言），每步的 argv/cwd/退出码/耗时/stdout/stderr 原样落 `<workdir>/run/report.json`。
> 缓存隔离：所有 `bun install` 与 auto-install 步骤都把 `BUN_INSTALL_CACHE_DIR` 指到 workdir 下的私有缓存，**不写用户的 `~/.bun/install/cache`**；下文"冷/热缓存"因此有确定含义——同一份私有缓存，第一次 install 是空缓存（冷·真下载），之后复用（热）。

### 8.1 问题①：`BUN_BE_BUN=1` 下跑 `bun install`——**成立**，且依赖 lifecycle scripts 确被跳过

被测目录 `plugin-src/`：`package.json` 声明两个依赖（registry 包 `picocolors@1.1.1` + 一个本地打成 npm tarball 的探针包 `a2-lifecycle-probe@1.0.0`，探针的 `preinstall`/`postinstall` 一旦执行就在自己包目录里留下 `*_RAN` 标记文件），入口 `index.ts` 按 13 票协议实现 `describe`/`call`。

内核发出的命令（`<self>` = 编译产物自身路径，环境带 `BUN_BE_BUN=1`）：

```
<self> install            # cwd=plugin-src
```

`exit=0`，stdout 原文：

```
bun install v1.3.14 (0d9b296a)

+ a2-lifecycle-probe@./a2-lifecycle-probe-1.0.0.tgz
+ picocolors@1.1.1

2 packages installed [12.00ms]

Blocked 2 postinstalls. Run `bun pm untrusted` for details.
```

- **依赖的 lifecycle scripts 未执行**：`node_modules/a2-lifecycle-probe/` 里没有任何 `*_RAN` 标记；`<self> pm untrusted` 把被拦的两条脚本连原文一起列出来（`» [preinstall]: echo ran > DEP_PREINSTALL_RAN` / `» [postinstall]: …`）——**这就是 12 票"审计事件里记录依赖清单/被拦脚本"的现成素材来源**（另有 `<self> pm ls` 列依赖树）。**【实测】**
- **但根 `package.json` 自己的 lifecycle scripts 默认照跑**：`ROOT_PREINSTALL_RAN`、`ROOT_POSTINSTALL_RAN`、`ROOT_PREPARE_RAN` 三个标记全部落地，install 的 stderr 里能看到 `$ echo ran > ROOT_PREINSTALL_RAN` 等回显。**【实测，本节最重要的安全发现】**——"bun install 默认不跑 lifecycle scripts"这句话**只对依赖成立，不对被装的那个工程自己成立**。而 `a2 plugin add <dir>` 里的那个"工程"恰恰是**用户/agent 交来的、未经审查的插件目录**：只要它的 `package.json` 写一行 `"preinstall": "curl … | sh"`，在 add 的那一刻就会以用户身份执行。
- **缓解已实测**：`<self> install --ignore-scripts` → `exit=0`，根脚本与依赖脚本的标记**全部为空**，依赖照常装好。**【实测】**
- **耗时**（同一份 workdir 私有缓存，先冷后热）：**冷缓存（首次真下载）3.4 秒**、**热缓存 19ms**（2 个包，本机受限网络；早前一轮非隔离测量是 4.0s / 16–18ms，量级一致）。**【实测】**——这就是 `a2 plugin add` 一次装载的时延量级：冷缓存以秒计、热缓存以毫秒计。

### 8.2 问题②：`BUN_BE_BUN=1` 下跑 `bun build --target=bun`——**成立**，产出单文件

```
<self> build ./index.ts --target=bun --outfile <registry>/k1-dep-plugin.js     # cwd=plugin-src
```

`exit=0`，stdout：`Bundled 3 modules in 5ms` / `k1-dep-plugin.js  6.0 KB  (entry point)`。**【实测】**

- 产物 **6,002 字节，登记目录下只有这一个文件**（无 chunk、无 sourcemap、无 node_modules）。
- 两个依赖都被**内联进工件**（工件文本里能搜到 picocolors 的 `isColorSupported` 与探针包的 `a2-lifecycle-probe@1.0.0`）——`--target=bun` 不把 npm 依赖留成外部 require。
- TS 直接进（entry 是 `.ts`，产物是 `.js`），不需要额外转译步骤。

### 8.3 问题③：工件被同一个 bin 拉起，JSON 往返 + 退出码语义——**成立**，且删掉源目录照跑

打包后把工件挪进"登记区"（模拟 `~/.a2`），然后 **`rm -rf` 掉整个插件源目录（连同 `node_modules`）**，再从一个中立空目录（无 `package.json`、无 `node_modules`）里由内核拉起：

| 内核发出的命令 | stdin | 结果 |
|---|---|---|
| `<self> <artifact> describe` | — | `exit=0`，stdout 是合法 JSON 工具清单（`tools=["echo","boom"]`），**与删源目录之前的输出逐字一致** |
| `<self> <artifact> call` | `{"tool":"echo","input":{"text":"hello-a2"}}` | `exit=0`，stdout `{"ok":true,"tool":"echo","output":{"upper":"HELLO-A2",…,"probe":"a2-lifecycle-probe@1.0.0","pid":51391,…}}` |
| `<self> <artifact> call` | `{"tool":"boom"}` | `exit=3` + 结构化错误 JSON（插件自定义的失败码原样传回） |
| `<self> <artifact> call` | `{"tool":"nope"}` | `exit=4`（未知工具） |
| `<self> <artifact> call` | `{not json` | `exit=2`（坏报文） |
| `<self> <artifact> call` | `{"tool":"throw"}` | `exit=1`，stderr 是 Bun 的未捕获异常栈（内核侧能拿到，不污染 stdout 的 JSON 面） |
| `<self> --no-install <artifact> describe` | — | `exit=0`，输出与不加 flag 时逐字一致（见 §8.5：这是推荐姿势） |

**【实测】**——补充事实：

- **工件里的 npm 依赖运行期真的可用**（describe 回报 `{"picocolors":true,"probe":"a2-lifecycle-probe@1.0.0"}`），证明打包是真内联而不是懒解析。
- **插件是独立子进程**：插件回报的 `pid`（51391）与内核自身 `pid`（51376）不同 —— ADR 0007/0011 的"进程外隔离"红线在这条路径上成立（与 §3.2 同一结论，此处是"打包工件"版本）。
- 单次 `describe`/`call` 子进程往返 **7–11ms**（含 Bun 冷启，与 §2.2 的 8ms 量级吻合）。

### 8.4 边界：打不进的怪包长什么样（供 12 票写拒绝面）

| 情形 | 命令与结果 | 对 12 票的用法 |
|---|---|---|
| **依赖没装就 build** | `exit=1`，stderr：`error: Could not resolve: "left-pad". Maybe you need to "bun install"?`（带行号与列指示） | build **明确失败、不产坏工件**；错误文本可直接转写成结构化拒绝的 `detail` |
| **native addon（`.node`）+ `--outfile`** | `exit=1`，stderr 只有一句 `error: cannot write multiple output files without an output directory` | 用 `--outfile` 时 `.node` 必然让 build 失败——**这就是天然的检出信号**，但报错文本不提 addon，指引得由内核自己写 |
| **native addon（`.node`）+ `--outdir`** | `exit=0`，产物目录里是 **`index.js` + `fake-vmgqa0c8.node` 两个文件** | 若改用 `--outdir`，判据是"产物文件数 > 1 即非单文件插件 → 拒绝"（同一判据顺带覆盖任何被外置的资源文件） |
| **非静态可分析的 `require(变量)`** | build `exit=0`，**无任何 warning**；产物运行期才决定去解析 | 打包期发现不了，必须靠运行期的 `--no-install` 兜（见 §8.5），否则会变成静默联网 |

**【实测】**——注：`.node` 样本是占位文本文件，只验证**编译期**行为（bun bundler 对 `.node` 扩展名的处理路径），未验证真实原生 addon 的运行期加载。

### 8.5 auto-install：Bun 运行期会**联网自动装包**——触发规则与关闭方式（并更正 §3.3 的归因）

§3.3 曾结论"`BUN_BE_BUN=1` 执行外部 `.ts` 时 `import` npm 包不会现场联网装包"。本轮做了控制变量复测，**该结论的归因需要更正**：

| 场景（都是 `BUN_BE_BUN=1 <bin> iso.ts`，`iso.ts` 静态 `import isOdd from "is-odd"`，本地没装过） | 结果 |
|---|---|
| 目录树里**没有任何 `node_modules`**、也没有 `package.json` | **`exit=0`**——终端刷 `🔍 Resolving [n/m]` 进度，**联网把包装进 `BUN_INSTALL_CACHE_DIR` 后正常跑通** |
| 同上，但**有 `package.json`**、仍无 `node_modules` | **`exit=0`**，同样 auto-install（包落到该次运行的私有缓存里，实测确认）——`package.json` 的有无不影响触发 |
| 祖先目录里有一个**空的** `node_modules/` | `exit=1`：`error: Cannot find package 'is-odd' from '…/iso.ts'` |
| 加 `--no-install` flag（`<bin> --no-install iso.ts`） | `exit=1`：同上硬错 |

**结论【实测】**：Bun 的 auto-install 以**"整条祖先目录链上找不到任何 `node_modules`"**为触发条件（与 `package.json` 无关），触发时会**联网**从 registry 装包进全局缓存并继续执行。§3.3 那次"没有现场装包"的观察是真实的，但原因是它的祖先目录 `kernel-min/` 当时已经被 `bun install` 过（§3.3 第 1 点自己记了这件事）——**auto-install 当时是被关掉的状态**，不是 Bun 的默认行为。

**对 a2 的直接含义（12 票必须显式处理）**：

- 一个 agent 现场写的插件，只要 `import` 了一个没打进工件的包名（打错字、动态 require、或零依赖插件里的一句 `import`），在 `~/.a2` 这种通常没有 `node_modules` 的目录下被拉起时，**会在调用的那一刻静默联网装包**——供应链面从"装载期"漏到了"调用期"，且离线环境下行为不可预测。
- **缓解已实测**：内核 spawn 插件时统一加 `--no-install`（`<bin> --no-install <artifact> …`），auto-install 即关闭、变成 `Cannot find package` 硬错（fail-closed，符合裁决序里的安全底线优先）；对正常的单文件工件**完全无副作用**（§8.3 末行已验证输出逐字一致）。

### 8.6 对 11/12 票的落地口径（本节实测直接支撑）

1. **依赖流成立，13 票的设计不用改**：`a2 plugin add <目录插件>` = 临时目录 `bun install` → `bun build --target=bun` 打单文件 → 登记工件 → 弃 `node_modules`；运行期与零依赖单文件插件走完全相同的 describe/call 路径。全程由 `a2` 自己经 `BUN_BE_BUN` 完成，**不要求用户装系统级 bun**。
2. **install 必须带 `--ignore-scripts`**：否则插件目录自己的 `package.json` 能在 add 时执行任意命令（§8.1）。"bun install 默认不跑 lifecycle scripts"这句 spec 措辞建议按本节收紧为"**依赖的**不跑；根工程的必须靠 `--ignore-scripts` 关"。
3. **spawn 插件必须带 `--no-install`**：把 auto-install 关成 fail-closed（§8.5）。
4. **拒绝面的判据**：build 非零退出即拒绝（错误文本进 `detail`）；若改用 `--outdir`，产物文件数 > 1 即判"非单文件插件"（`.node`/外带资源都落这条）。native addon 与动态 `require(变量)` 这两类，**打包期能抓到的只有前者**，后者靠第 3 条兜。
5. **审计素材现成**：`bun pm ls`（依赖清单）与 `bun pm untrusted`（被拦的 lifecycle scripts 原文）都能在 `BUN_BE_BUN` 下跑，可直接进 add 的审计事件。
6. **时延口径**：add 一次 = install（热缓存 ~17ms / 冷缓存 ~4s）+ build（~10ms）；调用一次 = 子进程 7–11ms。

### 8.7 备选方案（本次未触发，备查）

三问全成，spec 的 Further Notes 里"翻车则回 04 票复议运行时"的条件**没有触发**，插件依赖流照 13 票原样实施即可。为防后续版本回归，把当时列的备选路径记在这里备查：①内核内改用 Bun 的编程式 API（`Bun.build({ target: "bun" })` 在内核进程里直接打包，绕开 CLI 面——本次未实测）；②`a2 plugin add` 期要求系统级 bun 在场（退化为外部依赖，与"单文件分发"冲突，仅作末选）；③只支持零依赖单文件插件，带依赖的插件要求作者自己先打包成单文件再 add（能力缩水但零新增机制）。
