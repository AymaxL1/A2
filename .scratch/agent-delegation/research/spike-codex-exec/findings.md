# Spike 实测报告：`codex exec --json` 无头驱动行为

> 对应票据：`.scratch/agent-delegation/issues/02-spike-codex-exec.md`
> 实测对象：`/Users/heqianbin/.codex/plugins/.plugin-appserver/codex`，`codex-cli 0.146.0-alpha.3.1`（arm64 Mach-O，不在 PATH，全路径调用）
> 方法：Python 驱动脚本 `driver.py`（同目录）以 `start_new_session=True` 拉起 codex 子进程（自成进程组），流式落盘 stdout/stderr，支持定时发信号 + 硬超时兜底；隔离 `CODEX_HOME` 指向 sandbox 内独立目录，仅复制 `auth.json`。
> 调用预算：**8 次 `codex exec`**（quota 消耗类）+ 5 次 `--help`/`--version`（免费，不占预算）。逐条证据见 `samples/`。

---

## 0. 隔离方案与护栏合规证明

- **CODEX_HOME 隔离可行，且是唯一被验证过的安全路径**：把 `CODEX_HOME` 指向 `sandbox/../codex_home`（空目录，仅放一份复制来的 `auth.json`，**不**复制 `config.toml`），8 次调用全部成功鉴权、正常产出，证明鉴权只认 `$CODEX_HOME/auth.json`，不依赖 `~/.codex` 下其它文件。未测试 `-c` 行内覆盖路径单独跑通（见下方 2 节说明：本次是靠"不复制 config.toml + 显式传 `-s`/`-c sandbox_mode=`"这个更干净的组合验证的，等价于 multica 的每任务 `$CODEX_HOME` 隔离思路，在 exec 模式下同样可行）。
- **反向验证隔离不会"泄漏"到真实身份**（`samples/exec7-no-auth-isolation-check.*`）：把 `CODEX_HOME` 指到一个完全空目录（无 `auth.json`）后跑 `exec`，请求带不上 bearer token，服务端返回 `401 Unauthorized: Missing bearer or basic authentication in header`，**没有**观察到静默回退到真实 `~/.codex/auth.json` 或任何环境凭据。即"隔离失败"这一档是 fail-closed（直接 401 失败），不会误用真实用户身份。
- **护栏执行证明**：
  - 全程未写入 `~/.codex` 下任何文件——`stat` 对比 `config.toml`（`2026-07-28 03:43`）、`auth.json`（`2026-07-23 21:26`）mtime 与任务开始前的 `ls -la` 快照完全一致（未变化）。
  - `auth.json` 副本已删除：`rm -fv codex_home/auth.json` 执行且 `find spike-codex-exec -iname auth.json` 为空，另外整个 `codex_home/`、`codex_home_noauth/`（exec 运行时自动写入的 sqlite/cache/session 等状态目录）已一并 `rm -rf`，不保留任何鉴权相关残留。
  - `sandbox/` 已清空（`inside-write-test.txt` 等测试产物已删除，现状为空目录）。
  - 全部 grep 校验：`auth.json` 里 4 个长度 >20 的密钥字符串（`id_token`/`access_token`/`refresh_token`/`account_id`）未出现在任何 `samples/*` 文件中。
  - sandbox_mode 实验只用了 `read-only`/`workspace-write`，未使用 `danger-full-access` 跑任务。
  - 中断信号只发给自己拉起的进程组（`os.killpg(pgid, ...)`，`pgid` 来自 `start_new_session=True` 的子进程自身 pid）。
- **调用清单**（全部 8 次实消耗调用，命令与结果见对应 `samples/<scenario>.meta.json`）：

  | # | scenario | 目的 | 退出码 |
  |---|---|---|---|
  | 1 | `exec1-baseline-readonly-default` | 无 sandbox flag 的默认行为 + 事件 schema 基线 | 0 |
  | 2 | `exec2-default-write-attempt` | 默认配置下尝试写文件 | 0（但写被拦，见下） |
  | 3 | `exec3-readonly-explicit-write` | 显式 read-only 下强制写 | 被本机 90s 硬超时兜底 SIGTERM（网络重连耗尽时间，非卡死等审批，见 5 节） |
  | 3b | `exec3b-readonly-explicit-write-retry` | 同上重跑一次 | 0（写被拦，定论样本） |
  | 4 | `exec4-workspace-write-cfg-boundary-nopath` | `-c sandbox_mode=workspace-write` + PATH 清空 + cwd 内/外写边界 | 0 |
  | 5 | `exec5-interrupt-sigterm-midrun` | 进程组 SIGTERM 中断实测 | -15（被信号杀死） |
  | 6 | `exec6-failure-invalid-model` | 故意传非法 model 名触发失败终态 | 1 |
  | 7 | `exec7-no-auth-isolation-check` | 空 CODEX_HOME（无 auth）验证不回退真实身份 | 1 |

