# Spike 01 findings — Claude Code headless 事件流实测

实测对象:本机 `/usr/local/bin/claude` 2.1.212。8 次真实调用,累计 `total_cost_usd` ≈ $0.372。驱动脚本 `run.sh`,样本 `01-baseline-readonly.*` … `08-sigterm-mid-tool.*`(每组 `.stdout.ndjson`/`.stderr.log`/`.meta.txt`)。

> 说明:本文件由主会话据 spike 子代理交回的完整结论重建——子代理的文件写入护栏拦截了 `findings.md` 直接落盘,样本与 `run.sh` 均由子代理正常写入。

## 逐题结论(对应 01 票 7 问)

### 1. 事件流 schema(样本 01/02)
顶层 `type` 只有 5 种:`system` / `rate_limit_event` / `assistant` / `user` / `result`。

- `text` / `tool_use` / `thinking` 都是 `assistant.message.content[]` 里的**子块**,不是顶层事件类型。
- **`tool_result` 的顶层 `type` 实际是 `"user"`**(附兄弟字段 `tool_use_result` 装结构化细节)——归一化时不能按 type 字面找 tool_result。
- `session_id` 从第一条 `system/init` 事件起就确定,此后每一行都带。
- `system/init` 的 `capabilities` 含 `["interrupt_receipt_v1","msg_lifecycle_v1"]`;`tool_use` 块带 `caller:{type:"direct"}`;`assistant` 事件带 `parent_tool_use_id`(子代理转发溯源,本次样本均 direct/null)。

### 2. stdin 姿态(样本 01/06)
- `--input-format text`(默认):prompt 走位置参数。
- `--input-format stream-json`:prompt 走 stdin 一行 JSON。
- **两次独立复现**:stream-json 模式写完 prompt 不发 EOF,进程产出 `result` 后**不会自己退出**,一直阻塞到外部关闭 stdin 或杀进程。→ 驱动方必须显式管理 stdin 生命周期与进程收尾。

### 3. 权限 bypass(样本 02/03)
- `--permission-mode bypassPermissions`:工具直接执行(文件真实落盘)。
- 不加时**不是挂起**,是 CLI **同步自动拒绝**:合成一条 `is_error:true` 的 tool_result,回合仍正常收尾,`result.permission_denials[]` 结构化记录。
- 默认档拒绝**无差别**:cwd 内的写入也照样拒——**没有「仅放行 cwd 内」的中间档**。bypass 是「全放行 / 无差别拒绝」两态开关。

### 4. control_request(样本 03,专门引诱)
- 8 次调用(含 2 次专门引诱场景)**零命中** `control_request`/`control_response`。
- 未授权工具调用走同步自动拒绝(见第 3 题),不是协议往返询问。
- 与 multica 报告 `claude.go:439-481` 描述的应答逻辑**不一致**——判断为版本/触发条件漂移(报告代码可能针对交互式场景或更早协议版本),与票面预判「文档与二进制可能不一致」吻合。

### 5. 中断(样本 04/08)
- 进程组 SIGTERM 精确命中、无残留(`ps` 扫描为空),两次均 <1s 优雅退出,**无需 SIGKILL 兜底**(该路径完全未触发)。
- 收到信号后先合成 `[Request interrupted by user]` 事件、再落终态 `result`(`terminal_reason:"aborted_streaming"`)才退出。→ **drain 循环不能一发信号就弃管道**,要读到底。
- OS exit code 固定 **143**,不区分优雅/暴力。
- 局限:两次打断都卡在首 token 前(被 `system/api_retry` 顶出观察窗),未直接抓拍「活的嵌套子进程被连带杀掉」的强证据,只有间接推断。

### 6. 终态与退出码(样本 01/05)
- 成功:exit 0(`subtype:"success"`,`is_error:false`,`terminal_reason:"completed"`)。
- 失败(如 model 不存在):exit 1,但 **`subtype` 仍是 `"success"`**——必须联合 `is_error` / `terminal_reason` / `api_error_status` 判定,不能只看 subtype。
- 中断:exit 143(`subtype:"error_during_execution"`)。

### 7. 工作目录约束(样本 07,越界写)
- **没有隔离效果**。bypass 下相对路径 `../` 越界、绝对路径 `/tmp/...` 越界写入**均成功**,无拒绝无提示,事件形状与 cwd 内正常写入完全一致。
- `--add-dir` / cwd 只是默认解析基准,**不是安全边界**。真要隔离必须上 OS 级手段。

## 与 multica 报告对照

**方向一致(4 项)**:prompt 传递方式(arg vs stdin,由 `--input-format` 决定)、stdin 保持打开的设计意图、bypass 是让 agent 真正干活的必要项、中断走进程组信号而非协议层。

**唯一实质分歧**:`control_request` 双向应答(第 4 题)——multica 报告描述 Claude 在 stream-json 里同步应答 control_request,本次 8 次调用(含 2 次引诱)从未观察到,未授权工具调用改为同步自动拒绝。判断为版本/触发条件漂移,而非报告有误。

本次还补上了报告没细说的字段:`caller`、`interrupt_receipt_v1`/`msg_lifecycle_v1` capabilities、`permission_denials[]`。

## 对适配层设计的直接影响

1. **stdin 生命周期需显式管理**——stream-json 模式进程不自退,适配器负责关 stdin/收尾。
2. **bypass 是能力开关不是安全开关,且只有两档**——设计双层信任时不能指望 Claude 给「仅 cwd 内」的中间档。
3. **cwd 不能当沙箱**——Claude 侧任务隔离要 OS 级手段(sandbox-exec 等),或在 spec 里显式声明「任务目录外不设防」的信任假设。⚠️ 与 Codex 有真沙箱(02 spike)不对称,归一化/信任模型要分别处理。
4. **`-p` 单发场景大概率不需实现 control_request 应答**,但留兜底。
5. **中断后要把管道读到底**(先收 `[Request interrupted]` 再收 result)。
6. **终态判定要联合多字段**(subtype 不可靠)。
7. **无头子进程默认继承宿主机全部插件/技能/自定义 agent 面**(`Task`/`SendMessage`/`RemoteTrigger` 等本机项目工具都在,不是 vanilla claude)——适配器必须 `--tools`/`--strict-mcp-config` 显式收紧被委托 agent 的能力面,否则失控。

## 踩坑备忘(非结论,供实现参考)
- 每次调用(哪怕「回复 OK」)会隐性触发一次 `claude-haiku-4-5` 小额用量(内部分类/标题生成,约几厘钱)。
- `system/api_retry`(指数退避)8 次里出现 2 次,CLI 自带重试且透明上报到流里。
- 中断场景 `total_cost_usd` 为 0(模型请求真正完成前中断不计费)。
- `--bare` 会把认证限定为 `ANTHROPIC_API_KEY`/`apiKeyHelper`,本机是订阅 OAuth,`--bare` 会打不开认证——勿用。
