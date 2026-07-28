# 04: 产出《宿主调用本地 agent 适配层》spec

Status: claimed
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
