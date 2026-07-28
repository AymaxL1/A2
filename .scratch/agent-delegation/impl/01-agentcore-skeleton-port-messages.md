# 01 — AAAgentCore 骨架:AgentPort 协议 + 6 型消息 + Fake + 门禁接入

**What to build:** 平台多一个纯逻辑 target `AAAgentCore`(只依赖 AAContracts),里面有一次 agent 进程执行的抽象 `AgentPort` 与平台统一的 6 型消息模型,以及一个可编程的 `FakeAgentPort` 供上层纯逻辑测试;这套地基编译进 `Scripts/check.sh` 门禁并有一组 TestReport 冒烟断言证明它活着。此票交付后,后续所有票都能在假件上开工。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent
**验证环:** vfsoverlay 可验(纯逻辑 + executable,无需 Xcode、无需真 agent)。

- [ ] `Package.swift` 新增 library target `AAAgentCore`,依赖仅 `AAContracts`;产品导出。
- [ ] `AgentPort` 协议:以 `(可执行路径, 参数, 环境, 工作目录, stdin 处置)` 启动一次 agent 进程,返回句柄 + 可逐行读取的事件流;含探活、进程组终止的接口形状。句柄为不透明值类型(样板 `AAPluginSDK.ProcessHandle`)。
- [ ] 6 型统一消息 `Codable` 模型:`text/thinking/tool-use/tool-result/status/error`,工具调用带 `callID` 字段(全链保留);round-trip 可编解码。
- [ ] `FakeAgentPort`(放 AAHostTestKit 或新 `AAAgentTestKit`,归实施):可编程「回放预置 stdout 事件脚本」「编程 launch 失败」「编程进程中途死亡」,并记录 launch 参数与终止信号序列(样板 `FakeProcessPort`)。
- [ ] 接入 `Scripts/check.sh`:AAAgentCore 按拓扑序 vfsoverlay 直编;新增 `AAAgentCoreConformanceTests`(TestReport 同构模式,**不得 import Testing**)并入动态 runner。
- [ ] TestReport 冒烟:FakeAgentPort 基本行为(launch 记录/编程失败/编程死亡)+ 6 型消息 Codable round-trip 各至少一条断言,`check.sh` 全绿。
- [ ] 铁律:AAAgentCore 不 import 任何 `Host*`(check.sh grep 强制,与 PluginProxy 同级)。
