# 旧 Swift 断言 ↔ 新 TS 测试 对等映射表

**这张表是干什么的**:内核 bin 化是重写,不是移植。已验收的行为不能在重写里静默丢失,所以旧 Swift
(`Sources/` 逻辑 + `Tests/` 断言 + `Scripts/check/*.sh` 门禁)的每一条行为断言,要么在 TS 侧有对应测试,
要么在这里写明**为什么不要了**(合并进更强的断言 / 属 Swift 实现细节 / 顺延到哪张票)。

**怎么用**:每张重建票在完成时把自己覆盖的那部分登记进来(本表起于 04 票,由后续票追加,⑤票时应当收口)。
「处置」只有四种:`映射`(TS 有对应断言)、`合并`(被另一条更强的断言覆盖)、`淘汰`(只属旧实现细节)、
`顺延 <票号>`(行为还没建,归那张票)。

**记账口径**:旧仓的同一条行为常常在 swift-testing 与 shell 门禁里各有一个投影
(`Tests/AAHostTestKitTests/RegistryConformanceTests.swift` 文件头明写:shell 里 grep 的文案必须逐字是某个
`@Test` 的名字),两个投影算**一条**,不重复计数。

---

## 04 票登记:控制面(注册表 + capabilities list/describe/call + dangerous 默拒)

### A. `Tests/AAHostTestKitTests/RegistryConformanceTests.swift`(15 条)

| # | 旧断言(@Test 名节选) | 处置 | 新 TS 测试 |
|---|---|---|---|
| 1 | 默认注册表 list() 含三条 demo 能力且风险档正确 | 映射 | `cli-capabilities.test.ts` ▸ list --json:三档能力各一,顺序 = 登记顺序 |
| 2 | 注入的能力集被 list() 原样透传(含顺序) | 合并 | 同上(顺序断言);「假件 seam」本身淘汰 —— TS 侧注册表就是构造参数,不需要专门的注入 seam |
| 3 | describe:未知返回 nil;echo 交回可构造调用的 parameters | 映射 | ▸ describe --json:交回可据以构造调用的参数声明 / ▸ describe 未知能力:unknown_capability + 退出码 6 |
| 4 | invoke 校验层:未知能力 / 缺必填 / 类型不符 各自收敛到对的 code | 映射 | ▸ call 参数校验:缺必填 / 类型不符 / 取值不在 allowedValues 内 |
| 5 | invoke 执行层:safe 回显 / 业务失败 / normal 零 GUI 直执行 | 映射 | ▸ call safe / ▸ call normal:直通执行、零确认打断 / ▸ 业务失败 → capability_failed + 退出码 5 |
| 6 | 假 confirm=true 时 handler 恰执行一次 | 顺延 08 | 本票无确认通道(确认器是 08 票) |
| 7 | dangerous + 假 confirm=false → denied,handler 绝不执行 | 顺延 08 | 「用户点了拒绝」需要确认器在场,归 08(届时新增 `confirmation_denied`) |
| 8 | **confirm=nil 时 handler 绝不执行(fail-closed 保底)** | 映射 | ▸ call dangerous:无确认器 → confirmation_unavailable + 退出码 2,且 handler 一次都没执行 |
| 9 | dangerous 确认回调确实收到本次请求的 input | 顺延 08 | 同 6/7 |
| 10 | 延迟确认不占住调用请求:invoke 立即 pending + `capabilities.result` 查询 | 顺延 08 | `pending` 态与 `capabilities.result` op 本票不做(见下「有意的契约变更」6) |
| 11 | allowedValues 非法取值 → invalid_params(退出码 6) | 映射 | ▸ call 参数校验(第三段:scope=bogus) |
| 12 | allowedValues 合法取值放行执行 | 映射 | ▸ call 参数校验(第四段:scope=persistent) |
| 13 | 未声明 allowedValues 的参数不约束取值 | 合并 | ▸ call safe(message 取任意字符串照常执行) |
| 14 | 契约往返:RiskLevel 与 JSONValue 经 JSON 编解码稳定 | 映射 | `contract-golden.test.ts` ▸ 金标(合法)`capability-descriptor.json` / `capability-call-result.json` 等(解析后逐字段等于磁盘原文) |
| 15 | 退出码映射:每个 error.code 逐码映射正确 | 合并 | CLI 缝上直接断言**真实退出码**(0/1/2/4/5/6 各有活体样本),比断言映射函数更强;未登记码归 6 见 B 组 |

