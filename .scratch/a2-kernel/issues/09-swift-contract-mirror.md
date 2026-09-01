# 09 — Swift 契约对照层:手写 Codable + 金标快照双端门禁

**What to build:** 壳原子切换的 expand 前置(不切换、不动现有壳行为)。Swift 侧长出与 TS 契约对照的手写 Codable 报文层与 UDS 客户端基础(连接、角色注册、快照+增量接收、确认请求-响应),TS 与 Swift 双端对同一批金标报文样本做编解码快照测试并双双入门禁——契约漂移从此在门禁层报警。不引入代码生成链。

**Blocked by:** 08(协议面定型)。

**Status:** done — b038cca(主体)+ 0f02f2e(CR 修复:镜像松紧照抄契约、并行时序去 flake、对账盲区补第五层)

- [x] 协议报文族(包封/错误/拒绝指引/角色注册/快照/增量/确认请求-响应)在 Swift 侧有手写 Codable 对照
  - 新 target `A2Contract`(与 AA* 全族**零依赖边**)。镜像 18 个已登记契约 + 其全部嵌套类型;范围以**壳(10 票)消费得到的**为界。
  - **有意不镜像 20 条**(各能力自己的 result:proxy.\* / service.\* / mihomo.\* / CLI 查询面),逐条写了理由(`A2UnmirroredContract.reason`)——能力 `output` 是任意 JSON,由 `A2JSON` 承载,不为每条能力建一个会漂的 struct。
  - `RoleRegisterResult` 镜像了但**金标里没有样本**(08 票没造),显式记账在 `A2ContractCoverage.mirroredWithoutGoldenSample`,覆盖来自活体烟测;哪天补了样本,对账断言会红提醒删记账。
- [x] 金标报文样本为双端共享事实源:TS 侧 `bun test`、Swift 侧 swift-testing 各自对全部样本编解码快照,任何一侧改契约即门禁红
  - Swift 侧读的是**同一批文件**(`kernel/contract/golden/`,路径由 `#filePath` 推仓库根,**不经环境变量** —— check.sh 一行不改是本票硬约束)。
  - 合法样本 36 份:解得动 + **往返后逐字段语义等价**;非法样本 11 份:必须解不动。
  - **对账机制**(防「新契约/新样本 Swift 没跟」):全集取**已登记契约**(每份 JSON Schema 的 title = `CONTRACT_SCHEMAS` 一条,**不是**金标清单 —— 后者只列有样本的,CR 抓到那是盲区),断言 ≡ 已镜像 ∪ 有意不镜像;已登记但无样本的必须显式记账并写理由(现存两条,均为嵌套类型)。
  - **封闭词表对账**(金标盖不到的那一格):读 `contract/schema/*.schema.json` 的 enum/const 与 Swift enum 逐字比 —— 枚举**多**一个取值不会让任何旧样本失效,只有这条抓得住。
  - **松紧对账**(CR 追加):契约没写 `min(1)` 的地方空串必须收得下、写了的必须被拒,**两个方向都验** —— 镜像比契约严同样是漂移(会把合法帧整帧丢掉)。
- [x] Swift UDS 客户端基础可对运行中 TS 内核完成:连接、注册 subscriber 收快照与增量、注册 confirm-agent 收确认请求并回传响应(集成冒烟即可,UI 不接)
  - 新 target `A2KernelClient`:连接、NDJSON **字节级**拆行、请求-响应按 id 相关、推送分流入队、`confirmation-pending` 按内核承诺的窗口顺延截止时间、`roles.register` / `confirmations.resolve`。
  - 活体烟测 `Scripts/a2-smoke-09.sh`(**不在 Scripts/check/ 下,门禁不引用**):临时 A2_HOME 起真 daemon → 注册 confirm-agent 拿全量快照(uid=501 真校验、21 条能力)→ 触发真 dangerous → 收 confirmation 推送 → approve / deny 两条链各一遍(发起方分别拿到 exit 0 与 exit 2 + 指引),4/4 全绿;编译产物与 bun 源码入口两种被测体各跑一遍。
- [x] 现有壳、`check.sh`、既有快照测试全部不动、保绿(本票纯 expand)
  - `bash Scripts/check.sh` → **PASS=429 FAIL=0**(与开工前逐条相同;`swift test` 182 → **238** 条,用例数棘轮 ≥182 满足,构建零 warning)。日志 `/tmp/a2-check-09.log`(主体)、`/tmp/a2-check-09cr.log`(CR 后)。
  - 门禁把 `swift test` 记作**一条**断言(不按用例数展开),故新增 56 条用例**不改变 PASS 总数** —— 这是脚本既有设计,不是我调过口径。

## CR 修复(0f02f2e,7 项全做完)

1. **硬违反·镜像比 TS 严**:8 处纯 `z.string().optional()` 被收严成"非空可选"(合法的 `detail:""` 会被整帧丢弃),全部放回;反向那处(`cliAlias` 元素级 `min(1)`)补上。`A2Decoding` 头注立铁律 + 新增 10 条两向断言。
2. **并行 flake**:假内核改用**专用 Thread**、时序断言按判据差给余量;默认并行连跑 3 遍 56/56 绿。
3. **对账盲区**:金标补 `role-register-result.json`(`bun test` 262 → 263/0),Swift 侧人工记账销掉;全集改取**已登记契约**并加三条断言。
4. `FakeKernel` 改为**真独立**(只用 Foundation,不 import 任何被测代码),头注随之成为真话。
5. `A2JSON` 超 `Int64` 落 Double —— 头注记为已知边界(附为什么现在不管)。
6. `A2KernelClient` 超时后连接实质报废 —— 头注写明语义与「超时即重连」的使用要求(10 票依赖)。
7. 豁免界措辞校准为「消费但不建 typed struct」,三条代理面理由改成实话 + 10 票挪表预告。
