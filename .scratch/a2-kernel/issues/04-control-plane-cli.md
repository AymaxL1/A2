# 04 — 控制面重建:注册表等价物 + CLI 子命令面

**What to build:** 蓝图第②步(服务安装拆去 05 票)。TS 内核长出控制面:能力注册表等价物(manifest、风险三档标注)+ agent-first CLI 子命令面——`a2 capabilities list|describe|call --json` 全链路可用,结构化输出与退出码语义稳定,dangerous 调用此时一律走默拒(仲裁三层在 08 票补齐,本票先立 fail-closed 地基)。以旧 Swift 控制面与其断言为行为规范参考逐条映射。

**Blocked by:** 03(契约骨架)。

**Status:** done — 83bc689 控制面立起(注册表 + 三条 CLI + dangerous 默拒),bun test 59/59、tsc 干净、check.sh PASS=429 FAIL=0;Swift 对等映射表建账 37 条 + 8 条契约变更

- [x] 注册表等价物承载能力清单与 manifest(id、参数 schema、风险档),`a2 capabilities list|describe <id> --json` 输出机读结果
  - `kernel/src/capability/registry.ts`:`CapabilityRegistry` 持 manifest + handler,`list()`(顺序 = 登记顺序)/ `describe(id)` / `invoke()`。参数声明是**纯数据**(`ParameterSpec{name,type,required,description,allowedValues?}`),不是 zod 对象——11 票的插件只能用 JSON 描述自己,内置能力与插件必须同一套。
  - `kernel/src/capability/builtin.ts`:风险三档各一个自检样本(`demo.echo` safe / `demo.note.set` normal / `demo.wipe` dangerous),沿用旧 Swift 同名能力与行为;三条全是纯数据回显,不碰文件/网络/系统状态。
  - 契约进 `wire.ts` 并导出 JSON Schema:`CapabilityDescriptor` / `CapabilityListResult` / `CapabilityDescribeResult` / `CapabilityCallResult`(`bun run schema` 共 11 份)。
  - 重复能力 id 从旧实现的「静默后者覆盖前者」改为**启动即抛**(`DuplicateCapabilityError`,有断言)。
- [x] `a2 capabilities call <id> --json` 打通调用闭环:成功返回结构化结果,失败返回结构化错误,退出码语义固定并写进契约
  - 成功:`{"ok":true,"result":{"capability":"demo.echo","output":{...}}}`,exit 0;`--input '<JSON 对象>'` 传参,不带等价于 `{}`。
  - 退出码(`src/contract/exit-codes.ts`,值即契约):**0** 成功 / **2** dangerous 被拒 / **4** daemon 不可达 / **5** 能力业务失败(`capability_failed`)/ **6** 能力或参数不合契约(`unknown_capability`/`missing_parameter`/`type_mismatch`/`invalid_params`)/ **1** 用法错。六个值全有活体断言;3(超时)本版无产出面,已记账。
  - 参数出错的报文带「去看这条能力的 manifest」的精确命令(`a2 capabilities describe <id> --json`)+ `context.parameter`,agent 可自纠。
- [x] dangerous 档能力被 call 时返回 `confirmation_unavailable` 类结构化默拒(fail-closed 起点),永不 TTY 交互、无 `--yes`
  - `confirmation_unavailable` + exit 2;**handler 一次都不会被碰到**(反证断言:整条 stdout 里不出现 handler 产物 `wiped`)。
  - `--yes` 不是"被忽略"而是**根本不存在**:未知选项当场用法错(exit 1),有断言;拒绝是立即返回,不等待、不超时猜谜(有耗时断言)。
  - **仲裁在内核里,不在客户端里**:裸 UDS 直连(绕开 CLI)调 `demo.wipe` 同样被拒,有断言。
  - 留给 08 的缝:`runtime.confirmerPresent()`(本票恒 false)。仲裁那一侧问的一直是同一个问题,08 只需换答案来源。
- [x] 拒绝即指引报文形态落地:拒绝中携带机器可读的「人类如何完成」精确命令字段
  - 默拒报文 `guidance = {summary, steps[{description, command?}], context{capability,risk,home,socketPath}}`;金标样本 `contract/golden/response-confirmation-unavailable.json` 把这个形状钉住(08 票补确认器时**本形状不变**)。
  - 同一形态也覆盖了 `unknown_capability`(→ `a2 capabilities list --json`)与参数三码(→ `a2 capabilities describe <id> --json`)。
- [x] 旧 Swift 控制面对应断言完成行为对等映射入 `bun test`(合并/淘汰的实现细节断言留清单记录);`check.sh` 保绿
  - `kernel/test/swift-parity-map.md` 立表(**由后续票追加,⑤票收口**):RegistryConformanceTests 15 条 + ExitCodeContractTests 6 条 + capabilities-e2e.sh 16 组 = **37 条**,逐条标 映射/合并/淘汰/顺延;另列 8 条**有意的契约变更**(包封化、`denied` 拆成 `confirmation_unavailable`、`WireError` 加 message/guidance、`bool`→`boolean`、`schemaSummary`/`cliAlias` 淘汰、pending 态顺延 08、重复 id 改为启动即抛、超时码 3 暂无产出面),每条给出处。
  - `bun test` **59 pass / 0 fail**(源码入口与 `A2_TEST_BIN=dist/a2` 编译产物两种被测体跑同一批);`bun x tsc --noEmit` 干净;`bash Scripts/check.sh` → **PASS=429 FAIL=0**(日志 `/tmp/a2-check-04.log`,Swift 侧一行未动)。
