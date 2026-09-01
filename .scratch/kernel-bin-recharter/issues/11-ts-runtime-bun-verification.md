# 11 — 调研:TS 内核运行时与单 bin 分发实测(Bun 基线)

Type: research
Status: resolved

## Question

[10 票](10-kernel-language-decision.md)已裁内核换 TS 重写,基线假设为 **Bun compile 单文件 bin,且内核 bin 可复用自带运行时把插件 `.ts` 文件作子进程拉起**(插件北极星=「agent 现场写插件」)。本票为 [04 票](04-kernel-boundary-process-model.md)(内核边界与进程模型)提供实测背书:

1. **Bun compile 实测**:本机(macOS)`bun build --compile` 产单文件可执行——真实体积、冷启动耗时、常驻 RSS 基线;`--target` 交叉编译 Linux 产物是否可出(能出即可,不必跑)。bun 未装则先装到用户目录(官方脚本,记录卸载方式);装不上则此项转文档口径并显著标注「未实测」。
2. **内核 bin 作插件运行时**:编译产物能否经 `BUN_BE_BUN=1`(或其他机制)执行外部 `.ts` 文件为子进程;外部脚本 `import` npm 依赖时的行为(是否要求 node_modules 在场)。这是插件北极星的成立条件,重点实测。
3. **daemon 工况 API 面**:Bun 的 UDS server(`Bun.listen({ unix })`)与 client;子进程管理与信号(`Bun.spawn`/`process.kill`/信号处理);socket 文件权限控制;`SO_PEERCRED`/`LOCAL_PEERCRED` 经 `bun:ffi` 取对端凭据的可行性(文档+最小实测)。
4. **备选运行时对照**(文档级即可):Node SEA 与 Deno compile 在上述 1/2/3 项的口径,供 Bun 翻车时 04 票复议运行时选型。

结论落 `docs/research/ts-kernel-runtime-bun.md`(中文,来源带 URL,区分【实测】/【文档】/【推断】;本机可实测项直接实测)。

## Answer

2026-08-04 本机完整实测（详见 [`docs/research/ts-kernel-runtime-bun.md`](../../../docs/research/ts-kernel-runtime-bun.md)），四问逐一作答：

1. **Bun compile 实测**：本机原未装 bun,官方一键脚本首次因 HTTP/2 传输中断失败(非权限问题),改用同一官方 Release 资产 + `curl --http1.1 --retry` 重试装成(Bun 1.3.14, darwin-aarch64,只写 `~/.bun` 与 `~/.zshrc`)。最小程序 `--compile` 产物 **60.5MiB**(体积几乎完全由内置运行时决定,与用户代码量无关),冷启动 **7.7–13ms**(20 次采样),空闲常驻 daemon RSS **26.4MiB**。`--target=bun-linux-x64` 交叉编译**最终成功产出合法 ELF 产物**(90.2MiB,`file` 确认为真正的 Linux x86-64 可执行文件),唯一代价是首次编译需联网下载目标运行时,受本机网络所限耗时约 17.5 分钟(绝大部分是下载等待)。**【实测】**
2. **内核 bin 作插件运行时(插件北极星成立条件)**:**编译产物内部对自己 `Bun.spawn(process.execPath, ..., env:{BUN_BE_BUN:"1"})`,可以把编译期不存在、agent 现场写的外部 `.ts` 文件当独立子进程拉起并正确回收 stdout/退出码,不需要额外装系统级 bun**——本机完整验证成立,同时满足 ADR 0007 进程外隔离红线。**但外部插件脚本 `import` npm 包时严格要求 `node_modules` 在场**(同级或祖先目录,标准 Node 解析算法),**不会**现场联网装包(初测因与并发 `bun install` 撞车产生过一次误判,已用隔离环境纠正确认)——04 票设计插件系统时需显式处理"插件依赖怎么进 node_modules"这一环。**【实测,本票最关键结论】**
3. **daemon 工况 API 面**:`Bun.listen/connect({unix})` 收发正常;`Bun.spawn` 信号(`kill("SIGTERM")` → `signalCode`/`exitCode`/`resourceUsage()`)行为符合文档;UDS socket 权限**实测跟随进程 umask**(更正了一条描述"Bun 默认强制 0700"的过时 GitHub issue 口径,umask 022→0755、umask 077→0700);**`bun:ffi` dlopen `libSystem` + `node:net` 兼容层的 `socket._handle.fd` 调 `getpeereid()` 在 macOS 上完整打通,返回值(uid=501/gid=20)与真实用户凭据完全吻合**——本票原本确定性最低的一项已升级为实测通过。**【实测】**
4. **备选运行时对照**:Node SEA 与 Deno compile 的编译产物均**不支持运行时动态执行外部脚本**(SEA 官方文档明确"module loading does not read from the file system";Deno compile 产物同样是"self-contained"),这条限制直接否决二者作为插件运行时候选——Bun 的 `BUN_BE_BUN` 是三者中唯一原生满足插件北极星的机制。**【文档】**

**基线判定**:「Bun compile 单文件 bin + 内核 bin 复用自带运行时拉插件」本机实测成立,可直接支撑 04 票的内核边界与进程模型设计;需要显式处理的现实约束(插件依赖 node_modules、体积/RSS 基线、umask 权限模型、peer credential 取法)见调研文档 §7。
