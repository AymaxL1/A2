# 07 — 决定:目标架构映射与迁移切法

Type: grilling
Status: resolved

Blocked by: 04, 05, 06

## Question

把 04/05/06 的结论落成可开工的工程蓝图:

1. **target 图重画**:Package.swift 现图(`AAHostMacOS` 同持 UDS server、菜单栏、各系统端口实现)按新边界拆分——无头内核 target 群、壳 target 群、共享契约;`aa`/`aahost`/`aa-agent`/新可执行的依赖箭头;「插件不得 import Host*」红线在新图的等价物。
2. **迁移路径**:现有代码哪些动/不动、动的去向;可合并的增量切步(每步门禁绿)排序;`Scripts/check.sh`(428 断言)与 `flagship-e2e.sh` 在新拓扑下的适配点。
3. **命名定案**:内核 bin、壳 app、target 前缀。

产出 = 重构蓝图,后续实施效fort按它拆票。

## Answer

2026-08-04 现场面试四问钉死(用户逐项拍板):

1. **仓库形态 = 同仓 monorepo**:本仓新增 `kernel/`(TS 工程:`src/`、`package.json`、`bun.lock`、协议 schema),Swift 壳继续住 `Sources/`。协议同仓同步演进、切换原子(04 票「全换不并行」的落地条件)、门禁一体、git 历史连续、Swift 行为规范参考在侧。目标 target 图:`kernel/` 产出唯一 bin `a2`(内含 daemon/CLI/协议三模块群);Swift 侧收敛为壳 target 群(`a2-panel` + UI 资产 + 契约对照),`AAHostRuntime`/`AAAgentCore` 等逻辑 target 降为行为规范参考、⑤步切换后退场。
2. **契约源 = TS 为源 + 契约快照测试**:报文类型在 `kernel/` 以 TS 可序列化 schema(如 zod)定义,导出 JSON Schema 作机器可读契约(也是将来 agent 写客户端/插件的土壤);Swift 侧手写 Codable 对照;双端对同一批金标报文样本做编解码快照,契约变更即门禁报警。不引入代码生成链。
3. **命名定案 = a2 系**(用户裁定,品牌级改名;原「aa」系全面退场):内核 bin = **`a2`**(命令小写),常驻入口 `a2 daemon run`,服务管理 `a2 service …`;菜单栏壳 target/可执行 = **`a2-panel`**,.app 显示名「A2 Panel」;TS 工程住 `kernel/`。中文概念名不变(「菜单栏壳」「确认器」)。**连动修订**:路径约定改 **`~/.a2`**(环境变量 `A2_HOME`,socket `~/.a2/run/kernel.sock`),unit 命名空间 **`com.a2.*`**(内核与 mihomo 托管 unit 同源)——04 票⑦原文随此修订;旧名 `aahost`/`aa`/`aa-agent` 随废弃退场(「壳 app 为何叫 shell」之问已裁:英文 shell 与命令行 shell 撞名,工程标识符用 panel,壳仅作中文概念名)。
4. **迁移切步 = ①→②→③→④→⑤→⑥,每步可合并、门禁绿**:①契约与骨架(`kernel/` 工程+协议 schema+`a2 daemon run` UDS 骨架+TS 门禁起步;Swift 不动、`check.sh` 保绿)→ ②控制面重建(registry/runtime 等价物+CLI 子命令面(结构化输出/拒绝即指引)+`a2 service`;以 Swift 逻辑与 428 断言为行为规范对照)→ ③mihomo 监督面(安装脚本/配置管理/自启 unit/存活探测/实例接管阶梯,04 票④)→ ④仲裁与确认器协议(dangerous 三层+角色注册/订阅推送;壳未接入时默拒层即生效,Linux 形态先天成立)→ ⑤**壳原子切换**(`a2-panel` 改喂养源接新内核;废除 `aahost`/`aa`/`aa-agent`;快照测试跟切;门禁由 `check.sh` 切至 TS 门禁+壳快照——唯一的门禁切换点)→ ⑥插件宿主(`BUN_BE_BUN` 拉起+13 票协议,蓝图预留位)。`flagship-e2e.sh` 在⑤随 CLI 重写为对 `a2` 的端到端;门禁口径细则归 08 票。
5. **红线在新图的等价物**:「插件不得 import Host*」→「插件 = 进程外子进程,能力只经协议白名单」(细化归 13 票);壳侧新红线:**`a2-panel` 不得含业务逻辑**,只做事件投影+确认器呈现。