---

## 逐项回答（对应票上 7 问）

### 1. 事件流 schema：类型、字段形状、session/thread id 获取方式

样本：`samples/exec1-baseline-readonly-default.stdout.jsonl`（最干净的基线样本，6 行）。

观测到的事件类型全集（跨全部 8 次调用汇总）：

| `type` | 出现层级 | 关键字段 | 样本出处 |
|---|---|---|---|
| `thread.started` | 流级，**永远是第一行** | `thread_id`（UUID，形如 `019faa09-dcf2-75d2-b83c-28e95e20e800`） | 全部 8 个样本首行 |
| `turn.started` | 流级 | 无附加字段 | 全部样本 |
| `item.started` | 流级 | `item:{id,type,command,aggregated_output,exit_code:null,status:"in_progress"}` | exec1/exec4 |
| `item.completed` | 流级 | `item:{...}`，`type` 见到过 `command_execution`（含 `exit_code`/`status:"completed"\|"failed"`/`aggregated_output`）、`agent_message`（`text`）、`error`（item 级警告，如 model 元数据缺失） | exec1/exec2/exec3b/exec4/exec6 |
| `error` | 流级，非终态 | `message`（人类可读字符串，可能内嵌一段原始 API 错误 JSON） | exec3/exec6/exec7（重连提示、最终错误） |
| `turn.completed` | 流级，终态 | `usage:{input_tokens,cached_input_tokens,cache_write_input_tokens,output_tokens,reasoning_output_tokens}` | exec1/exec2/exec3b/exec4 |
| `turn.failed` | 流级，终态 | `error:{message}` | exec6/exec7 |

**session/thread id 获取方式：直接从 stdout 第一行拿，不需要等任何文件落盘。** 这是与 multica 最直接的差异（见下节）——`--json` 流的第一条事件就是 `{"type":"thread.started","thread_id":"<uuid>"}`，无需像 multica 对 app-server 协议那样等 rollout 文件写入磁盘后再读文件名解析 id。

**未覆盖**：本次任务只是简单只读列目录/写文件，没有出现 `reasoning`（8 次调用 `reasoning_output_tokens` 均为 0）、`apply_patch`/`file_change` 类型的 item——multica 分析里提到的 `item/fileChange/requestApproval` 对应的"文件补丁"专属 item 类型未被触发，因为我们全程用 shell 重定向写文件而非 apply_patch 工具；这部分 schema 留白，不构成本次结论的一部分。

### 2. sandbox 与审批：sandbox_mode 怎么传 + 隔离是否可行

样本：`exec3b-readonly-explicit-write-retry`（`-s read-only`）、`exec4-workspace-write-cfg-boundary-nopath`（`-c sandbox_mode=workspace-write`）。

- **两种传递方式都实测生效**：
  - CLI flag：`-s/--sandbox <read-only|workspace-write|danger-full-access>`（`exec3b` 用此形式，写被拦截，行为符合 read-only 语义）。
  - `-c` 行内覆盖：`-c sandbox_mode=workspace-write`（`exec4` 用此形式，cwd 内写成功），`-c` 的 key 就是 `config.toml` 里同名字段（已读取用户真实 `config.toml` 第 3 行确认字段名为 `sandbox_mode`，`-c` 走的是同一份配置 schema）。
  - **env 变量：`codex exec --help`/`codex --help` 都没有列出任何用于*设置* sandbox_mode 的环境变量**（`CODEX_HOME` 只影响去哪读配置/鉴权，不是 sandbox 开关本身）。本次未发现、也未测试任何"用环境变量直接指定 sandbox_mode"的机制，结论是：**该版本只支持 flag 和 `-c`/config.toml 两条路，没有 env 路**（基于 `--help` 文档面 + 全部样本行为交叉验证，未做穷举式反证）。
  - **不覆盖时的默认值**：`exec1`/`exec2` 都没传任何 sandbox 相关 flag，且隔离用的 `CODEX_HOME` 里根本没有 `config.toml`。`exec2` 里模型被要求写文件，结果与显式 `read-only`（`exec3b`）表现一致（写被拦、文件未落盘）——即**裸 CODEX_HOME + 不传任何 sandbox flag 时，等效于 read-only**（不是 danger-full-access，也不是 workspace-write）。
