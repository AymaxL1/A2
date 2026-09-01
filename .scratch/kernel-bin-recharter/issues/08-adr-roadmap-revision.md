# 08 — 收图:ADR 批次修订 + 路线图修订

Type: grilling
Status: resolved

Blocked by: 07, 13

## Question

1. **ADR 批次**:新增「内核 bin 化 / UI 可选」ADR;修订 0005(dangerous 确认新模型);视 01 票结论处置 0001/0002(跨端与语言);0007 义务面(关于页 → 无 GUI 形态)的新落点;对 agent-delegation spec 的修订指令。
2. **路线图重写**:`docs/v1-roadmap.md` —— Phase 1 出口判据是否随新架构重写、17 票与 5 条人工项落位(方向取 01 票)、重构效fort的阶段位置、MCP adapter 时点(雾区项)顺带裁或继续挂起。
3. **收图检查**:Decisions so far 全量索引核对、雾区清空或显式移交、宣布到达 destination。

## Answer

2026-08-04 现场面试三问钉死(用户逐项拍板),并完成收图检查:

1. **分发与 GPL 处置**(清雾区「分发形态与 GPL 义务面收缩处置」):渠道 V1 = **单文件直接下载 + curl 安装脚本**,Homebrew Formula 列后续;`a2-panel.app` 随附带包。GPL:**内核重签校验废除**(15 票产物,其分发合规前提随 12 票消失);关于页降级为「调用外部 GPL 程序」声明;新增 **`a2 about` 子命令 + 随包静态文本**为不依赖 UI 的必有落点(03 票建议采纳);ADR 0007 修订反映义务收缩,独立子进程红线保留并泛化(13 票口径)。
2. **ADR 批次七条全定**:①新增总纲 ADR「内核 bin 化与 UI 可选」(01/04/06 票);②ADR 0001 废止重立→「macOS+Linux 当下承诺,Windows 远景不设预留」(10 票);③ADR 0002 废止重立→「TS 内核(Bun 单 bin)+ Swift 菜单栏壳」(10/11 票);④ADR 0005 修订→三层仲裁+确认器+长连接在场,CLI 永不阻塞/TTY 禁令保持(05 票);⑤ADR 0007 修订→外部安装+义务收缩为声明+红线泛化+`a2 about` 落点(12/13 票+本票第 1 问);⑥新增 ADR「插件 exec 协议与装载」(13 票);⑦agent-delegation spec 修订指令(非 ADR):审批收敛内核统一仲裁、执行器内核内 TS 重生、壳无专属通道(04/05/06 票)。ADR 正文撰写属实施工作,随 /to-spec 效fort落地。
3. **路线图重写包全定**(清雾区「TS 门禁口径」「5 条人工项落位」「MCP adapter 时点」):`docs/v1-roadmap.md` 的 **Phase 1 出口判据改为蓝图第⑤步完成**(a2 单 bin+service 安装+mihomo 监督+三层仲裁+壳原子切换+门禁切换);**17 票**合入 main 后价值转为行为规范参考;**5 条人工项**顺延到⑤后按新形态重定义(签名仪式→`a2-panel.app`、TCC/通知授权→确认器、实测项→对 `a2` 重跑);**TS 门禁口径** = `bun test` + 契约金标快照 + 壳快照测试 + 重写版 flagship e2e,428 断言按**行为对等**逐条映射(允许合并/淘汰只属 Swift 实现细节的断言),`check.sh` 保绿至⑤后退役;**MCP adapter 继续挂起不排期**(13 票已裁不进 V1,真实需求出现再立效fort)。
4. **收图检查**:13/13 票全部 resolved(01–13);雾区四条余项全部由本票裁决、清空;Out of scope 五条维持不变;**宣布 destination 到达**——锁定决定集 + 蓝图(07 票)+ ADR 批次指令 + 路线图修订口径 + 在飞处置齐备。交接:按 wayfinder 流程走 **/to-spec**(把全图决定收拢成可开工 spec)→ /to-tickets → /implement;实施不在本图。
