# 06 spec 定稿

Type: task
Status: resolved
Blocked by: 02, 03, 04, 05

## Question

把全图决策收束成 `.scratch/url-router/spec.md` 定稿(即本图 Destination)。必须覆盖:

- **能力契约**(ADR 0004 全要素):`url-router` 能力面 —— 稳定 ID/版本、输入输出 schema、
  query/command 之分、风险级(takeover/restore = dangerous,route = safe)、幂等、超时、
  结构化错误、测试样例;
- **CLI 面**:`a2 url-router takeover|restore|route|status`(+ `--dry-run`)的机读输出与
  退出码语义;
- **UDS 协议**:壳转发 URL 的帧/能力形态、配置快照推送(按 03 裁定);
- **壳侧改动**:CFBundleURLTypes、kAEGetURL 处理、机械兜底(按 03)、机械执行器(按 04);
- **体验章**:退出 A2 后的降级故事(点链接 → LS 拉起壳 → 内核停着 → 兜底 + 节流通知),
  与 takeover/restore 的弹框-等待-超时旅程;
- **配置 schema**:`~/.a2` 下的落点、字段(承接参考项目 config.example.json 全参数)、
  敏感字段纪律;
- **门禁修订**:build-app.sh 断言(APP14+)与 kernel 测试面;
- **ADR 清单**:0008 修订(壳兜底豁免措辞,按 03)+ 新 ADR(URL 分流与默认浏览器接管,
  含裁决序对照)是否成立;
- **移植对照表**:ClaudeURLRouter.swift 各段 → 内核模块落点(吃 02 的平台事实);
- **验收清单**:施工 effort 开票用。

AFK 起草,用户 CR 通过 = 收图。

## Answer

[spec.md](../spec.md) 定稿:2026-09-03 起草,同日用户 CR 通过(含草稿自定细节:
壳转发超时 1.5s、幂等判据、`partial` 报文、V1 不做 config 子命令)。
本图 Destination 达成,施工按 spec §14 另立 effort。

## Comments

- 2026-09-03:spec 草稿已成([spec.md](../spec.md)),覆盖 Question 全部条目;待用户 CR。
  两处对既有契约的咬合值得 CR 时重点看:①确认模型完整复用既有退出码词表
  (`confirmation_unavailable`/`denied`=2、`timeout`=3);②壳转发 URL 零新帧
  (壳作为客户端调同一条 `url-router.route`),UDS 增量只有快照 `urlRouter` 节
  与执行指令帧两条。