- **CODEX_HOME 逐任务隔离可行**：见 0 节，8/8 调用鉴权成功，真实 `~/.codex` 全程零改动，且证明了"隔离失效时 fail-closed（401）而非误用真实身份"。另外 `--help` 里还看到一个更强的防御性 flag：**`--ignore-user-config`**（"Do not load `$CODEX_HOME/config.toml`; auth still uses `CODEX_HOME`"）——本次因为压根没往隔离 CODEX_HOME 里放 `config.toml`，没必要用它，但如果适配层未来的隔离目录有被污染风险（比如复用旧目录），这个 flag 是文档化的第二道保险，值得记录但本次未做专门样本验证。
- **旁证**：exec 运行时会把"学到的"状态（项目信任级别、models_cache、sqlite 状态库等）写回它所用的 `$CODEX_HOME`（本次隔离目录运行后自动长出了 `config.toml`（仅一条自动写入的 `[projects."/Users/Shared/Workspaces/PROJECT_AA"] trust_level="trusted"`）、`cache/`、`sessions/`、多个 sqlite 文件），说明 `$CODEX_HOME` 不是纯只读输入，是"用后即脏"的运行时状态盘——如果适配层要保证每任务纯净，必须每任务重建/清空 CODEX_HOME（这一点已在清理阶段验证：删除即可，无残留跨任务污染真实配置的路径）。

### 3. 审批请求：exec 模式下还发不发？默认怎么处理？

样本：`exec2-default-write-attempt`、`exec3b-readonly-explicit-write-retry`、`exec4-workspace-write-cfg-boundary-nopath`（第二条越界写）。

**结论：在 `--json` 流里，三次"应当被拒绝的写"实验里，一次都没有看到任何审批类事件（不管是 RPC 请求、还是"决定"事件）。`codex exec --help` 本身也印证了这点——顶层 `codex --help` 有 `-a/--ask-for-approval` flag，但 `codex exec --help` 完全没有这个 flag，说明 exec 子命令没有暴露"审批策略"这个概念给调用方配置。**

更值得注意的细节（三次实验一致）：**被拒绝的写连 `item.started`/`item.completed` 都不会出现**——不是"item 出现但标记 denied/failed"，而是这个 item 在流里完全不存在。例如 `exec3b` 里模型被强制要求"第一个且唯一一个 tool call 必须是 `echo hello > exec3-write-test.txt`"，实际流里只有两条 `agent_message`（"我会执行"→"Exit code: 1"），中间没有任何 `command_execution` item。`exec4` 的第二条命令（越界写 `../OUTSIDE_WRITE_TEST.txt`）同样：只有第一条 in-cwd 写留下了完整 `item.started`/`item.completed` 对，第二条越界写在流里完全消失，只有模型自己最后文本里声称的 `call2 exit=1`。

这带来一个重要的**不确定性需要如实标注**：我们无法从外部 100%区分"harness 在 item 级别之下就静默拦截了（模型的 tool call 请求从未变成一个可见 item）"和"模型自己判断会失败、选择不真的调用工具、编了个数字应付指令"这两种可能——两次样本里模型的最终文本（"Exit code: 1"、"call2 exit=1"）都只是文本，不是来自任何结构化字段。**但无论哪种机制，对外可观测的行为是确定的且一致（3/3）：拒绝对写操作不产生结构化的、可编程识别的"审批/拒绝"事件，只能通过磁盘状态兜底验证（见第 6 项）。**

默认行为总结：**没有"挂起等答复"这一档**（不会卡住等一个不存在的人类）；效果上等价于"自动拒绝"，但不是通过一条可识别的"拒绝"事件表达的，而是"这次工具调用连痕迹都没留下"。这与 multica 在 app-server 协议上收到的显式 `execCommandApproval`/`item/fileChange/requestApproval` RPC 完全不是一回事（详见"关键差异"节）。

