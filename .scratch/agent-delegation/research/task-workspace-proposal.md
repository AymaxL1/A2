# 任务工作区目录结构提案(03 票产物)

Status: 待用户过目
前置拍板(2026-07-29,已定):根目录 `~/.aa/agent-tasks/`;时间+slug+随机尾命名;V1 手动 prune;通知直开报告且报告主形态 = HTML。

## 树形总览

```
~/.aa/agent-tasks/                        # 根:AAContracts.AAPaths 单一来源
└── 20260729-1432-diagnose-network-x7f3/  # 目录名即 task-id:<YYYYMMDD-HHmm>-<slug>-<hex4>
    ├── meta.json          # 唯一元数据真相源(单写者 = 适配层)
    ├── prompt.md          # 委托原文快照:prompt + 全部委托参数(审计与重跑依据)
    ├── report.html        # 主产物,完成通知直接打开(见「HTML 报告怎么来」)
    ├── changes.md         # 有副作用任务(b 类)的变更清单;纯只读任务缺省
    ├── logs/
    │   ├── raw.ndjson         # agent 原始事件流,全量落盘,永不裁剪 —— 排障真相源
    │   ├── normalized.ndjson  # 归一化 6 型消息流 —— 状态判定与报告的唯一输入
    │   └── stderr.log         # 子进程 stderr 原样
    └── work/              # 缺省任务工作目录(agent cwd);委托指定外部 workdir 时不建
```

## 逐项设计决定

### 1. 命名与寻址

- **目录名 = task-id**,对外唯一标识:`aa agent status <task-id>` 直接收目录名,零查表。
- `<YYYYMMDD-HHmm>` 前缀让 `ls` 天然按时间排序;`<slug>` 从 prompt 首句生成(小写连字符,≤24 字符,空则 `task`);`<hex4>` 随机尾防同分钟撞名。

### 2. 文件清单与职责边界

| 文件 | 出现时机 | 职责 |
|---|---|---|
| `meta.json` | 创建即有 | 状态与结构化事实的唯一来源(下详) |
| `prompt.md` | 创建即有 | 委托原文 + 参数快照;人可读,重跑可复制 |
| `logs/raw.ndjson` | 启动即有,流式追加 | agent 原话,平台永不加工——排障回这里 |
| `logs/normalized.ndjson` | 流式生成 | 平台词汇(6 型消息,含 CallID);报告/状态只依赖它 |
| `logs/stderr.log` | 启动即有 | 子进程 stderr |
| `report.html` | 终态生成 | 主产物,通知直开 |
| `changes.md` | 有副作用任务终态 | 改了什么、为什么、怎么回滚 |
| `work/` | 缺省 workdir 时 | agent 的沙箱工作目录 |

**raw vs normalized 的红线**:raw 是「agent 说了什么」,normalized 是「平台听懂了什么」;一切下游(状态、报告、将来 GUI)只准消费 normalized,排障才碰 raw——两者永不互相回写。

### 3. meta.json(schema_version: 1)

```json
{
  "schema_version": 1,
  "task_id": "20260729-1432-diagnose-network-x7f3",
  "state": "running",
  "agent": "claude",
  "model": null,
  "workdir": "~/.aa/agent-tasks/20260729-1432-diagnose-network-x7f3/work",
  "initiator": "cli",
  "created_at": "…", "started_at": "…", "finished_at": null,
  "pid": 4242,
  "exit_code": null,
  "session_id": "…",
  "error": null
}
```

- `state` ∈ `pending / running / completed / failed / cancelled / timeout / orphaned`。
- `session_id` 拿到就写(学 multica「立刻落盘」,为将来 resume 留门)。
- `initiator` 预留 `cli/gui/plugin`(北极星第二步的插件委托直接续用)。

### 4. 生命周期与可维护性

- **崩溃残留判定**:`state=running` 且 `pid` 已死 → 下次任何 `aa agent` 读操作扫到即改标 `orphaned`,其余文件原样保留(证据不销毁)。
- **prune(手动,已拍板)**:`aa agent tasks prune --older-than 30d | --keep 100`;**只删终态目录,永不删 running**;`aa agent tasks list` 显示条数与磁盘占用,给用户清理信号。
- **演进规则**:`schema_version` 顶层递增;文件与字段**只增不改义**;读侧必须容忍未知字段/未知文件;旧任务目录永不迁移(读侧向后兼容)。读侧容忍之外,**写侧也必须把未知字段原样写回**——`meta.json` 的更新是读-改-写,写侧若把不认识的键剥掉,就等于旧版本单方面抹掉新版本刚写下的数据,那不是向后兼容。
- **状态值域的扩张不在「只增不改义」的兼容承诺内**:上面那条担保的是**字段**只增,并不担保 `state` 的**取值**只增。新增一个 `state` 取值时,旧版本读侧会把该任务按「不可读」处理(fail-loud:`aa agent list` / `prune` / 残留扫描一律**跳过而非猜**)。这是刻意的 fail-closed:猜成活态会导致重复拉起同一个任务,猜成终态则会让 prune 把证据删掉——两种猜法都比「读不出」更坏。故要加状态值,就得连同 `schema_version` 一起考虑,别当成一次普通的字段追加。

### 5. 三种消费姿态的落点

| 消费方 | 落点 |
|---|---|
| `aa agent status/list` | 只读 `meta.json` |
| 完成通知点开 | `open report.html` |
| 人肉盯过程 | `tail -f logs/raw.ndjson` |

### 6. HTML 报告怎么来(落实「报告用 HTML」拍板)

- **主路径**:委托 prompt 模板里约定 agent 直接产出**自包含** `report.html`(内联样式、无外链——现代 agent 写这个很稳)。
- **兜底**:终态检查发现没有 `report.html` 时,适配层把 agent 的最终文本消息 HTML-escape 后套一个极简内置模板生成之,并在页脚标注「由文本兜底生成」。
- **不做** md→HTML 渲染器(守 AAAgentCore 零依赖红线;兜底只是字符串拼接)。

## 待 01/02 spike 回填的两个小空位

- raw.ndjson 的确切行格式(两家原始事件是否天然逐行 JSON)——spike 样本定案。
- `session_id` 在两家事件流里的获取时机——决定 meta 里该字段的写入点。
