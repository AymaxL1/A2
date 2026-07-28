# 01: Spike — Claude Code headless 事件流实测

Status: open
Type: task
Blocked by: (无)

## Question

`claude -p --output-format stream-json` 被无头驱动时的真实行为是什么?文档与二进制可能不一致(multica 报告实证过文档漂移),适配层设计吃的是实测事实。

验证清单(本机 claude 2.1.212,纯脚本,不需要 Xcode):

1. **事件流 schema**:一次真实任务(小型只读诊断 prompt)的完整 NDJSON 样本——事件类型清单、text/thinking/tool_use/tool_result 的字段形状、`session_id` 出现的位置与时机。
2. **stdin 姿态**:`-p` 模式下 prompt 走参数还是 stdin?stdin 保持打开会怎样(multica 对 claude 是写完保持打开)?
3. **权限 bypass**:`--permission-mode bypassPermissions` 生效的实测证据;不加时 `-p` 模式会发生什么(挂起等审批?直接拒绝?)——这决定 blocked-args 黑名单是否必须。
4. **control_request**:`-p` 单发模式下是否还会出现 `control_request` 类双向消息(multica 在交互流里要应答它);出现的话不应答会怎样。
5. **中断**:任务中途对进程组发 SIGTERM,退出码/末尾事件/残留子进程实测;SIGKILL 兜底路径。
6. **终态与退出码**:成功/失败/中断三种情形的退出码语义与最后一条事件的形状。
7. **工作目录约束**:`--add-dir`/cwd 的实际隔离效果,agent 越出工作目录写文件是否可能。

产物:原始 NDJSON 样本 + 结论摘要存 `research/spike-claude-headless/`,回写本票 `## Answer`。注意:spike 会真实消耗 Claude 配额,任务 prompt 取最小。