### 4. 中断：进程组 SIGTERM/SIGKILL，退出码与残留进程

样本：`exec5-interrupt-sigterm-midrun.*`。

- 任务：`sleep 60 ; echo done`（`-s read-only`），驱动脚本在 8.3s 时对**进程组**（`os.killpg`，非单进程）发 `SIGTERM`。
- 结果：进程在信号发出后几乎立即死亡（总运行 8.515s），`returncode=-15`（**被信号 15 直接杀死，不是捕获信号后自行退出某个码**——即 codex 没有为 SIGTERM 注册优雅关闭的信号处理器）。
- **残留进程检查双重确认为零**：驱动脚本内部 `ps -o pid,pgid,command -g <pgid>` 查询该进程组为空；额外用 `ps aux | grep "sleep 60"` 做系统级独立复查同样为空。说明 codex 派生的 `/bin/zsh -lc 'sleep 60...'` 及其子进程 `sleep` 都和 codex 本体在**同一个进程组**里，进程组级 SIGTERM 可以一次性带走整棵进程树，没有"逃逸"到新进程组的子进程。
- 中断发生前流里只落盘了 `thread.started` + `turn.started` 两行（`item.started` 都没来得及出现/落盘），中断没有产生任何"任务被取消"的终态事件（`turn.failed`/`turn.aborted` 均未出现）——**从流本身看不出"是我杀的还是它自己崩了"，区分中断 vs 崩溃只能靠退出码是否为负（被信号杀）**。
- 因为 SIGTERM 已经足够快、足够干净地杀死整棵树，驱动脚本里预置的"SIGTERM 无效则升级 SIGKILL"的兜底路径**全程未被触发**（`escalated_to_sigkill: false`）——本次没有构造出"需要 SIGKILL 兜底"的场景（codex 没有 SIGTERM 处理器，理论上也没有能拖住退出的理由）。

### 5. 终态与退出码

三种终态，样本互相印证：

| 终态 | 退出码 | 终态事件 | 样本 | stderr 特征 |
|---|---|---|---|---|
| 成功 | `0` | `turn.completed` + `usage` token 统计 | exec1/exec2/exec3b/exec4 | 见下方"意外发现"，与成败无关的噪音 ERROR 日志 |
| 失败（API 层错误，无论 400 非法 model 还是 401 鉴权缺失） | `1` | `turn.failed`，`error.message` 带原始错误串（`exec6` 是 `400 invalid_request_error`，`exec7` 是 `401 Unauthorized`） | exec6/exec7 | 同上噪音 + 该次失败对应的 `ERROR codex_api::endpoint::responses_websocket` 行 |
| 外部信号中断 | `-15`（即被 `SIGTERM` 杀死，Python `subprocess.returncode` 的负数惯例） | 无——流原样截断，不会补一条终态事件 | exec5 | 无额外内容（进程来不及打印） |

**退出码语义是"二元+信号"，不区分失败原因**：400（模型名非法）和 401（鉴权缺失）两种完全不同的错误都统一落到退出码 `1`，要区分具体错因只能解析 `turn.failed.error.message` 里的原始字符串（这段字符串本身还是**再序列化了一层的 JSON 字符串**，例如 `exec6` 里 `error.message` 的值是 `"{\"type\":\"error\",\"status\":400,...}"`——是双重编码，适配层要 parse 两次）。

stderr 上的内容不是终态判定的可靠依据：即使是**成功**的调用，stderr 也会有若干条 `ERROR` 级别日志（见 7 节），必须以退出码 + `turn.completed`/`turn.failed` 事件为准，不能用"stderr 非空"或"stderr 里有 ERROR 字样"来判定任务失败。

### 6. 工作目录：cwd 隔离与越界写实测

样本：`exec4-workspace-write-cfg-boundary-nopath.*`。

- `-c sandbox_mode=workspace-write`，cwd 固定为 `sandbox/`。两条强制的 shell 调用：
  1. `echo inside-ok > inside-write-test.txt`（cwd 内）→ **成功**，完整 `item.started`(`status:"in_progress"`) → `item.completed`(`exit_code:0,status:"completed"`) 事件对，磁盘上确认文件真实落地（10 字节，内容 `inside-ok\n`）。
  2. `echo escaped > ../OUTSIDE_WRITE_TEST.txt`（cwd 上一级，越界）→ **无对应 item**（同第 3 项的"拒绝即消失"现象），磁盘复查确认父目录下确实**没有**生成该文件——即便看不到结构化拒绝事件，OS/沙箱层面的边界确实是硬性生效的。
