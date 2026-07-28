# 05 — agent-first 命令面与接入引导

**What to build:** 让外部 Agent 与人类都好用:从注册表元数据映射出人体工学域子命令(如 `aa proxy …`,与 capabilities 底座同源);`aa docs agents-md` 输出可贴进任意仓库 AGENTS.md 的接入片段,内置 Codex `prefix_rule` 一行信任配置示例(S3 裁定的唯一官方沙箱姿态);`aa install-cli` 建符号链接入 PATH;宿主未运行时的报错与启动提示成为正式 UX。

**Blocked by:** 03

**Status:** ready-for-agent

**验证环:** vfsoverlay(今天可验)。

- [ ] 域子命令与 `capabilities call` 底座行为一致(同一注册表路由,输出与退出码同契约)
- [ ] `aa docs agents-md` 输出含:何时用本 CLI、发现/调用命令、prefix_rule 配置示例、dangerous 语义说明
- [ ] `aa install-cli` 幂等可重跑;卸载/覆盖行为明确
- [ ] 宿主未运行:人类可读提示 + 机读错误结构 + 专属退出码
- [ ] check.sh 全绿
