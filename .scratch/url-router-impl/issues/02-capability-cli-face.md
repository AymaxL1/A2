# 02 capability/CLI 面 + contract golden

Status: claimed
Blocked by: 01

## Question

spec §3/§4:五条能力上注册表 —— `url-router.status`(safe)/`decide`(safe)/
`route`(normal)/`takeover`(dangerous)/`restore`(dangerous),域子命令
`a2 url-router …` 等价写法;输入输出 schema 落 `kernel/contract/schema` + golden 快照。

- route 的执行侧:探测(ps/lsof)、CDP(GET/PUT + AbortSignal.timeout)、
  Roxy API、`open -b`,按 02 研究票实测形状落地;URL 独立 argv。
- takeover/restore 本票只落**契约与幂等判据**(handler 已是目标 → `already:true`),
  执行编排(壳指令帧)归 04 票 —— 在此之前调用返回结构化「执行器未接线」错误。
- 幂等/错误码/`--dry-run`(= decide)/退出码对齐 docs/agents/a2-cli.md。

验收:capabilities list 可见五条(带 risk);contract golden 更新;bun test 绿。

## Comments

### 2026-09-04 施工完成(Opus 5 子代理),待 CR

分支 `feature/url-router-02-capability-cli`,三笔:

- `0140dcd` feat(kernel):执行侧(探测/CDP/Roxy API/三级降级)
- `4f670ae` chore(contract):六条 schema + 两个错误码 + 九个金标
- `3c9d306` feat(kernel):五条能力上注册表 + `a2 url-router` 域面

`bun test` **547 pass / 32 skip / 0 fail**(施工前 480 pass,**新增 67 条**);
`bun run typecheck` 干净;`bun run schema` 导出物已入库,金标漂移门禁绿。

新增源文件:`src/url-router/{execute,handler}.ts`、`src/capability/url-router.ts`、
`src/cli/url-router.ts`;改动:`contract/{wire,exit-codes,emit}.ts`、`cli/{main,usage}.ts`、
`daemon/runtime.ts`、`test/support/harness.ts`。

**CR 时值得看的口径**(按"最容易吵起来"排序):

1. **CLI 不是零手工接线,两处,都有理由**。① `main.ts` 放行 `url-router` 这个域 token
   (与 `proxy`/`arbitration` 同一行分派,泛型解析器本来就需要这一步);② spec §4 给的写法是
   `route <url> [--dry-run]` —— **位置参数**加一个**换能力而不是换参数**的旗标,与泛型解析器的
   `--名字 值` 不同形。于是加了 `cli/url-router.ts`:**一次纯 argv 改写**(幂等、有单测),
   改写后仍交 `domainCommand`,别名匹配/仲裁/渲染/退出码没有第二份实现。
   `--dry-run` 落到 `url-router.decide` 而不是 `route` 上的一个布尔:**风险档必须在 manifest 上
   分得开**(一条 safe 一条 normal),藏进参数里就没法分档了。
2. **`decide` 会真去探测**(ps/lsof/CDP GET),因为决策词 `roxy-cdp:<port>` 里那个端口只能探出来。
   只读,所以仍是 safe;且**域名没命中时一次外部程序都不调**(有断言)——热路径上省掉 ~40ms。
3. **`route` 的 result 多了 `steps`**(已脱敏)。母本 `log()` 写的那些话没地方去(spec §8
   不设独立 logPath),放进报文比另开一条日志通道诚实,而且"为什么每次都要多等两秒"这种事
   只有它答得出来。若认为不该进契约,删它只需改一处 schema + 一处 done()。
4. **`takeover`/`restore` 读不出 handler 时按「不是目标」处理**(fail-closed)。这是有意的:
   猜「大概已经是了」会让一次真正需要人点头的接管被静默跳过。代价是一台从没换过默认浏览器的机器上
   `status.handler` 恒为「未能判定」——LaunchServices 里本来就没有条目,05 票的悬空诊断会接手。
5. **母本没有的三处收紧**,都在代码里写了理由:`open`/`ps`/`lsof` 各 5s 上限;
   `roxyStartupAttempts`/`roxyAPITimeoutSeconds` 的**上限**钳制(母本只有下限——它是点一下就退的
   小程序,而这里是常驻内核,1e9 次重试等于这条能力再也不返回);API 重试的**末次不再白睡**。
6. **`defaults export` 的 plist 解析踩到一个真坑**:`LSHandlers` 条目里嵌着
   `LSHandlerPreferredVersions` 子字典,它**也**有个 `LSHandlerRoleAll`(值是 `-`)且排在前面。
   裸取首个匹配会把每台正常的 Mac 报成「默认浏览器是 `-`」——不报错、只一直答错。测试先红后绿。
7. **测试红线的落点**:`harness.ts` 默认把四个 `A2_URL_ROUTER_*` 指到一执行就失败的兜底假件
   (照 `FORBIDDEN_NETWORKSETUP` 的先例)。谁忘了注入行为假件,当场拿到非零退出——
   门禁永远不会在跑测试的人脸上弹出浏览器窗口,也永远不读真进程表。

**与 spec 的偏差:无**(§3 五条能力与风险档、§4 四条 CLI 写法、§5 「执行器未接线」、
§8 配置健康与 `roxyAPIKey` 纪律逐条对齐)。上面第 3、5 条是 spec 没规定、由施工判断补的,
不与 spec 冲突,列在这里供裁定。

**留给后续票**:`takeover`/`restore` 的真执行器与两次系统弹框(04);handler 悬空诊断与
`restore` 目标缺失前置校验(05);`a2 guide` 里要不要提这五条(本票未动 guide)。