- 结论：`workspace-write` 的可写边界严格锁定在传入的 cwd（本次用 `-C`/进程自身 cwd，未显式测 `--add-dir` 追加白名单目录），跨到父目录一级就被拦，且拦截方式与"审批"一节一样是静默的，无法从流里直接看到"越界"这个判定过程，只能通过任务完成后 diff 文件系统来确认。
- **未覆盖**：没有测试 `--add-dir` 追加可写目录、也没有测试系统临时目录（`$TMPDIR`/`/tmp`）是否在默认可写白名单内——如果适配层需要"额外挂载一个可写目录"的能力，`--add-dir` 是候选项，但本次未验证其实际生效方式。

### 7. PATH 姿态：全路径调用有没有额外坑

- **基本调用不受 PATH 影响**：`--version`/`--help`/`exec --help` 等纯本地操作不需要 PATH（Mach-O 可执行文件直接跑）。
- **PATH 清空后 shell 工具仍可用**（`exec4` 用 `--strip-path` 把 `PATH` 设为空字符串，两条 shell 调用里第一条依然成功执行）：证据是 `item.completed` 里 `command` 字段显示实际执行的是 `/bin/zsh -lc 'echo inside-ok > inside-write-test.txt'`——**codex 用绝对路径 `/bin/zsh` 拉起 shell，不经过 PATH 查找**；`-l`（login shell）参数还会让 zsh 自己重新走一遍登录环境初始化，进一步稀释了"父进程 PATH 是否为空"这件事的影响。本次没有发现因为二进制不在 PATH、或运行环境 PATH 被清空而导致的"资源查不到"类故障。
- **自更新行为：未观测到 exec 路径下有自动更新**。`codex --help` 把 `update` 列成一个独立子命令（"Update Codex to the latest version"），8 次 `exec` 调用里没有任何一次的 stdout/stderr 出现更新检查/下载相关的字符串。这是"未观测到"而非"证明不存在"（只跑了 8 次、只用了 `exec` 一个子命令面）。
- **但发现了一个和 PATH 无关、和"全路径/非标准二进制"更相关的真实坑**：这个具体二进制（ChatGPT 桌面 App 内置的 alpha 插件版，`~/.codex` 目录本身也带有 `pets/`、`goals_1.sqlite`、`computer-use/` 等明显是 ChatGPT App 专属的状态，不是纯净的开源 `codex` CLI）在**每一次** `exec` 调用里，不管任务内容是什么、也不管任务最终成不成功，stderr 都会稳定出现这几类 `ERROR` 日志：
  - `codex_models_manager::manager: failed to refresh available models: timeout waiting for child process to exit`（8/8 次全部出现）
  - `rmcp::transport::worker: worker quit with fatal: ... url (https://chatgpt.com/backend-api/ps/mcp)`（多次出现，某个内置 MCP 服务器连不上 ChatGPT 后端）
  - `codex_api::endpoint::responses_websocket: failed to connect to websocket: ... url: wss://.../responses`（WebSocket 传输偶发失败，但会自动回退到 HTTPS 传输后继续，不影响任务成败——`exec2`/`exec7` 的 stderr 都能看到这类行，其中至少一次任务仍以 `0` 退出）
  这些是**这个特定构建自带的、连到 ChatGPT 私有后端的旁路依赖**，会产生大量噪音但不致命；换成纯净的开源 `codex` 二进制大概率不会有这几条（没有验证条件确认，仅基于目录结构和错误信息里的 `chatgpt.com`/`pets`/`computer-use` 强烈暗示这是定制构建的专属行为，不代表上游 `codex exec` 的通用特征）。适配层如果要拿"stderr 是否有 ERROR"做健康检查，这个构建会直接产生大量误报。

---

## 与 multica（app-server 协议面）的关键差异

multica 驱动的是 `codex app-server --listen stdio://` 的 **JSON-RPC 2.0 双向协议**（`thread/start`、`turn/start` 请求 + `codex/event`/`item/*` 通知，详见 `multica-adapter-analysis.md` 第 2/5 节），本次实测的是 `codex exec --json`——**结构性差异比预想的更大**：

