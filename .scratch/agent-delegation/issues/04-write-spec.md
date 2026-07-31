# 04: 产出《宿主调用本地 agent 适配层》spec

Status: resolved
Type: task
Blocked by: 01, 02, 03

## Question

综合图上全部决议(map.md「Decisions so far」)与 01/02 的实测事实、03 的工作区结构,走 /to-spec 产出 ready-for-agent 的 spec——这张票即本图的目的地。

要求:

1. 验收场景收敛为可判定的旗舰验收辞:a「查问题」诊断报告 + b「帮我改 mihomo 配置」(b 必须演示双层信任:普通改动零打断、踩 dangerous 弹宿主确认)。
2. Implementation Decisions 汇编建图期决议,不改变任何一条;01/02 实测推翻某决议时,先回图上修正决议再写 spec。
3. 测试决策沿用仓库三层 seam 价值观:AAAgentCore 纯逻辑打 Fake Port(swift-testing 主体)、试驾 CLI E2E 脚本、验证环标注 vfsoverlay 可验/需 Xcode。
4. Out of scope 继承 map 同名节。
5. spec 落 `.scratch/agent-delegation/spec.md`,随后拆实施票(拆票属于 spec 之后的动作,不在本票内)。

## Answer

图的目的地达成。spec 定稿于 [spec.md](../spec.md)(/to-spec 综合 14 决议 + 两 spike 实测 + 骨架摸底,无新面试)。随后 /to-tickets 拆出 7 张实施票 `impl/01–07`(tracer-bullet 垂直切片)。

spec 阶段两处收敛(执行既定「并行红线」,非新决策):①验收 b 用已跑通的 demo 能力(demo.note.set/demo.wipe)演示双层信任机制,不硬绑尚未落地的 mihomo 写能力(09/10 票);②测试走手写 TestReport 同构模式接 check.sh,禁止 import Testing,swift-testing 随 v1-core-proxy 11 票统一迁移。骨架摸底另确认:AAAgentCore 有自己的 AgentPort(样板 SystemProcessPort 反孤儿),不复用 AAPluginSDK.ProcessPort。

实施票依赖图:01 骨架(无阻塞)→ 02/03/04/06 并行(blocked by 01)→ 05(blocked by 01,04)→ 07 CLI 收口(blocked by 02,03,04,05,06)。
