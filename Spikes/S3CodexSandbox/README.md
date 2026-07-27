# S3 Codex↔CLI 沙箱实测（PROTOTYPE — 抛弃式，不进产品代码）

> 回答的问题（`docs/v1-roadmap.md` Phase 0 / S3，源自 05 票遗留最关键项）：**Codex workspace-write 沙箱是否拦截 CLI↔宿主的本地 IPC？**
> 结论：**拦，而且全拦。** 详见 Findings。

## 方法

- `server.py`（本会话非沙箱运行）：三端点回声服务——①工作区外 UDS（`~/Library/Application Support/S3Spike/aa.sock`）②工作区内 UDS（`workspace/aa.sock`）③TCP `127.0.0.1:8737`。
- `workspace/probe.py`：逐端点 connect 并输出 JSON 行。
- 基线：本会话直接跑 probe → 三端点全通（排除服务端因素）。
- 实测：`codex exec -s workspace-write -C workspace --skip-git-repo-check "运行 python3 probe.py …"`（codex-cli 0.146.0-alpha.3.1，2026-07-28，消耗用户 Codex 配额 18,572 tokens）。

## Findings（2026-07-28）

| 端点 | 基线（非沙箱） | workspace-write 沙箱内 |
|---|---|---|
| UDS（工作区外） | ✅ | ❌ `EPERM Operation not permitted` |
| UDS（工作区内，可写目录） | ✅ | ❌ `EPERM` |
| TCP localhost | ✅ | ❌ `EPERM` |

1. **workspace-write 只放行文件系统写（workdir、/tmp、$TMPDIR），socket 类操作一律禁止**——`connect()` 系统调用层面被 seatbelt 拒绝，与 socket 文件所在目录是否可写无关。07 票预设的两条技术备选（UDS、localhost 短连）在沙箱内**全部不成立**。
2. **幸存路径 = 提权信任**：从 codex 二进制 strings 证实机制——模型可为命令声明 `sandbox_permissions: "require_escalated"` 并附 `prefix_rule`（如 `["aa"]`），Codex 把它作为「可持久化的允许规则」呈现给用户，一次批准、后续会话复用；受信命令在**沙箱外**执行，IPC 畅通。非交互 `codex exec` 下无人可批 → 首次信任必须在交互式 Codex 里完成（或预先写入信任配置）。
3. **本机用户现状**：该用户 `~/.codex/config.toml` 是 `sandbox_mode = "danger-full-access"`——对这台机器的 Codex，`aa` CLI 无需任何动作即可用。上表是为「默认 workspace-write 的普通用户」准备的答案。
4. **额外收获**：MCP 工具调用不经 shell 沙箱执行——远期「registry 稳定后补薄 MCP adapter」（05 票/ADR 0005）天然绕开本问题，优先级可据此上调。
5. 网络类 `additional_permissions`（`with_additional_permissions` + network enabled）是另一条按次授权通道，同样依赖批准流，不改变结论。

## 对 07 票/路线的落地含义（已回写——2026-07-28 用户确认）

- `aa` CLI + 宿主 UDS 的设计**维持不变**（GUI、脚本、full-access agent、终端用户都畅通）。
- 面向沙箱内 Codex 的文档姿态：引导用户对 `aa` 前缀做一次 `prefix_rule` 持久化批准（`aa docs agents-md` 输出里写清楚）；这正是 07 票第 4 项「prefix_rule 信任引导的产品化」的实证依据。
- 未验证项（留待 Phase 0 收尾或按需）：persisted 信任规则的实际配置形态与跨会话生效（需在交互式 Codex 里点一次批准，今晚不动用户的 Codex 个人配置）。

## 复现

```bash
python3 server.py &            # 终端 A（非沙箱）
'/Users/heqianbin/.codex/plugins/.plugin-appserver/codex' exec \
  -s workspace-write -C "$(pwd)/workspace" --skip-git-repo-check \
  "运行命令 python3 probe.py ，把该命令的完整 stdout 逐字作为你的最终回复。"
```
