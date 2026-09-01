# 11 — 插件宿主:exec describe/call + 零依赖插件 + `a2 plugin add`

**What to build:** 蓝图第⑥步的宿主主体,插件北极星「agent 现场写插件」落地:agent 现场写一个零依赖单文件 `.ts`,`a2 plugin add <path>` 零闸即时登记生效(审计事件推送确认器/入日志),内核经 `BUN_BE_BUN` 拉起插件子进程——`plugin describe` 读工具清单+schema+dangerous 声明,`plugin call <tool>` stdin JSON 进、stdout JSON 出、退出码即成败;插件工具经内核统一暴露给 CLI,dangerous 声明的工具被调用时走三层仲裁。

**Blocked by:** 02(BUN_BE_BUN spike)、08(仲裁与协议)、10(蓝图切步序:⑥在⑤后)。

**Status:** done — 5896ffe(10 票 CR 尾款·文字账)+ c64c583(11 主体,含尾款 a 的门禁守卫)+ 28a54c3(收口)

- [x] describe 约定落契约:插件被 `describe` 调用时输出工具清单、参数 JSON Schema、dangerous 声明;非法输出得到结构化错误与指引
- [x] call 约定打通:参数 stdin JSON 进、结果 stdout JSON 出、退出码语义固定;超时与非零退出映射为结构化错误
- [x] `a2 plugin add <path>` 对零依赖单文件 `.ts` 即时生效:登记入 registry、产出审计事件(推送订阅者/入日志)、无任何确认闸;`a2 plugin list` 机读可见
- [x] 插件工具经内核统一调用面暴露;dangerous 声明的工具被调用时走 05 票三层仲裁(无确认器默拒+指引,有确认器带外确认),safe/normal 直通
- [x] 端到端验收:现场写的示例插件 add 后被 agent 经 CLI 全链路调用成功;插件为进程外子进程、能力只经协议白名单(红线等价物),V1 无事件面/常驻态记为已知限制

## 逐框证据

**框 1(describe 约定)**:`kernel/src/plugin/protocol.ts` 的 `describePlugin()`。契约进 `wire.ts`:`PluginDescribeResultSchema`(`{protocol:1, name?, tools[]}`)+ `PluginToolSpecSchema`(`{name, summary, dangerous, parameters: ParameterSpec[]}`)——**参数用的就是内置能力那套 `ParameterSpec` 纯数据形**(04 票为此有意不把 zod 塞进 manifest),所以插件工具与内置能力在 `a2 capabilities list` 里长得一模一样。非法输出四条路径各有结构化错误 + 指引(坏 JSON / 缺字段 / 非零退出 / 超时),断言见 `cli-plugin.test.ts` 三条 describe 用例;**失败即清场**(登记区连暂存文件都不留,有断言)。

**框 2(call 约定)**:`callPluginTool()`。stdin 一行 `{"tool","input"}`、stdout 一行 `{"ok":true,"output"}`;**退出码词表封闭**(`PluginExit`:0 成功 / 2 报文读不懂 / 3 业务失败 / 4 未知工具 / 其余没跑成),映射见 `exit-codes.ts`:`capability_failed`→5(与内置能力业务失败同档)、`plugin_protocol_error`→6、`plugin_failed`/`plugin_timeout`/`plugin_load_failed`→5。**超时不归退出码 3**——3 的语义是「人没点」(08 票裁的唯一产出面),插件卡住与人没点是两件事,合流会让 agent 的「重试还是别重试」变糊(取舍写在 `exit-codes.ts` 里)。stderr 不污染 stdout 有断言。

**框 3(零闸装载)**:`kernel/src/plugin/host.ts` 的 `addPlugin()` + 三条 op(`plugin.add|list|remove`)+ `a2 plugin` 子命令面。**装载零闸有正面对照断言**:同一时刻同一台内核上,`demo.wipe`(dangerous)被默拒(退出码 2)而 `plugin add` 退出码 0。留痕两条腿:`AuditAction` 新增 `plugin_added` / `plugin_removed`(封闭词表 + 金标 + Swift 对账),既落 NDJSON 也推给在场长连接;能力全集变化推**新的第七族事件** `capability-set`。

