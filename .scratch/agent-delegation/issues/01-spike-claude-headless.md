# 01: Spike — Claude Code headless 事件流实测

Status: resolved
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

## Answer

> 实测产出(本机 claude 2.1.212,8 次真实调用,累计 ≈$0.37)。样本/驱动脚本 + 完整 [findings.md](../research/spike-claude-headless/findings.md) 存 `research/spike-claude-headless/`(`run.sh` + `01-baseline-readonly` … `08-sigterm-mid-tool`)。主会话已审并回图。

1. **事件流 schema**:顶层 `type` 只有 5 种(`system`/`rate_limit_event`/`assistant`/`user`/`result`);`text`/`tool_use`/`thinking` 是 `assistant.message.content[]` 里的子块,`tool_result` 实际顶层 `type` 是 `"user"`(附带兄弟字段 `tool_use_result` 装结构化细节)。`session_id` 从第一条 `system/init` 事件起就确定,此后每一行都带。
2. **stdin 姿态**:`--input-format text`(默认)走位置参数;`--input-format stream-json` 走 stdin 一行 JSON。两次独立复现证实:stream-json 模式下写完 prompt 不发 EOF,进程在产出 `result` 之后**不会自己退出**,会一直阻塞到外部关闭 stdin 或杀进程——这是设计behavior,驱动方必须自己管生命周期。
3. **权限 bypass**:`bypassPermissions` 下工具直接执行(文件真实落盘)。不加时**不是挂起**,是 CLI 自动同步拒绝(合成一条 `is_error:true` 的 `tool_result`,回合仍正常收尾),`result.permission_denials[]` 结构化记录。默认档拒绝是无差别的(cwd 内的写入也照样拒),没有"仅放行 cwd 内"这种中间档。
4. **control_request**:8 次调用(含 2 次专门引诱场景)全部零命中 `control_request`/`control_response`。未授权工具调用走的是同步自动拒绝,不是协议层往返询问——与 multica 报告 `claude.go:439-481` 描述的应答逻辑不一致,判断为版本/触发条件漂移(报告代码可能针对交互式场景或更早协议版本),不是本次实测能反驳的通用结论。
5. **中断**:进程组 SIGTERM 精确命中、无残留(`ps` 扫描为空),两次都无需 SIGKILL 兜底,反应 <1s。收到信号后会先合成一条 `[Request interrupted by user]` 事件、再落终态 `result`(`terminal_reason:"aborted_streaming"`)才退出——drain 循环不能一发信号就弃管道。OS exit code 固定 143,不区分优雅/暴力。两次打断都卡在首 token 前(被 `system/api_retry` 顶出观察窗),未直接抓拍到"活的嵌套子进程被连带杀掉"这一更强证据,只有间接推断;SIGKILL 路径完全未触发。
6. **终态与退出码**:成功 exit 0(`subtype:"success"`,`is_error:false`,`terminal_reason:"completed"`);失败(如 model 不存在)exit 1,但 `subtype` 仍是 `"success"`——**必须联合 `is_error`/`terminal_reason`/`api_error_status` 判定**,不能只看 `subtype`;中断 exit 143(`subtype:"error_during_execution"`)。
7. **工作目录约束**:没有隔离效果。bypass 下相对路径 `../` 越界和绝对路径 `/tmp/...` 越界写入均成功,无拒绝无提示,事件形状与 cwd 内正常写入完全一致。`--add-dir`/cwd 只是默认解析基准,不是安全边界;真要隔离必须上 OS 级手段。

**与 multica 报告的主要分歧**:仅 `control_request`(第 4 题)——报告描述的同步应答逻辑本次实测未复现,判断为协议随版本演进产生的漂移,与票面预判("文档与二进制可能不一致")一致。其余(prompt 传递方式、stdin 保持打开、bypass 必要性、中断走进程组信号)方向一致,且本次补上了报告没细说的具体后果和新字段(如 `caller`、`interrupt_receipt_v1`、`permission_denials[]`)。

**对适配层设计的直接影响**(详见子代理回复全文):stdin 生命周期需显式管理;bypass 是能力开关不是安全开关且只有两档;cwd 不能当沙箱、需要 OS 级隔离；`-p` 单发场景大概率不需要实现 `control_request` 应答但要留兜底；中断后要把管道读到底；终态判定要联合多个字段；无头子进程默认继承宿主机全部插件/技能/自定义 agent 面(`Task`/`SendMessage` 等),需要显式 `--tools`/`--safe-mode` 收紧。
