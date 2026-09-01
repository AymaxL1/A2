# 07 — 代理控制面行为对等:配置、模式/节点/订阅、显式还原、存活监督

**What to build:** 蓝图第③步的监督半边 + 代理域命令行为对等。旧 Swift 侧已验收的代理能力在 TS 内核重生:配置管理与 reload、模式切换、节点选择与列表、订阅管理、系统代理接管;「退出即还原」废除后,系统代理还原成为**内核显式命令**。存活探测持续供状态面;内核重启/升级期间 mihomo 照跑(数据面不随控制面起落)。以 428 断言中代理域子集为行为规范逐条映射。

**Blocked by:** 06(mihomo 共存阶梯)。

**Status:** done — 323dbae(07 主体)+ cb3a4bf(06 票 CR 尾款)+ 44a2301(07 票 CR 修复)代理域 17 条能力 + 显式系统代理 + 存活监督全落地(bun test 194/0 源码与编译产物两遍、tsc 干净、check.sh PASS=429 FAIL=0),用户自己的 mihomo 与真系统代理全程未被触碰

- [x] 配置管理与 reload 打通:改配置经内核落盘并触发 mihomo 重载,失败返回结构化错误
      → `proxy.config.get|set`(可调项 `mixedPort`/`allowLan`/`logLevel`/`mode` 落 `<A2_HOME>/mihomo/settings.json`)+
        `src/mihomo/config.ts` 的**确定性渲染**(幂等靠逐字比较;secret 现读留住;**a2 拥有头部、订阅拥有正文**,
        订阅正文里撞名的顶层键行级摘除,不引 YAML 解析器)。重载走 `PUT /configs {path}`,
        **失败即回滚**(写回旧字节 + 再重载一次旧的;回滚的写也失败时不发第二次 reload)并返回
        `proxy_operation_failed` + 指引。06 票留的「mixedPort 7897 做成配置项」在此闭环。
- [x] 模式切换、节点列表/选择、订阅管理(safe/normal 档)全链路 `a2 … --json` 可用;订阅源变更类信任面操作标 dangerous 档(本票内默拒,08 票后可带外确认)
      → 17 条 `proxy.*` **真能力**进注册表(必须经 daemon),并长出域子命令面:`a2 proxy on/off/status/mode/
        node/groups/ping/config/subscription …/supervision`(`cliAlias` 收回契约,最长别名优先,按 `ParameterSpec`
        声明的类型强转 argv)。**两种写法同一条路**有断言(`a2 proxy groups` 与 `capabilities call
        proxy.groups.list` 的 `result` 完全相同)。dangerous = `subscription.add`(沿旧 Swift 逐字)与
        `subscription.remove`(新增面,不可逆故就高不就低),**本票内一律 fail-closed 默拒且不留痕**(有断言)。
- [x] 系统代理接管与还原均为显式内核命令,还原不再挂任何客户端生命周期;无 GUI 全程可完成
      → `proxy.system.enable|disable|status`;快照落 `<A2_HOME>/system-proxy.json`(逐服务 × 逐类型 × 逐字段)。
        顺序即安全语义:**读实况 → 合并出最终还原快照 → 落盘 → 才动系统**;写到一半失败即回滚(故障注入有断言)。
        **重复接管不覆盖首次快照**、接管后新出现的服务并入各记各的原状、还原**不要求内核可达**(善后动作)。
        `networksetup` 整条可注入,门禁里打的是 `test/support/fake-networksetup/`——**一次真系统代理都没碰**。
        CR 后另加一道**全局兜底**:`harness.ts` 默认把 `A2_NETWORKSETUP` 指到一个"一执行就大声失败"的假件
        (退出码 97),忘了注入的测试当场红 —— 因为默认实现走**绝对路径**,PATH 那道防线对它无效。
- [x] 存活探测产出状态与事件(供 CLI 查询,08 票后供订阅推送);杀掉内核 daemon,mihomo 与系统代理设置不受影响,内核回来后监督恢复
      → daemon 里一条**只读**观测循环(`proxy/supervision.ts`):按 `adopted.json` / 自管配置定"盯谁",
        只发 `GET /version`,状态变化写成 `ProxySupervisionEvent`(**内容即 08 票的推送载荷,形状不变**),
        落 `<A2_HOME>/log/proxy-supervision.log`(NDJSON,跨 daemon 世代追加),经 `proxy.supervision.get` 可查。
        `instance_down` **必带指引**,收编档明说「生命周期归原托管方」。票面那条断言逐字落地:
        杀掉 daemon → mihomo 的 pid 不变、控制端点照答、系统代理纹丝不动;新 daemon 起来后观测恢复。
- [x] 代理域断言完成行为对等映射入 `bun test`(以假 mihomo 夹具驱动);`check.sh` 保绿
      → `bun test` 115 → **194**(新增 5 个文件 60 条;CR 后 +15);`test/swift-parity-map.md` 07 票登记 9 组
        (Proxy 15 / Subscription 17 / SystemProxy 10 / CrashRecovery 28 —— 整族淘汰但 **CR229「还原依据
        不能丢」改判为映射** / proxy-e2e 分组 / subscriptions-e2e 分组 / flagship+真核 / 能力集对照 /
        本票新账 **14** 条)+ 4 条新的「有意的契约变更」。`check.sh` **PASS=429 FAIL=0**(Swift 侧一行未动)。
      **一处做不到项(如实记账)**:写盘失败类故障注入(回滚写失败不发第二次 reload、快照持久化失败即
        fail-closed)需要一层"让某次写盘失败"的假文件系统,本票没造;相关判断在代码里且有注释成文。
      **CR 后修正**:原先另记的两条「做不到」被证伪并已补齐 —— ②「重放接管失败只撤销本次调用」用
        `A2_FAKE_NETSETUP_FAIL_AT` 的写次计数就能命中;③订阅源 http(s) 分支起一个**回环** `Bun.serve`
        即可(「门禁不出网」说的是不连外网,不是不许有 HTTP 往返)。两条都不需要新造基建 ——
        把"我没做"写成"做不到"是 CR 抓到的一处不实记账。
