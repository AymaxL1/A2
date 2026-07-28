# 02: Spike — Codex exec headless 事件流实测

Status: claimed
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