**框 4(统一暴露 + 调用层仲裁)**:插件工具就是 `Capability`,经 `registry.register()` 进**同一张注册表**——于是三层仲裁、参数校验、事件广播**一行都不必为插件重写**(dangerous 声明 → `risk: "dangerous"` → `registry.invoke` 自动走 08 票那条路)。两分支都有活体断言:无确认器 → `confirmation_unavailable` + 退出码 2 + 指引 + **插件一次都没被拉起**(反证);有确认器(fake-client / 壳的真代码路径)→ 批准后照常执行,确认器收到的是**逐字原样的 input**。

**框 5(e2e + 红线)**:`Scripts/a2-plugin-e2e.sh` 五幕 **34 条**,进门禁第④步。脚本自己**就是那个 agent**:heredoc 现场写一个零依赖单文件 `.ts` → `a2 plugin add` → 经 CLI 全链调通 → dangerous 两分支 → 卸载 → 留痕。红线三条:插件 pid ≠ 内核 pid(**进程外**)、插件环境里一个 `A2_*` 都没有(**能力只经协议白名单**)、`--no-install` 恒带(fail-closed,不联网现装)。**V1 无事件面/常驻态**照 spec 记为已知限制,写在 `a2 plugin --help` 的「边界」一节里(agent 读得到)。

## 契约形状(新增)

| 契约 | 形状 | 面 |
|---|---|---|
| `PluginDescribeResult` | `{protocol:1, name?, tools:[PluginToolSpec]}`(tools 至少一条) | 内核 ← 插件 |
| `PluginToolSpec` | `{name, summary, dangerous, parameters:[ParameterSpec]}` | 内核 ← 插件 |
| `PluginCallRequest` | `{tool, input:{...}}` | 内核 → 插件(stdin) |
| `PluginCallOutput` | `{ok:true,output}` \| `{ok:false,error:{message,detail?}}` | 内核 ← 插件(stdout) |
| `PluginRecord` | `{name, artifact, source, addedAt, tools, capabilities}` | `a2 plugin list` |
| `PluginListResult` / `PluginChangeResult` | `{directory,plugins}` / `{action,plugin,added,removed}` | CLI 机读 |
| `CapabilitySetEvent` | `{action,plugin,added,removed,capabilities}`(**带变化后的全集**) | 推送第七族 |

- **id 命名空间**:`plugin.<插件名>.<工具名>`,名字与工具名取值域 `[a-z0-9][a-z0-9_-]*`。内置能力无一以 `plugin.` 开头(有断言),所以插件**永远撞不掉**内置能力;两个插件可以有同名工具。
- **热更新语义**:add = 复制工件进 `<A2_HOME>/plugins/` → 对**暂存工件**describe(与将来被调用时同一个 cwd/环境)→ 通过才就位 → 注册表**全或无**热更新 → 落清单 → 留痕 + 推增量。同名再 add = **替换**(旧能力注销、新能力上岗,`action: "replaced"`)。启动时从清单**还原**(不重新 describe:登记的是 add 那一刻的快照)。清单坏了**拒绝读写**(照 07 票订阅清单那条),daemon 照常启动但一个插件都不装,stderr 留一行。

## 10 票 CR 尾款处置(五项,全做)

