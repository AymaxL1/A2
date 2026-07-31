# 03: 任务工作区目录结构设计

Status: resolved
Type: prototype
Blocked by: (无)

## Question

每次委托一个任务工作区目录(暂定 `~/.aa/agent-tasks/<task-id>/`),内部结构长什么样?用户明确要求「好好设计,一定要考虑可维护性」——这张票产出一个具体结构提案(prototype)供用户过目拍板。

要覆盖的内容(建图期已定的素材):`report.md` 主产物、原始 NDJSON 全量日志(排障真相源)、归一化消息流、任务元数据(状态/agent/model/session-id/时间/退出码)、b 类任务的改动说明(diff/变更清单)。

设计必须回答:

1. **命名与寻址**:task-id 生成规则(时间序?可读前缀?);目录名可读性 vs 唯一性。
2. **文件清单与各自职责**:哪些文件必有、哪些按任务类型出现;raw 与 normalized 的边界;元数据是单 `meta.json` 还是分散。
3. **生命周期与可维护性**:任务堆积怎么办(清理策略/上限/归档);运行中 vs 终态的目录状态如何区分;崩溃残留(拿到一半的任务)长什么样、如何判定与回收。
4. **演进余地**:将来加字段/加文件不破坏已存在的任务目录(版本标记?约定优于 schema?)。
5. **消费方**:`aa` 状态查询、完成通知跳转、人肉 tail 日志三种消费姿态在这个结构上分别怎么走。

软依赖:01/02 的原始事件样本能让 raw 日志部分更实(不强阻塞,可并行)。产物:结构提案文档(树形示例 + 每文件职责)链入本票,HITL 过目后回写 `## Answer`。

## Comments

**2026-07-29 用户拍板(批量面试追加轮)**,提案必须遵守:

1. 根目录 = `~/.aa/agent-tasks/`(进 `AAContracts.AAPaths` 单一来源)。
2. 目录命名 = 时间前缀 + 可读 slug + 短随机尾(如 `20260729-1432-diagnose-network-x7f3`)。
3. 清理 = V1 不自动删;`aa agent tasks prune` 手动(按龄/按量),状态查询显示条数与磁盘占用;自动清理进 fog。
4. 完成通知直接打开报告,**报告主形态 = HTML**(用户原话:可读性更高)——提案需回答 HTML 报告怎么产出(agent 直写 vs 适配层渲染)与未产出时的兜底。

## Answer

结构提案定稿于 [research/task-workspace-proposal.md](../research/task-workspace-proposal.md),2026-07-29 用户过目通过(原话「03 提案 agree」)。要点:

- 根 `~/.aa/agent-tasks/`,**目录名即 task-id**(`<YYYYMMDD-HHmm>-<slug>-<hex4>`),`aa` 命令直接收目录名零查表。
- 每任务固定布局:`meta.json`(状态唯一真相源,单写者=适配层,schema_version 演进)+ `prompt.md`(委托快照)+ `report.html`(主产物,通知直开)+ `changes.md`(有副作用任务)+ `logs/{raw.ndjson, normalized.ndjson, stderr.log}` + 缺省 `work/`。
- 红线:**raw 与 normalized 永不互相回写**;下游只消费 normalized,排障才碰 raw。
- 崩溃残留:`running` 且 pid 死 → 读操作扫到改标 `orphaned`,证据不销毁;prune 只删终态。
- HTML 报告:主路径 = prompt 约定 agent 直写自包含 HTML;兜底 = 最终文本 escape 套极简内置模板;不做 md 渲染器。
- 两个小空位(raw 行格式、session_id 获取时机)由 01/02 spike 回填,不影响结构定稿。