1. **单向 vs 双向**：`exec --json` 是纯单向事件流（codex → 调用方），没有 JSON-RPC 的 `id`/请求-响应信封，调用方**无法**往里发消息（无法追加指令、无法应答审批、无法 `session/cancel`）。app-server 模式下 multica 的 `codexClient` 能收到 `execCommandApproval`/`item/fileChange/requestApproval`/`item/permissions/requestApproval` 这些明确的"请求"并**主动回一条 accept**；exec 模式下**没有等价的可回复请求**——多次测试均确认，被拒绝的操作对外根本不出现在流里（见第 3/6 项），适配层无事可"回复"，因为压根没有请求发过来。这意味着如果适配层想复刻 multica 那种"自动应答但至少留痕"的行为，在 exec 模式下做不到——没有痕迹可留，只能靠事后 diff 文件系统/工具输出反推。
2. **session/thread id 获取方式完全不同**：multica 分析报告明确写"靠等 rollout 文件落盘"；exec 模式下 id 是流的**第一行**直接给出（`thread.started.thread_id`），不需要碰文件系统。这对适配层是好消息——早绑定 session 指针（multica MUL-5305 那套"崩溃不丢续接指针"的设计）在 exec 模式下更容易做，甚至不需要 multica 那样专门等 Codex 的 rollout 文件真落盘。
3. **中断机制殊途同归**：multica 对 17 个 backend（包括 app-server 模式的 Codex）统一用"进程组信号"而非协议层取消（"代码里搜不到任何 `session/cancel` 调用"）。本次 exec 模式的实测（第 4 项）证实同一套进程组 SIGTERM 策略在 exec 模式下一样有效、一样干净（无残留），**这条经验可以直接复用，不需要为 exec 模式单独设计中断机制**。
4. **协议词汇表面相似，但形态不同**：multica 报告提到 app-server 新版走 `turn/started`/`item/*` 等"raw v2 通知"；exec `--json` 的事件名（`thread.started`/`turn.started`/`item.started`/`item.completed`/`turn.completed`/`turn.failed`）用的是**同一套 thread/turn/item 概念词汇**，但载体是扁平 NDJSON 的 `type` 字段，不是 JSON-RPC method 名——说明 Codex 内部大概率共享同一套"事件模型"，只是 exec 和 app-server 两层各自套了不同的传输皮。适配层如果同时要支持这两种模式，内部归一化模型可以按 thread/turn/item 三级设计，两条协议路径映射到同一套内部结构的成本应该不高。
5. **审批默认行为的可观测性天差地别**：multica 在 app-server 模式下能清楚看到"发生了一次审批请求，我方自动同意了"（有 RPC 往返可审计）；exec 模式下**连"发生过一次审批"这件事本身都观察不到**——拒绝就是沉默的空气墙。如果适配层的审计/可追溯性要求来自 multica 的参考设计（"至少要能证明系统确实拦截/放行过某个动作"），exec 模式在这一点上**先天信息量更少**，需要额外自建观测手段（比如任务前后对 cwd 做文件树快照 diff）才能补齐。

---

## 意外发现

1. **exec 会无条件尝试读 stdin，哪怕 prompt 已经作为参数传入**：8 次调用 stderr 第一行几乎都是 `Reading additional input from stdin...`，即使 prompt 是 CLI 位置参数、且我们把子进程 `stdin` 显式设为 `DEVNULL`。因为 `DEVNULL` 会立刻返回 EOF 所以没有卡住，但这暗示**如果调用方把 stdin 保留成一个"打开但没人写、也不关闭"的管道（比如某些进程池/PTY 场景的默认行为），exec 可能会挂起等 stdin，永远不会开始跑任务**。这是无头驱动最容易踩、后果最隐蔽的坑（表现为"进程卡住不产出任何 JSON 事件"，而不是报错）。
2. **`exec3` 的 90 秒硬超时不是卡在审批上，是卡在网络重连**：第一次尝试（`exec3-readonly-explicit-write`）触发了本机驱动脚本的安全网超时，起初怀疑是"headless 下没人能应答的审批请求把进程挂住了"；但流里实际内容是 `Reconnecting... 2/5` 到 `5/5` 的网络重连提示（`exec7` 的完整样本进一步证实：codex 对每个传输通道有 5 次重试，WebSocket 通道试完 5 次后回退到 HTTPS 通道再试 5 次，全部耗尽才报终态失败，全程可能耗时 40+ 秒）。这说明**exec 的失败路径天然较慢**（不是快速失败），适配层设置的"任务无响应看门狗"超时阈值要给网络重试链路留出至少 60-90 秒余量，避免把"还在正常重试"的任务误判成卡死。
3. **CODEX_HOME 是"用后即脏"的运行时状态盘，不是纯配置输入**：即使一开始只放了一份 `auth.json`，codex 运行几次后会在里面自动长出 `config.toml`（含自动写入的项目信任级别）、`sessions/`、`cache/`、多个 sqlite 状态库——和真实 `~/.codex` 的目录结构几乎同构。适配层如果参考 multica"每任务独立 CODEX_HOME"的模式，必须理解这是**每任务全新目录 + 用后即弃**，而不是"建一次、反复复用"的配置目录。