| # | 事项 | 处置 |
|---|---|---|
| a | 门禁③步陈旧产物隐患 | **修了**:`check.sh` 新增「②b 内核产物新鲜度守卫」——`kernel/dist/a2` 比 `kernel/src`/`package.json`/`bun.lock` 里任何一个文件旧(或不存在)就**当场 `bun build --compile` 重建**,再往下跑 e2e。选「陈旧才重建」而不是「恒重建」:重建十几秒、不是 100ms(那是不带 `--compile` 的 bundle),新鲜时不该白花。**本次首跑就命中了**:产物确实是旧的(日志里列出了比它新的五个文件),重建后 ③④ 两步验的才是当前这版内核 |
| b | 票面字面订正 | **做了**:10 票框 4 加勾选注记(实为 `build-app.sh` 出包,`XcodeGen` 无消费者);框 6 与 `docs/v1-roadmap.md` 判据 6 的「`check.sh` 退役」改为「**旧引擎退役、入口与接口保留**」,两处都注明是字面订正、判据实质未变 |
| c | 对等映射表 A 组「21 条」口径 | **注明了**:21 数的是 `assert_*` 调用点;另有 **8 处内联 `echo PASS/FAIL` 判定分支**(反孤儿探针那两段)没被计入,**断言点合计 29**。顺延的是整族行为规范,不因数字口径而变 |
| d | GUI 未测带记录补宽 | **补了**(10 票文件偏差 4 + 本 nightlog):`actionTapped → session.call` 的接线本身、以及菜单发起 `proxy.subscription.add` 时的**参数收集**(弹框/取值/拼 input)同样在未测带——探针走的是投影与确认那半边,不点菜单项、不收参数 |
| e | 真 mihomo 那条缺口的候选补法 | **只记文字、未实现**(10 票文件偏差 5 + roadmap 人工项节):`A2_REAL_MIHOMO_BIN=<路径>` 时旗舰 e2e 加一幕真核(config 接受 + 三条 REST 对照),并把人工实测真回包收进金标钉住假件。**需用户裁定**——本机跑着用户自己的 mihomo,那是施工红线 |

## 门禁与测试

- `cd kernel && bun test` → **300 pass / 0 fail**(263 → 300:插件用例 25 条 + 金标样本 12 份)
- `bun x tsc --noEmit` → 干净
- `swift build` → 零 warning;`swift test` → **101 passed**(99 → 101:词表对账 1 条 + 投影 1 条)
- `bash Scripts/check.sh` → **步 PASS=8 FAIL=0**(①300 / ②101 / ③46 / ④**34**(新)/ ⑤ .app 出包),全程 99 秒
- 插件 e2e 在门禁里跑的是**编译产物**(`kernel/dist/a2`,60MiB):即 02 票 spike 那条「产物自举拉起外部 `.ts`」的真路径,不是源码模式的近似

## 偏差 / 做不到项(如实)

1. **门禁从「四件套」变成「五件套」**:插件 e2e 是新的一步(④),`.app` 出包顺延为 ⑤。`check.sh` 的**接口**(一条命令、非零退出、清楚 PASS/FAIL、入口路径)逐字未变。
2. **没有 `a2 plugin call`**:插件工具经 `a2 capabilities call plugin.<名>.<工具>` 调用(ADR 0004 唯一调用面)。多一条平行调用面就多一处仲裁可能被绕过的地方,所以不做——`a2 plugin --help` 里显式写了这一点。
3. **没声明 dangerous 的工具登记为 `normal` 而不是 `safe`**:内核无从知道插件工具是不是只读。代价是每次调用都会广播一条 `capability` 事件(safe 不广播);收益是「写被当成读」这种错永远不会发生。
4. **插件环境白名单不给 `HOME`**:给了就等于把 `~/.a2`(socket 默认落点)直接递给插件。代价是插件读不到 `~/.bunfig.toml` 之类的用户级配置——对零依赖单文件形态无影响。**这不是沙箱**:同 UID 下插件仍可自己去猜路径,ADR 0011 的威胁模型对此是诚实的;白名单守的是「内核不主动递」。
5. **启动还原不重新 describe**:工件在我们自己的登记区、只有 add 会动它。重新问一遍既不会更真,又让启动时间随插件数线性增长。代价:有人手改登记区里的工件时,清单与实际会漂到下一次 `a2 plugin add`。
6. **V1 无事件面 / 无常驻态**(ADR 0011 已知限制,不是本票遗漏):插件不能主动推事件、不能跨调用保内存状态。已写进 `a2 plugin --help` 的边界一节。
7. **目录插件(带依赖)不收**:结构化拒绝 + 指引明说那是 12 票。
8. **未联网;未 launchctl 任何真 unit;未删 CLT;用户 mihomo(33888)全程未碰**——插件 e2e 压根不装、不起任何 mihomo,mihomo 扫描面全部指向空的沙盒目录。