### B. `Tests/AAContractsTests/ExitCodeContractTests.swift`(6 条)

| 旧断言 | 处置 | 新 TS 测试 |
|---|---|---|
| 0–6 七个码的数值被钉死 | 合并 | 数值仍钉在 `src/contract/exit-codes.ts`;CLI 缝断言的是真实退出码(见 A15)。**3(超时)本版无产出面**,见「有意的契约变更」8 |
| semantics 恰好覆盖 0…6 且顺序连续 | 淘汰 | 旧断言守的是「帮助表由 semantics 生成」这条实现细节;TS 侧帮助是手写文本,退出码表只出现一次(`usage.ts`) |
| capability_failed → 5 | 映射 | `cli-capabilities.test.ts` ▸ 业务失败 → 退出码 5 |
| denied → 2 | 映射 | ▸ call dangerous → 退出码 2(码名换成 `confirmation_unavailable`,见「有意的契约变更」2) |
| 协议/校验层 8 码 → 6 | 映射 | ▸ call 参数校验(三码)/ ▸ describe 未知能力(unknown_capability) |
| 未登记的错误码保守归 6,绝不吞成成功 | 映射 | `cli-basics.test.ts` ▸ 退出码契约:未登记的 error.code 保守归 6 |

### C. `Scripts/check/capabilities-e2e.sh`(E2E 门禁)

| 旧断言 | 处置 | 新 TS 测试 |
|---|---|---|
| 2a / 2a2 宿主未运行 → 退出码 4 + `host_unreachable` + 结构化报文 | 映射 | ▸ daemon 未运行:能力面同样是 daemon_unreachable + 退出码 4(码名 `host_unreachable` → `daemon_unreachable`) |
| 2c list --json 含 id / risk / 参数 | 映射 | ▸ list --json(`schemaSummary` 键的断言淘汰,见「有意的契约变更」5) |
| 2d describe --json 含 parameters/name/type/required | 映射 | ▸ describe --json |
| 2e / 2f call demo.echo / demo.note.set 退出码 0 | 映射 | ▸ call safe / ▸ call normal |
| 2g / 2h / 2i missing_parameter / type_mismatch / unknown_capability 退出码 6 | 映射 | ▸ call 参数校验 / ▸ describe 未知能力 |
| 2j `message=boom` → capability_failed 退出码 5 | 映射 | ▸ 业务失败 |
| 2k `--input 'not-json'` → 退出码 1 且提示"合法 JSON" | 映射 | ▸ 用法错一律退出码 1(用例含 `--input not-json`,报文 message 含「不是合法 JSON」) |
| 2k2 call 缺 id → 退出码 1 | 映射 | ▸ 用法错(用例 `capabilities call`) |
| 2L / 2L2 / 2L2b–d / 2L3 / 2L4 域子命令(`aa demo echo --message hi`)与 call 同底座 | 顺延 05/07 | 域子命令面(`cliAlias` 解析、按声明类型强转 argv)本票不做 |
| 2M 未知**域子命令** → `unknown_command` 退出码 1(对照 2i 的 6) | 映射 | ▸ 用法错(未知动作 → `usage` 码 + 退出码 1)与 ▸ describe 未知能力(6)两条一起守住这个区分 |
| D1 / D1b `AA_CONFIRM_AUTO=deny` → 退出码 2 + 无 `wiped` | 顺延 08 | 「用户点拒绝」需确认器;本票守的是**无确认器**那条(A8) |
| D2 `AA_CONFIRM_AUTO=approve` → 退出码 0 + `wiped:true` | 顺延 08 | 同上 |
| **D3 裸 UDS 直连仍被拒、响应绝不含 `wiped`** | 映射 | ▸ 裸 UDS 直连绕开 CLI:dangerous 仍然默拒(拒因从"未确认"变成"无确认器",绕不过仲裁这一点不变) |
| 2'' 假监听器不回应 + `AA_TIMEOUT_SECONDS=1` → 退出码 3 | 顺延 08 | 见「有意的契约变更」8 |
| `aa --help` 打全 7 条退出码语义 | 合并 | `usage.ts` 的 USAGE 里仍有整行退出码表;`cli-basics.test.ts` ▸ help --json 断言帮助可机读 |
| `aa docs agents-md` 含 capabilities/dangerous/exit code | 顺延 13 | agent 指引物随分发工件走 |

