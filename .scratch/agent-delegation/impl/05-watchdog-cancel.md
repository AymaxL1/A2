# 05 — 消息静默看门狗 + 取消语义(经 Fake Port)

**What to build:** 平台能在 agent 长时间无输出时判定卡死并终止任务,且在工具调用在途时放宽超时预算不误杀;用户取消一个 running 任务时,状态机干净迁移到 cancelled 并发出终止意图。全部纯逻辑(经 Fake Clock/Agent Port),把两家 spike 暴露的中断行为差异收敛成统一语义。

**Blocked by:** 01(Port);04(取消/超时作用于任务状态机)。

**Status:** ready-for-agent
**验证环:** vfsoverlay 可验(ClockPort 注入时间,零真实等待、零真进程)。

- [ ] 消息静默看门狗:以 ClockPort 驱动,`静默时长 > 阈值` 判卡死 → 触发终止 → 状态迁 `timeout`;阈值可配。
- [ ] 工具在途放宽:存在未闭合 tool-use 时给更大超时预算(须容忍 Codex 40+s 网络重连,不误杀)。
- [ ] 取消:用户取消 running 任务 → 状态机迁 `cancelled` + 向 AgentPort 发终止意图(实际信号在 06 真实现);Fake Port 断言收到终止调用。
- [ ] 中断的两家差异收敛为域逻辑:Claude 中断后事件流会先补 `[Request interrupted]` 再落终态 → **drain 读到底**;Codex 中断不产终态 JSON → **发信号那刻自标 aborted**。此差异在状态机/drain 逻辑层显式处理。
- [ ] 测试经 Fake Port:静默超时触发一条、工具在途放宽不误杀一条、取消迁移 + 终止调用一条、两家中断收敛各一条。
