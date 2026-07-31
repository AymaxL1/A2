# 02: Spike — Codex exec headless 事件流实测

Status: resolved
Type: task
Blocked by: (无)

## Question

`codex exec --json` 被无头驱动时的真实行为是什么?本机是 0.146.0-alpha(`~/.codex/plugins/.plugin-appserver/codex`,不在 PATH),alpha 版行为漂移风险高,必须实测。

验证清单(纯脚本,不需要 Xcode):

1. **事件流 schema**:一次小型只读任务的完整 JSON 输出样本——事件类型、字段形状、session/thread id 的获取方式(multica 靠等 rollout 文件落盘,exec 模式如何?)。
2. **sandbox 与审批**:`sandbox_mode`(workspace-write / danger-full-access)在 exec 模式下怎么传(CLI flag?config.toml?env?);用户现有 `~/.codex/config.toml` 是 `danger-full-access`,委托时如何按任务覆盖而不污染用户全局配置(multica 用每任务 `$CODEX_HOME` 隔离,exec 模式是否同样可行)。
3. **审批请求**:exec 模式下是否还会发审批类请求(app-server 会发 `execCommandApproval` 等 RPC);会的话默认行为是什么(自动同意?挂起?拒绝?)。
4. **中断**:进程组 SIGTERM/SIGKILL 实测,退出码与残留进程。
5. **终态与退出码**:成功/失败/中断的退出码语义;stderr 上有什么。
6. **工作目录**:cwd 隔离与越界写实测。
7. **PATH 姿态**:不在 PATH 的二进制全路径调用有无额外坑(相对资源查找、自更新行为)。

产物:原始 JSON 样本 + 结论摘要存 `research/spike-codex-exec/`,回写本票 `## Answer`。注意:spike 会真实消耗 Codex 配额,任务 prompt 取最小。

## Answer

实测对象 `codex-cli 0.146.0-alpha.3.1`(ChatGPT App 内置 plugin-appserver 分支)。8 次 `codex exec` 实调用 + 5 次免费 `--help`/`--version`,全部证据在 `research/spike-codex-exec/samples/`,驱动脚本 `research/spike-codex-exec/driver.py`,完整报告 `research/spike-codex-exec/findings.md`(逐题证据引用、与 multica app-server 面的关键差异、对适配层设计的直接影响,详见该文件)。以下为浓缩结论:

1. **事件流 schema**:`--json` 输出扁平 NDJSON,`type` 取值 `thread.started/turn.started/item.started/item.completed/turn.completed/turn.failed` + 非终态 `error`。**session/thread id 就是第一行**`thread.started.thread_id`,不需要等任何文件落盘——这是与 multica(等 rollout 文件)最直接的差异。
2. **sandbox_mode 传递**:CLI flag `-s/--sandbox` 与 `-c sandbox_mode=<value>` 均实测生效,无 env 变量路径;裸 `CODEX_HOME`+不传 flag 时默认等效 `read-only`。**每任务独立 `$CODEX_HOME`(只拷贝 `auth.json`,不拷贝 `config.toml`)隔离方案可行**,且反向验证:隔离目录缺 auth 时是 fail-closed(直接 401),不会静默回退到真实 `~/.codex` 身份。
3. **审批请求**:`codex exec --help` 本身没有 `-a/--ask-for-approval` 暴露;三次"应当被拒绝的写"实验(默认档、显式 read-only、workspace-write 越界)里**从未出现任何审批类事件**,被拒绝的调用连 `item.started` 都不会出现在流里——不是"收到拒绝事件",而是"这次调用像没发生过",与 multica 在 app-server 协议上能收到并自动应答 `execCommandApproval` 等 RPC 完全不是一回事。只能靠事后 diff 文件系统确认是否被拦。
4. **中断**:进程组 `SIGTERM` 实测干净有效——codex 无 SIGTERM handler,信号发出后进程带着整棵子进程树(含 shell 派生的 `sleep` 孙进程)几乎瞬时死亡(`returncode=-15`),两次独立 `ps` 复查均无残留,SIGKILL 兜底路径全程未触发(没需要)。中断不产生任何终态 JSON 事件,适配层需自行在发信号那一刻标记任务为 aborted。
5. **终态与退出码**:成功 `0`(`turn.completed`+usage);失败 `1`(`turn.failed`,`error.message` 是双重编码的 JSON 字符串,400/401 等不同错因不体现在退出码上,需 parse 两层);中断为负的信号号(`-15`)。stderr 里出现 `ERROR` 字样不能作为失败判据——成功任务的 stderr 也稳定带噪音(见第 7 点)。
6. **工作目录**:`workspace-write` 下 cwd 内写入成功且真实落盘,cwd 上一级的越界写被拦(文件确认未生成),拦截同样是静默的(无对应 item)。未测 `--add-dir`/`$TMPDIR` 是否在默认可写白名单内。
7. **PATH 姿态**:全路径调用 + PATH 清空后功能不受影响(codex 用绝对路径 `/bin/zsh -lc` 拉起 shell,不走 PATH 查找);未观测到 `exec` 路径下有自动更新行为。但这个具体二进制(ChatGPT App 内置 alpha,非纯净开源 codex)每次调用都会稳定打印几类无害但吓人的 `ERROR` 日志(models 刷新超时、内置 MCP 连 `chatgpt.com` 后端失败、WebSocket 偶发降级到 HTTPS 后自动恢复),是该定制构建的旁路依赖噪音,不代表上游通用行为,但提醒:不能用 stderr 内容做健康检查。

意外发现:①exec 无条件尝试读 stdin(即使 prompt 已经是参数),必须显式 `stdin=/dev/null` 否则有静默挂起风险;②失败路径的网络重连(两级传输 × 5 次重试)可能耗时 40+ 秒,看门狗超时阈值要留够余量,不能当成"卡死"误杀;③`$CODEX_HOME` 是用后即脏的运行时状态盘(auth.json 之外还会自动长出 config.toml/sessions/cache/sqlite),适配层要按"每任务新建、用完即弃"设计,不能长期复用。

护栏合规:全程未修改 `~/.codex`(mtime 比对确认);`auth.json` 副本已删除且已用 grep 交叉验证密钥材料未出现在任何样本文件中;`sandbox/` 已清空;信号只发给自建进程组;sandbox_mode 实验全程未使用 `danger-full-access` 执行任务。