### D. 本票未触及(留给相邻票,列此免得漏账)

- `Tests/AAHostTestKitTests/ProxyConformanceTests.swift`(12 条代理能力的暴露与风险档、timeout 防呆)→ **顺延 07**。
- `Tests/AAHostTestKitTests/SubscriptionConformanceTests.swift`(订阅四条能力、dangerous 的 `proxy.subscription.add`)→ **顺延 06/07**。
- `Scripts/check/proxy-e2e.sh` / `subscriptions-e2e.sh` 的能力元数据断言 → 随上面两条一起顺延。

---

## 有意的契约变更(不是丢失,是改判 —— 逐条有出处)

1. **`--json` 输出一律是包封**。旧 `aa` 的 list/describe/call 直接打裸 payload(`{"capabilities":[…]}`、
   裸 descriptor、裸 output),失败时才打信封;新内核成功失败**同一形状**,agent 一次 `JSON.parse` 就能分支
   (ADR 0008 第 2 条)。代价:旧的 `assert_contains '"id":"demo.echo"'` 这类 grep 仍成立,但取值路径多一层 `result.`。
2. **`denied` 拆成两码**。旧实现里「无确认通道」与「用户点了拒绝」共用 `denied`,只靠 detail 文案区分。
   新内核按 ADR 0005 修订后的三层仲裁分开:本票只产 `confirmation_unavailable`(第①层),
   08 票补 `confirmation_denied` / `confirmation_timeout`(第③层)。**退出码都是 2**,旧的退出码断言不受影响。
3. **`WireError` 加 `message`(必填)与 `guidance`(可选)**。旧只有 `{code, detail}`,没有任何机器可读的
   「人类如何完成」;「拒绝即指引」(ADR 0005 第 4 条第②层)要求拒绝自带精确命令,故加字段。
4. **参数类型词汇 `bool` → `boolean`**。旧 Swift 用 `bool`;新契约取 JSON Schema 的词,少一层翻译
   (这张词表要同时喂 agent 和 11 票的插件 describe 输出)。旧断言只 grep 过 `"type":"string"`,不受影响。
5. **`schemaSummary` 与 `cliAlias` 淘汰**。前者是可由 `parameters` 派生的展示串,不进契约(旧 E2E 只断言过
   这个键存在);后者属域子命令面(`aa proxy on`),随该面一起顺延 05/07,届时如仍需要再进 manifest。
6. **`pending` / `requestID` / `capabilities.result` op 不进本票**。旧实现的异步确认态是为 GUI 模态框设计的;
   新架构的确认器协议归 08 票,届时按「可选字段追加不算不兼容」加。顺带解掉旧的一处名字不一致
   (线协议 `requestID` vs CLI 输出 `requestId`)——新契约里只会有一个拼法。
7. **重复能力 id 从"静默后者覆盖前者"改为"启动即抛"**。旧 `Registry.init` 的字典覆盖是已记账的债;
   能力 id 是 agent 的调用坐标,重名必须在启动时炸,而不是在调用时给出一个"看起来成了"的结果。
8. **超时退出码 3 目前无产出面**。旧 `aa` 有 `AA_TIMEOUT_SECONDS` + `SO_RCVTIMEO` → 退出码 3;
   新客户端把"等不到响应"一律归为 daemon 不可达(退出码 4)——对调用方是同一件事:这条路走不通。
   08 票改长连接时会重新出现真正的「确认超时」语义,那时再决定 3 的归属。
