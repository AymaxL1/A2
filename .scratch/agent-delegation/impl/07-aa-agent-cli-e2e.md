# 07 — 试驾 CLI(aa-agent)收口 + 两家启动参数组装 + 端到端

**What to build:** 一个能真用的委托入口 `aa-agent`:`run` 组装委托(prompt/agent/model/workdir)、按 agent 选 adapter、经 SystemAgentPort 真拉起、落盘、判终态、出 HTML 报告;`status/cancel/list/prune` 管理任务。把前六票拼成端到端可跑的一刀,并真拉起 claude/codex 各跑一个最小任务做冒烟。这是本模块的旗舰验收面。

**Blocked by:** 02, 03, 04, 05, 06(要归一化 + 状态机 + 看门狗/取消 + 真 Port 全部就位)。

**Status:** ready-for-agent
**验证环:** CLI 解析/参数组装 vfsoverlay 可验;端到端冒烟需真 claude/codex(手动,非日常门禁)。

- [ ] `aa-agent` executable target(依赖 AAAgentCore + SystemAgentPort;**不碰现有 `aa`/AAHostMacOS**),`run|status|cancel|list|prune` 子命令 + 退出码复用 `AAContracts.AAExitCode`。
- [ ] Claude 启动参数组装:`-p --output-format stream-json --input-format stream-json` + **`--permission-mode bypassPermissions`(blocked-args 不可覆盖)** + 能力面收紧(`--strict-mcp-config` + 工具白名单) + `--model` 透传 + stdin 保持打开显式收尾。
- [ ] Codex 启动参数组装:`exec --json` + stdin `/dev/null` + `-s/--sandbox` 或 `-c sandbox_mode=` + **每任务独立 `$CODEX_HOME`(只拷 `auth.json` 不拷 `config.toml`,用完即弃)** + model 透传。
- [ ] `run` 完整链路:建工作区 → 拉起 → 归一化落盘 → 看门狗/可取消 → 终态 → report.html → 完成信息指向报告路径。
- [ ] `prune` 只删终态、永不删 running;`list` 显示条数 + 磁盘占用。
- [ ] CLI 解析与参数组装的 vfsoverlay 可验断言(不拉真进程);端到端冒烟脚本:真跑 claude 一个只读诊断任务 + codex 一个最小任务,断言终态与 report.html 产出(手动,标注真实配额消耗)。
- [ ] 旗舰验收辞点验(手动 ready-for-human):委托一次经 `aa demo.note.set` 的可逆改动零打断、一次经 `aa demo.wipe` 的 dangerous 改动触发宿主确认且拒绝分支能挡住。