---

## 对适配层设计的直接影响

1. **隔离方案直接照抄"每任务独立 CODEX_HOME + 只拷贝 auth.json"**：本次证明这条路径在 exec 模式下同样成立，且是"fail closed"的（隔离目录没 auth 就直接 401，不会误用真实身份）。适配层不需要碰 `~/.codex/config.toml`，`sandbox_mode` 全部走 `-c sandbox_mode=<...>` 或 `-s <...>` 显式传，两者等价，选哪个看适配层是否已经在拼一份 `-c` 覆盖列表（有的话顺手带上更省一次特判）。
2. **不要用"审批 RPC 有没有响应"这类信号做拦截审计——exec 模式下根本没有这类信号**。如果适配层的产品需求包含"记录/审计系统拦截了哪些危险操作"，exec 模式必须自建观测：任务前后对 cwd（以及任何 `--add-dir` 追加目录）做文件树快照并 diff，把"预期落地但没落地的文件"当作拦截证据，不能像 multica 那样指望协议层给一条明确的拒绝事件。
3. **子进程必须显式绑定 `stdin=/dev/null`（或等价的已关闭输入），否则有静默挂起风险**——这是所有 exec 封装代码的强制项，不是可选优化。
4. **看门狗超时阈值要覆盖网络重试链路的最坏情况**（经验数据：两级传输 × 5 次重试，观测到耗时可达 40+ 秒），不能照抄"读到几秒没输出就判定卡死"的粗暴策略；应该以"是否还在收到 `error: Reconnecting...` 这类心跳式事件"作为"仍存活"的判据之一，而不仅仅是任意事件的到达间隔。
5. **退出码只有三态（0 成功 / 1 失败 / 负数=被信号杀死），失败原因要靠解析 `turn.failed.error.message` 里的双重编码 JSON 字符串**——适配层的错误分类逻辑需要做两层 JSON parse，并对 parse 失败留兜底（把原始字符串整体当错误信息展示）。
6. **中断直接复用 multica 那一套"进程组 SIGTERM，不经协议层"**，本次验证了 exec 模式下这套机制干净有效（无残留子进程），不需要为 exec 单独设计取消协议——但要注意 exec 没有 SIGTERM 处理器，中断后拿不到任何"任务被取消"的终态事件，适配层自己要在发出中断信号的那一刻就把任务标记为 aborted，不能等着流告诉你。
7. **如果适配层要同时支持 exec 和 app-server 两种模式（比如轻任务走 exec、重任务走 app-server），内部事件模型按 thread/turn/item 三级设计可以直接复用**，两边命名体系高度接近，归一化成本比预期低；但审批/权限相关的字段必须分叉处理（app-server 有、exec 没有），不能假设两条路径行为对称。
8. **不要用 stderr 内容做健康检查**：至少这个特定构建（ChatGPT App 内置 alpha 版）在成功任务里也会稳定打印多条 `ERROR` 级别日志（models 刷新超时、内置 MCP 连不上 chatgpt.com 后端、WebSocket 偶发降级到 HTTPS）。只能以退出码 + 终态事件类型为准；如果目标环境换成纯净开源 `codex` 二进制，这几条噪音大概率不存在，但"不能信 stderr 的 ERROR 字样"这条原则依然适用（保守起见）。
