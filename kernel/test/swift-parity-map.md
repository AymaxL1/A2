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
| 6 | 假 confirm=true 时 handler 恰执行一次 | **映射(08)** | `cli-arbitration.test.ts` ▸ 确认器在场 + 批准 → 照常执行(断言 output = `{wiped:true,target:"disk9"}`,即 handler 恰跑了一次) |
| 7 | dangerous + 假 confirm=false → denied,handler 绝不执行 | **映射(08)** | ▸ 确认器在场 + 拒绝 → confirmation_denied + 退出码 2(码名见「有意的契约变更」2;stdout 里没有 `wiped`) |
| 8 | **confirm=nil 时 handler 绝不执行(fail-closed 保底)** | 映射 | ▸ call dangerous:无确认器 → confirmation_unavailable + 退出码 2,且 handler 一次都没执行 |
| 9 | dangerous 确认回调确实收到本次请求的 input | **映射(08,判据更强)** | ▸ 确认器在场 + 批准(断言 `request.input` 逐字段等于本次调用的入参)。旧断言验的是「回调收到了」,新断言验的是**协议字段**:input 是推给确认器那条报文的一部分;另有一条反证守着「订阅者收不到它」 |
| 10 | 延迟确认不占住调用请求:invoke 立即 pending + `capabilities.result` 查询 | **淘汰(08 改判)** | 旧的 pending + 轮询是为「GUI 模态框占住宿主主线程、而客户端只等 5s」设计的补丁。新架构改用**自描述的等待**:内核先推一帧 `confirmation-pending`(带它承诺的窗口),客户端据此延长自己的截止时间 —— 一次往返、零轮询(spec 壳契约「零轮询」)。理由与代价见「有意的契约变更」6 改写版 |
| 11 | allowedValues 非法取值 → invalid_params(退出码 6) | 映射 | ▸ call 参数校验(第三段:scope=bogus) |
| 12 | allowedValues 合法取值放行执行 | 映射 | ▸ call 参数校验(第四段:scope=persistent) |
| 13 | 未声明 allowedValues 的参数不约束取值 | 合并 | ▸ call safe(message 取任意字符串照常执行) |
| 14 | 契约往返:RiskLevel 与 JSONValue 经 JSON 编解码稳定 | 映射 | `contract-golden.test.ts` ▸ 金标(合法)`capability-descriptor.json` / `capability-call-result.json` 等(解析后逐字段等于磁盘原文) |
| 15 | 退出码映射:每个 error.code 逐码映射正确 | 合并 | CLI 缝上直接断言**真实退出码**(0/1/2/4/5/6 各有活体样本),比断言映射函数更强;未登记码归 6 见 B 组 |

### B. `Tests/AAContractsTests/ExitCodeContractTests.swift`(6 条)

| 旧断言 | 处置 | 新 TS 测试 |
|---|---|---|
| 0–6 七个码的数值被钉死 | 合并 | 数值仍钉在 `src/contract/exit-codes.ts`;CLI 缝断言的是真实退出码(见 A15)。**3(超时)自 08 票起有唯一产出面** `confirmation_timeout`,见「有意的契约变更」8 |
| semantics 恰好覆盖 0…6 且顺序连续 | 淘汰 | 旧断言守的是「帮助表由 semantics 生成」这条实现细节;TS 侧帮助是手写文本,退出码表只出现一次(`usage.ts`) |
| capability_failed → 5 | 映射 | `cli-capabilities.test.ts` ▸ 业务失败 → 退出码 5 |
| denied → 2 | 映射 | ▸ call dangerous → 退出码 2(码名换成 `confirmation_unavailable`);08 票起 `confirmation_denied` 与 `peer_rejected` 也映射到 2,见「有意的契约变更」2 |
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
| 2L / 2L2 / 2L2b–d / 2L3 / 2L4 域子命令(`aa demo echo --message hi`)与 call 同底座 | 顺延 07(05 票改标,见下) | 域子命令面(`cliAlias` 解析、按声明类型强转 argv)本票不做 |
| 2M 未知**域子命令** → `unknown_command` 退出码 1(对照 2i 的 6) | 映射 | ▸ 用法错(未知动作 → `usage` 码 + 退出码 1)与 ▸ describe 未知能力(6)两条一起守住这个区分 |
| D1 / D1b `AA_CONFIRM_AUTO=deny` → 退出码 2 + 无 `wiped` | **映射(08)** | `cli-arbitration.test.ts` ▸ 确认器在场 + 拒绝(码名 `denied` → `confirmation_denied`,退出码仍是 2)。**口径差别要记下**:旧的 `AA_CONFIRM_AUTO` 是宿主里一个 `#if AA_TESTING` 的环境开关(生产构建不可达);新架构里「拒绝」是**假确认器经真协议**回的一个决定 —— 内核里没有任何测试专用的确认旁路 |
| D2 `AA_CONFIRM_AUTO=approve` → 退出码 0 + `wiped:true` | **映射(08)** | ▸ 确认器在场 + 批准 → 退出码 0 且 output 含 `wiped: true`(同上:走真协议,不是编译期开关) |
| **D3 裸 UDS 直连仍被拒、响应绝不含 `wiped`** | 映射 | ▸ 裸 UDS 直连绕开 CLI:dangerous 仍然默拒(拒因从"未确认"变成"无确认器",绕不过仲裁这一点不变) |
| 2'' 假监听器不回应 + `AA_TIMEOUT_SECONDS=1` → 退出码 3 | **映射(08,语义改判)** | ▸ 确认器在场但没人应答 → confirmation_timeout + 退出码 3。**语义换了**:旧的 3 是「客户端等 socket 等腻了」,新的 3 是「**人**没在窗口内做决定」—— 前者已并入 4(这条路走不通),后者才值得单独一个码(见「有意的契约变更」8 改写版) |
| `aa --help` 打全 7 条退出码语义 | 合并 | `usage.ts` 的 USAGE 里仍有整行退出码表;`cli-basics.test.ts` ▸ help --json 断言帮助可机读 |
| `aa docs agents-md` 含 capabilities/dangerous/exit code | 顺延 13 | agent 指引物随分发工件走 |

### D. 本票未触及(留给相邻票,列此免得漏账)

- `Tests/AAHostTestKitTests/ProxyConformanceTests.swift`(12 条代理能力的暴露与风险档、timeout 防呆)→ **顺延 07**。
- `Tests/AAHostTestKitTests/SubscriptionConformanceTests.swift`(订阅四条能力、dangerous 的 `proxy.subscription.add`)→ **顺延 06/07**。
- `Scripts/check/proxy-e2e.sh` / `subscriptions-e2e.sh` 的能力元数据断言 → 随上面两条一起顺延。

---

## 05 票登记:service 安装面(`a2 service install|uninstall|status`)

### A. 旧账清点:**没有**

旧架构里"常驻"是 GUI 宿主自己的事(双击 `.app` 或从 Xcode 起进程),仓库里**没有任何一条断言、也没有任何一段
代码在装 launchd 单元**:`launchd` 一词在旧 Swift 里只出现在"孤儿子进程会被 launchd 收养"的注释中
(`Sources/AAHostMacOS/SystemProcessPort.swift`、`Sources/AAPluginSDK/AAPluginSDK.swift`、
`Scripts/check/proxy-e2e.sh:399`),说的是 mihomo 子进程的回收,归 06/07 票。

**故本票是新增面,无旧账可对**。唯一一处沾边的旧断言是 C 组 2a2(宿主未运行时 stderr 要有"启动指引"),
它在 04 票已记为映射 —— 05 票让那条指引里的 `a2 service install` **真的存在了**(此前是张空头支票)。

### B. 把 04 票标「顺延 05」的条目改标(本票不覆盖,理由如下)

| 旧断言 | 原处置 | 改为 | 为什么 |
|---|---|---|---|
| C 组 2L / 2L2 / 2L2b–d / 2L3 / 2L4:域子命令(`aa demo echo --message hi`)与 call 同底座 | 顺延 05/07 | **顺延 07** | 域子命令面 = 把**能力**映射成 `aa <域> <动作> --参数`(`cliAlias` + 按声明类型强转 argv)。`a2 service` 不是能力:它不进注册表、不经 daemon、没有 manifest,只是名字里也带"子命令"。真正的域子命令面随 07 票的 proxy 能力一起回来。 |
| 「有意的契约变更」第 5 条里 `cliAlias` 的顺延标注 | 顺延 05/07 | **顺延 07** | 同上。 |

### C. 05 票自己的新账(供 07/10 票对照)

| # | 行为 | 断言落点 |
|---|---|---|
| 1 | 三态机读(`not_installed` / `installed_not_running` / `running`),三态都是查询成功(退出码 0) | `cli-service.test.ts` ▸ 未安装 / ▸ 装了但没跑 / ▸ install 后 running |
| 2 | unit 内容:launchd `KeepAlive.Crashed` + `RunAtLoad` + `A2_HOME` 注入 + 日志重定向 | ▸ install(launchd):plist 落位、自愈自启键齐全 |
| 3 | unit 内容:systemd `Restart=on-failure` + `WantedBy=default.target` + `Environment=A2_HOME` | ▸ install(systemd):unit 落 XDG 位置 |
| 4 | unit 路径:`~/Library/LaunchAgents` / `$XDG_CONFIG_HOME/systemd/user` | 同上两条(沙盒里 XDG 有意指到非默认位置,路径断言可证伪) |
| 5 | install 幂等:已收敛时 `actions` 为空,且不再发任何改状态的命令 | ▸ install 幂等(两端各一条)+ 活体冒烟 6/8 |
| 6 | unit 内容漂移即收敛(重写 + 先 bootout 再 bootstrap) | ▸ unit 内容漂了就收敛回去 |
| 7 | uninstall 对称且幂等,进程与 socket 真的没了 | ▸ uninstall(两端各一条)+ 活体冒烟 7/8 |
| 8 | **装完就是能用的**:install 返回后紧接着的 `a2 status` 必须走通 | ▸ install(launchd)末段(去掉等待即红)+ 活体冒烟 4/8 |
| 9 | 崩溃自愈归系统 supervisor,应用层零看门狗 | **只有活体冒烟能验**:`scripts/service-live-smoke.sh` 5/8(SIGSEGV → launchd 重拉) |
| 10 | supervisor 命令失败 → 退出码 5 + 指引带着能原样重跑的那条命令 | ▸ supervisor 命令失败(故障注入) |
| 11 | 本平台无 supervisor → 退出码 6 + 指引给 `a2 daemon run` | ▸ 本平台没有已支持的 supervisor |
| 12 | 红线:只对 `com.a2.kernel` / `gui/<uid>` 说话 | ▸ 红线:整场只对 com.a2.kernel 说过话(逐条命令原文核对)+ 活体冒烟开跑前的"不是我的就不动" |
| 13 | **漂移收敛到进程**(unit 变了且服务在跑 → 跑着的那个也得换成新内容),05 票 CR 补账 | ▸ unit 内容漂了就收敛回去(launchd:bootout+bootstrap,断言 pid 变了)/ ▸ unit 漂了且服务在跑(systemd:`kernel_restarted`,断言 pid 变了且新实例能答话) |

**一处新口径(无旧对照,记此备查)**:`a2 service status` 三态**都是退出码 0** —— "没装"是这条查询的合法答案,
不是查询失败;要"没跑就非零退出"的判据请用 `a2 status`(daemon 不可达 = 4)。两条命令各答各的问题,
不让同一件事有两个来源不同的答案。

---

## 06 票登记:mihomo 共存阶梯(检测 + 三档 + 兼容地板 + 显式升级)

### A. `Scripts/check/mihomo-real-e2e.sh`(锁版真内核 E2E,两组)

| # | 旧断言 | 处置 | 新 TS 测试 |
|---|---|---|---|
| 1 | 锁版内核 SHA-256 与清单一致(比对随包二进制) | **映射(形态改判)** | 新架构**不随包分发** mihomo,所以"比对随包物"变成"**下载物必须对得上锁定版摘要,否则一个字节都不落盘**":`cli-mihomo.test.ts` ▸ 摘要对不上就 fail-closed;摘要与版本的单一来源同源核对见 ▸ 锁版元数据与旧仓那份实测记录同源 |
| 2 | 锁版真 mihomo 接受最小配置(`-t` 校验)/ 已启动且 REST `/version` 可达 | 映射 | ▸ 脚本安装档(下载→落位→unit→起来)与 ▸ 复用档末段:install 返回后 `status` 必须报 `running_instance` 且 `owner=a2`(**判据落在"控制面真的答话"上**,不是 pid) |
| 3 | 真内核报告锁定版本 / `/configs` 报告预期 mixed-port | 部分映射 + 顺延 07 | 版本读回在 ▸ 脚本安装档(`managed.version` = 锁定版);`/configs` 的**内容**面(mode/端口/节点)归 07 票 —— 本票只用它做能力位 `configs_read` 的探针 |
| 4 | E2E 结束不留孤儿 / 宿主退出后真内核已回收 | **改判(反向)** | 旧架构里"宿主退出必须回收内核"是对的(内核是宿主的子进程);新架构**恰恰相反** —— 数据面不随控制面起落。对应断言是 ▸ 数据面不随控制面起落:卸掉内核后 mihomo 的 pid **必须没变**。孤儿回收的责任移交系统 supervisor(`com.a2.mihomo`) |
| 5 | 真核状态 E2E 未修改系统代理后端 | 顺延 07 | 系统代理接管整体归 07 票 |

### B. `Tests/AAHostTestKitTests/ProxyConformanceTests.swift`(与"内核在不在"相关的 5 条)

| 旧断言(@Test 名节选) | 处置 | 新 TS 测试 |
|---|---|---|
| 假 ProcessPort:拉起后探活为真 / 终止后探活为假 / 外部死亡后探活为假 | **合并 + 改判** | 存活探测不再是"宿主探自己的子进程",而是 **supervisor 视角 + external-controller 探针**两条独立事实:▸ 复用档(`managed.state=running` + pid 真活着)/ ▸ 被收编的实例死了(能力位归零、`rest_api_unreachable`) |
| 假 ProcessPort:回收调用被记录(反孤儿可核验) | 淘汰 | 新架构里内核不再是任何 mihomo 的父进程,没有"回收"这件事可记 |
| status 域逻辑:内核存活 → running=true(反映 mode/端口/节点/apiReachable) | 拆分映射 | "在不在 + 控制面通不通"映射为 `presence` + `capabilities`(▸ 跑着别人的实例:三条能力位都是探出来的);mode/端口/节点归 **07 票** |
| status 域逻辑:内核死亡 / 无句柄 → running=false(**如实未运行,不报错**) | 映射 | ▸ 本机全无 → `presence=absent`、**退出码 0**(「没有」是合法答案,不是查询失败;与 `a2 service status` 同一口径) |
| status 域逻辑:进程活但 REST 不可达 → running 仍 true、apiReachable=false | 映射(词换了) | 同一件事的新说法:进程面(`managed.state`/`pid`)与控制面(`capabilities` 含不含 `rest_api`)是两条独立事实,▸ 被收编的实例死了 断言的正是"档位还在、能力位空了" |
| 插件能力 12 条的暴露与风险档 / mode.set / node.select / latency / groups.list | 顺延 07 | 代理行为对等整体归 07 票(04 票 D 组已列账) |

### C. 06 票自己的新账(供 07/10 票对照)

| # | 行为 | 断言落点 |
|---|---|---|
| 1 | 检测机读三态(`running_instance` / `binary_only` / `absent`)+ 将采用的档位,三态都退出码 0 | `cli-mihomo.test.ts` ▸ 全无 / ▸ 只有二进制 / ▸ 跑着别人的实例 |
| 2 | **扫描面全注入**:二进制目录、配置路径、控制端点、发布渠道、自管端口全部可整条替换 | 整份测试文件的沙盒(默认值另有纯计算断言:▸ 扫描面默认值) |
| 3 | **只连回环**:非回环 external-controller 有意不探,如实报告 | ▸ 非回环 → `skippedController` + 降回二进制档;▸ 扫描面默认值(`loopbackTarget` 正反例) |
| 4 | 收编档:只记一笔收编,不装二进制/不写 unit,那个实例的 pid 全程不变;幂等 | ▸ 收编档只记一笔收编 |
| 5 | 收编档不达地板 → 结构化拒绝 + 两条明路,**不擅自升级、不擅自并存** | ▸ 收编对象不达兼容地板 |
| 6 | 被收编的实例死了 → 报警 + 指引(**含人类可执行的重启命令**),内核不越权重拉 | ▸ 被收编的实例死了(指引里那条命令逐字断言) |
| 7 | 复用档:落点是符号链接、真身零改动、配置/数据/unit 自建、控制面真通 | ▸ 复用档 |
| 8 | 复用对象不达地板 → 回退隔离安装并在报文里说明原因 | ▸ 复用对象不达地板 |
| 9 | 脚本安装档:锁定版下载 → SHA-256 校验 → 可执行落位 → unit → 起来 | ▸ 脚本安装档 |
| 10 | 摘要不符 → fail-closed,**落点上一个字节都没写** | ▸ 摘要对不上就 fail-closed(去掉校验即红,已验) |
| 11 | **升级永远显式**:install 绝不换版本,只有 upgrade 换,且换完重启到新二进制 | ▸ 升级永远显式(去掉"已有就不下载"即红,已验) |
| 12 | 升级只对自管那份有效:收编档/复用档一律 `mihomo_not_managed` | ▸ 收编档没有可升级的对象 / ▸ 只读复用档同样拒绝 |
| 13 | **数据面不随控制面起落**:卸内核不动 mihomo(unit 还在、pid 没变);卸 mihomo 保留数据资产 | ▸ 数据面不随控制面起落 |
| 14 | 红线:整场只对 `com.a2.kernel` / `com.a2.mihomo` 两个 label 说过话 | ▸ 红线(逐条命令原文核对)|
| 15 | mihomo 的自愈自启归系统 supervisor(`KeepAlive.Crashed` / `Restart=on-failure`) | ▸ 复用档(plist 键逐条断言);**真 supervisor 的自愈只有活体冒烟能验**,mihomo 侧的活体冒烟顺延(理由见下) |

**一处做不到项(如实记账)**:mihomo 侧**没有**对应 `scripts/service-live-smoke.sh` 的活体冒烟。理由是本票最硬的施工红线 ——
活体冒烟意味着对真 launchd bootstrap 一个 `com.a2.mihomo`、并让它拉起一个真 mihomo,而本机正跑着用户自己的 mihomo。
unit 内容与编排在假件上逐条有断言,真 supervisor 的自愈语义已由 05 票的活体冒烟证过(同一套 plist 键、同一套渲染器)。
若要补,应与 5 条人工项同批、在干净机器上做。

## 07 票登记:代理控制面(配置+reload / 模式·节点·订阅 / 显式系统代理 / 存活监督)

**记账口径提醒**:旧仓同一条行为常常有三个投影 —— swift-testing 的 `@Test`、`Scripts/check/unit-and-domain.sh`
里逐字 grep 那个 `@Test` 名的 `assert_contains`、以及 E2E 里的一条独立断言。前两者算**一条**(文件头已成文);
E2E 那条另算(它验的是真进程/真往返,不是纯逻辑)。下表按旧文件分组,逐条给处置。

### A. `Tests/AAHostTestKitTests/ProxyConformanceTests.swift`(15 条 @Test)

| # | 旧断言(@Test 名节选) | 处置 | 新 TS 测试 |
|---|---|---|---|
| P-1 | 假 ProcessPort:拉起后探活为真 | **淘汰** | 内核不再是任何 mihomo 的父进程(06 票「有意的契约变更」11)。「它还在不在」的新形态是 supervisor 视角 + 控制面探针两条独立事实 |
| P-2 | 终止后探活为假 / 回收调用被记录(反孤儿可核验) | **淘汰** | 同上;新架构没有"回收"这件事可记(mihomo 挂自己的 unit) |
| P-3 | 外部死亡后探活为假(健康检查基石) | 映射(形态改判) | `cli-supervision.test.ts` ▸ 实例掉了 → instance_down + 指引(判据从"父进程探活"换成"控制面探针 + 结构化报警") |
| P-4 | REST 解析 /configs → mode / mixed-port;/proxies → 当前节点(跳过空 now 的分组) | 映射 | `cli-proxy.test.ts` ▸ 自管实例在跑(mode/mixedPort/node 三项)+ ▸ groups(GLOBAL 的 `now: ""` **归一成缺省**) |
| P-5 | status:内核存活 → running=true(并反映 mode/端口/节点/apiReachable) | 映射 | ▸ 自管实例在跑 |
| P-6 | status:内核死亡 / 无句柄 → running=false(**如实未运行,不报错**) | 映射 | ▸ 本机一个实例都没有 → running=false、退出码 0、**不臆造** mode/端口/节点 |
| P-7 | status:进程活但 REST 不可达 → running 仍 true、apiReachable=false | 映射 | 契约上钉死:`ProxyStatusResult` 两字段分开 + 金标 `proxy-status-api-unreachable.json`;`ProxyTarget.running` 的判据里保留了"自管档且 supervisor 报了 pid"这半句 |
| P-8 | 12 条能力的暴露;status/system.enable/system.disable 的风险档与 cliAlias | 映射(条数改判) | `cli-capabilities.test.ts` ▸ list(三档自检样本 + 代理域真能力 + 风险档);条数 12 → **17**,增删见下「07 票能力集对照」 |
| P-9 | groups.list:分组与候选解析;`GLOBAL now=""` 归一为 nil | 映射 | ▸ groups(逐字断言 `global.now` 缺省) |
| P-10 | mode.set:构造对的 PATCH /configs(body mode=global) | 映射(判据更强) | ▸ mode set 之后 get 读回来真的变了 —— 断言的是**改后读回**,不是"发出去的报文长什么样" |
| P-11 | node.select:构造对的 PUT /proxies/PROXY(body name=NODE-B) | 映射(判据更强) | ▸ node 选中之后 groups 与 status 两处读回都变了 |
| P-12 | latency:逐节点延迟;超时节点 delayMs=nil + timeout=true | 映射 | ▸ ping 逐节点延迟对齐候选清单,缺席的如实标注超时(**SLOW 没有 delayMs 这个键**) |
| P-13 | 能力暴露:groups.list=safe cliAlias[proxy,groups];latency.test=safe cliAlias[proxy,ping] | 映射 | `cli-proxy.test.ts` ▸ 域子命令 ≡ 能力调用(别名真的被解析到)+ ▸ list 的风险档断言 |
| P-14 | 能力暴露:mode.set=normal + allowedValues[rule,global,direct];node.select=normal 两参必填 | 映射 | ▸ mode 非法取值被校验层拦下(**大小写敏感**,RULE 被拒)+ ▸ 用法错(node 缺参) |
| P-15 | 防呆:超大有限 timeout(1e300)→ invalid_params(不越界崩宿主) | 映射 | ▸ ping timeout 防呆(CLI 层挡 inf/nan → 退出码 1;内核层挡 1e300 → 退出码 6,**且 daemon 还活着**) |

### B. `Tests/AAHostTestKitTests/SubscriptionConformanceTests.swift`(17 条 @Test)

| # | 旧断言 | 处置 | 新 TS 测试 |
|---|---|---|---|
| S-1 | id:同名(大小写不敏感)同 id;两个非 ASCII 名不碰撞;空名 → nil | 映射 | `cli-subscriptions.test.ts` ▸ id 由名字确定性派生(FNV-1a 32 位,与旧实现同一个算法) |
| S-2 | add:空名 → invalidParams,且**先于任何 I/O** 拒绝 | **映射(08)** | `cli-subscriptions.test.ts` ▸ add 空名:先于任何 I/O 就被拒(源指向一个**根本不存在的文件** —— 若实现先拉再校验名字,错误码会变成 `subscription_failed` 而不是 `invalid_params`) |
| S-3 | list:空清单 → active=null、条目为空 | 映射 | ▸ list 空清单 |
| S-4 | add:新增成功、id 带 slug 前缀、**不自动激活** | **映射(08)** | ▸ add 经确认器批准:真的新增了、id = `subscriptionId(名字)`、`reloaded:false` 且 `active` 仍是 null(再查一次 list 复核) |
| S-5 | add:同 name 再 add → 同 id、upsert 换源 | **映射(08)** | ▸ add 同名再来一次 = 换源:同一个 id、`action: "replaced"`、清单仍只有一条、物化配置的 marker 换成新版 |
| S-6 | add:拉取失败不留痕 | **映射(08)** | ▸ add 拉取失败不留痕:清单与物化目录都不该因为一次失败的 add 而出现 |
| S-7 | add:空内容 → 业务失败 | 合并 | 空内容与拉取失败共用 `assertUsableBody` 那一段;两个入口各有一条活体断言(▸ update 内容为空 → 拒绝落盘、▸ add 拉取失败不留痕) |
| S-8 | activate:激活成功;已是 active 幂等且**不重复重载** | 映射 | ▸ activate 正文渲染进自管配置…… + ▸ activate 幂等(reloaded=false) |
| S-9 | activate:切换生效;未知 id → 业务失败且 active 不变 | 映射 | ▸ activate 未知 id → subscription_failed + 激活项不变 |
| S-10 | activate:重载失败后 active 不变(无半态) | 映射(判据更强) | ▸ activate 内核不认那份配置 → 回滚(清单**与磁盘配置**都退回上一态) |
| S-11 | update:激活项更新成功、带 lastUpdatedAt、触发一次重载;未知 id → 业务失败 | 映射 | ▸ update 重新拉取 file:// 源、激活项重载、分组换成新版本 |
| S-12 | update:拉取失败什么都没改 | 映射 | ▸ update 拉取失败 → 什么都没改 |
| S-13 | update:空内容什么都没改 | 映射 | ▸ update 内容为空 → 拒绝落盘 |
| S-14 | update 回滚:配置回退为旧、saveConfig 序列 [新,旧]、reload 共 2 次 | **合并 + 改判** | 新架构里"物化配置"与"内核跑的配置"是两份(a2 头 + 订阅正文渲染成 `config.yaml`),回滚发生在 `applyManagedConfig` 那一层并**逐字**验证:▸ activate 内核不认那份配置(断言磁盘配置逐字等于回滚前)。旧断言的"reload 调用次数"属实现细节,不再单独计数 |
| S-15 | F6 回滚自身失败:不再发第二次 reload | **保留实现,无活体断言** | `proxy/config.ts::rollback` 里那条判断在(写回失败即抛,不发第二次 reload),但故障注入需要"让写盘失败"这一层假件,本票没造。如实记为**做不到项**,与 5 条人工项同批考虑 |
| S-16 | F5 损坏清单:list/add 均 capabilityFailed;**绝不覆盖用户数据** | 映射 | ▸ 清单文件损坏:一切读写都停手 + 指引,且那份坏文件**一个字节都没被改** |
| S-17 | 能力暴露:add=dangerous 需 name+source;list=safe;activate/update=normal 需 id | 映射 | `cli-capabilities.test.ts` ▸ list(`proxy.subscription.add` = dangerous)+ `cli-subscriptions.test.ts` ▸ add 默拒 |

### C. `Tests/AAHostTestKitTests/SystemProxyConformanceTests.swift`(10 条 @Test)

| # | 旧断言 | 处置 | 新 TS 测试 |
|---|---|---|---|
| SP-1 | 快照捕获全部服务,**逐字段**记录第三方代理的开关/host/port | 映射 | `cli-system-proxy.test.ts` ▸ proxy on(断言快照 `services` 逐字段等于接管前 fixture) |
| SP-2 | 接管:各服务 HTTP/HTTPS/SOCKS 均指向内核端口 | 映射 | ▸ proxy on(两服务 × 三类逐条断言) |
| SP-3 | 还原:第三方精确复原、原本关的仍是关、终态 == 接管前 | 映射 | ▸ proxy off:终态**逐字段等于接管前**(整棵状态 `toEqual`,不是 grep 子串) |
| SP-4 | 幂等:重复 enable 不覆盖首次快照;二次 disable → no-op restored=false | 映射 | ▸ 重复接管不覆盖首次快照 + ▸ proxy off 没接管过就是干净的 no-op |
| SP-5 | 内核端口未就绪 → 业务失败,**net.setCalls 为空**(零写入) | 映射 | ▸ 内核报不出混合端口 → 拒绝接管且**零写入**(断言 networksetup 调用日志一条没多) |
| SP-6 | 重放漏洞:接管后新增的服务也被纳入,还原回它自己接管前的状态 | 映射 | ▸ 接管之后新出现的网络服务(fixture 里中途插入 iPhone USB + 它自己的第三方代理) |
| SP-7 | 事务:持久化接管清单失败 → fail-closed、系统代理零写入 | **保留实现,无活体断言** | `system-proxy.ts::writeSnapshot` 失败即抛且在任何写之前(顺序有注释成文),但"让写盘失败"要另造一层假件。**做不到项**,与 S-15 同批 |
| SP-8 | 事务:接管写到一半失败 → 用完整快照回滚,不留半接管态 | 映射 | ▸ 接管写到一半失败 → 回滚到本次调用前(`A2_FAKE_NETSETUP_FAIL_AT` 故障注入)+ 首次失败时快照标记也清掉 |
| SP-9 | 重放失败只撤销本次调用,既有接管仍保持启用 | 映射(**CR 补**) | `cli-system-proxy.test.ts` ▸ 二次接管写到一半失败 —— `A2_FAKE_NETSETUP_FAIL_AT` 按**写次**计数即可命中(首次接管固定 12 次写,故障放在第 15 次就落在二次接管里)。三条都断:回到本次调用前(仍接管)、首次快照原样留着、之后 off 仍能精确还原。CR 前误记为做不到项,**已证伪并补齐** |
| SP-10 | 回滚也失败 → 保留接管标记供下次启动自愈 | **拆成两半**:「保留标记」映射,「下次启动自愈」淘汰 | 「启动自愈」随「退出即还原」一起废除(见下 D 组),但**它护着的那件事没废** —— 还原依据不能丢。新语义由 ▸ 还原写到一半失败 → 快照留着,再敲一次 off 仍能精确还原 守住:重试由人显式发起,而不是下次启动时自动补救。CR 前被 D 组整族淘汰盖掉,**已改判** |

### D. `Tests/AAHostTestKitTests/CrashRecoveryConformanceTests.swift`(28 条 @Test)—— **整族淘汰,理由成文**

旧的崩溃自愈是「宿主退出即还原」这条设计的**补丁**:因为还原挂在 GUI 进程的生命周期上,所以进程被 `kill -9`
时还原就丢了,于是需要下次启动时读持久化标记、判五分支(clean / userChangedProxy / alreadyHealthy /
recoverTakeover / restoreSnapshot)、reap 上世代孤儿内核、核验 pid 身份防盲杀、主副标记 + 墓碑……

新架构把**前提**拆了(ADR 0008 / spec:「退出即还原」废除):
- 还原是**显式命令** `a2 proxy off`,不挂任何进程的生命周期 → 没有"退出时没来得及还原"这个洞;
- mihomo 挂**自己的** `com.a2.mihomo` unit,内核不是它的父进程 → 没有"上世代孤儿内核"可 reap,
  自然也就没有"pid 复用盲杀"要防;
- 接管快照落在磁盘上、只由 `proxy off` 消费 → 内核崩了、机器重启了,那份快照照样是有效的还原依据。

**但整族淘汰有一条例外**(CR 抓到的漏账):旧的 **CR229「还原失败保留快照、下次可重试」**护的是
「**还原依据不能丢**」,这件事与"退出时还不还原"毫无关系 —— 快照没了,用户就永远回不去接管前的样子。
它已在 C 组 SP-10 改判为**映射**(▸ 还原写到一半失败 → 快照留着,再敲一次 off 仍能精确还原)。
"整族淘汰"说的是那 28 条**为"进程退出"这个触发点服务的编排**,不包括它们顺带护住的、与触发点无关的不变量。

除此之外的 28 条**没有一条需要在 TS 侧重生**。它们守的性质由**两条更强的断言**接手:
1. `cli-system-proxy.test.ts` ▸ 内核 daemon 被杀:系统代理与快照纹丝不动;新 daemon 起来后照样能显式还原;
2. `cli-supervision.test.ts` ▸ 杀掉内核 daemon:mihomo 的 pid 不变、系统代理不变;内核回来后监督恢复。

**一处如实说明**:旧的 `userChangedProxy` 分支(用户在接管期间自己改了代理 → 内核不覆盖)在新架构里
**没有对位物**:`proxy off` 无条件按快照还原。这是有意的取舍 —— 显式命令的语义就是"照我说的做",
而"猜用户是不是自己改过"正是旧实现里最难验、最容易误判的一段(旧仓为它写了 6 条断言 + 一条 deferred 保守分支)。
若将来要恢复这条保护,应作为 `proxy off` 的一个显式开关(`--only-if-mine` 之类)重新立票,而不是让它默认发生。

### E. `Scripts/check/proxy-e2e.sh`(103 条可数断言,按组)

| 组 | 旧断言 | 处置 | 新 TS 测试 |
|---|---|---|---|
| P1/P1b/P2 | proxy status 存活/死亡两态;域子命令 ≡ capabilities call **逐字节一致** | 映射(判据微调) | ▸ 自管实例在跑 / ▸ 一个实例都没有 / ▸ 域子命令 ≡ 能力调用。**逐字节 → 逐字段**:新包封带每次现造的相关性 id,断言改成 `result` 完全相等(见「有意的契约变更」14) |
| B / C | 宿主退出后无孤儿;SIGTERM-忽略型内核被 SIGKILL 兜底回收 | **淘汰(反向)** | 同 06 票 C 组 13:新架构里内核**不该**回收 mihomo。对应断言是「卸掉内核之后 mihomo 的 pid 必须没变」(06 票已立)+ 本票 ▸ 杀掉内核 daemon:mihomo 的 pid 不变 |
| CP0 | 能力元数据经 wire 下发(risk / cliAlias / allowedValues / 参数声明) | 映射 | `cli-capabilities.test.ts` ▸ list / ▸ describe;`cliAlias` 收回契约(见「有意的契约变更」15) |
| CP1–CP4 | groups / mode 改后读回 / node 改后读回 / ping 三态 | 映射 | ▸ groups / ▸ mode / ▸ node / ▸ ping(逐条) |
| CP2b | 非法取值 → invalid_params 退出码 6,**未触达内核**(mode 仍是旧值) | 映射 | ▸ mode 非法取值被校验层拦下(末尾断言 mode 仍是上一步设的 global) |
| CP5 | `--timeout inf` / `nan` → 退出码 1(CLI 层 isFinite 钳制) | 映射 | ▸ ping timeout 防呆(前半) |
| CP5b | 宿主侧越界防呆 → 退出码 6 且宿主仍存活 | 映射 | ▸ ping timeout 防呆(后半,断言 daemon 还答话) |
| CP6 | 域子命令 ≡ capabilities call(第二个样本) | 合并 | 同 P1b 那条(一条足够,两条是旧脚本的重复) |
| SP0 | system.enable/disable 的 risk 与 cliAlias | 映射 | `cli-capabilities.test.ts` ▸ list + `cli-system-proxy.test.ts` ▸ 域子命令 ≡ 能力调用(proxy off) |
| SP1–SP3 | proxy on 退出码/报文/接管落项数 6/6/原第三方被覆盖;on ≡ call | 映射 | ▸ proxy on(落项数从 fixture 现算:2 服务 × 3 类)+ ▸ 域子命令 ≡ 能力调用 |
| SP3b | id 映射与 cliAlias 别名并存(`aa proxy status` 仍通) | 映射 | ▸ 域子命令 ≡ 能力调用(两种写法都跑通)|
| SP4 | proxy off:restored=true;Ethernet 精确回第三方;**终态 = 接管前快照**(python JSON 全等) | 映射 | ▸ proxy off:终态**逐字段等于接管前**(`toEqual` 整棵状态,语义与 python 全等一致) |
| SP5 | 宿主正常退出后终态 = 接管前快照(退出即还原) | **淘汰(前提没了)** | 「退出即还原」废除。取而代之的是它的**反面**:▸ 内核 daemon 被杀:系统代理**纹丝不动**(退出**不**还原,还原只由 `a2 proxy off` 发起) |
| SH 剧本 A–D | 崩溃自愈四剧本(recoverTakeover / restoreSnapshot / userChangedProxy / 主标记损坏) | **淘汰** | 同 D 组:整族的前提被拆掉了 |

### F. `Scripts/check/subscriptions-e2e.sh`(43 条可数断言)

| 组 | 旧断言 | 处置 | 新 TS 测试 |
|---|---|---|---|
| 场景 1 | 多订阅存储 + 单一激活 + 切换生效(改后读回 groups.now / mode / active) | 映射 | ▸ activate 正文渲染进自管配置、内核重载、**分组真的换了**(读回判据同源) |
| 场景 2 | dangerous 两分支(approve → added;deny → 退出码 2 且不留痕) | **映射(08 补齐 approve 那半)** | 三条并存:▸ add 默拒 + 不留痕(无确认器 → `confirmation_unavailable`)/ ▸ add 经确认器批准:真的新增了 / ▸ add 被确认器拒绝:`confirmation_denied` + 退出码 2 + 不留痕。旧的一条 deny 分支现在有两种对位物 —— 新模型里「没人能确认」与「有人不同意」是两件事 |
| 场景 2 | F2 确认层可见性(`[confirm]` 行带 name/source) | **映射(08:从日志升成协议字段)** | 旧实现把入参渲染成宿主日志里的一行 `[confirm] <id> key=value`,E2E 靠 grep 它证明「input 到达确认层、没有盲批」。新架构把这件事**升成协议**:`ConfirmationRequest.input` 是推给确认器的报文字段,确认器必须原样呈现。断言:▸ add 经确认器批准(`request.input` 逐字段 = `{name, source}`)+ `cli-arbitration.test.ts` ▸ 确认器在场 + 批准。**还多守了一条旧断言守不住的**:▸ 确认内容不外泄 —— 那份 input **只**发给 confirm-agent,订阅者一帧都收不到 |
| 场景 3 | update(normal)零 GUI 确认、不挂起 | 映射 | ▸ update 重新拉取…(没有任何确认器在场,命令照常 0 退出 —— 这就是"normal 零确认"的反证) |
| 场景 4 | 裸 UDS 直连 add 仍 denied(绕过 CLI 躲不过确认) | 合并 | `cli-capabilities.test.ts` ▸ 裸 UDS 直连绕开 CLI:dangerous 仍然默拒(04 票已立;仲裁在 `registry.invoke` 里,与是哪条能力无关) |
| 场景 5 | http:// 源真路径跑通 | 映射(**CR 补**) | 起一个**回环**上的 `Bun.serve` 当订阅源(与旧脚本那个本地 `python3 -m http.server`、与假 mihomo 是同一种姿势 —— 「门禁不出网」说的是不连外网,不是不许有 HTTP 往返)。`cli-subscriptions.test.ts` ▸ update:http:// 源走真 HTTP 往返 + ▸ http 源返回 404 → 什么都没改。CR 前误记为做不到项,**已证伪并补齐** |
| 场景 6 | F3 重启后自动重载激活订阅(catalog 与内核不发散) | **淘汰(前提没了)** | 新架构里激活订阅**已经渲染进 `config.yaml`**,而 unit 的 ExecStart 就是 `-f <config.yaml>` —— mihomo 起来读的就是它,不需要内核在启动时补一次 reload。对应断言是 ▸ activate 之后读 `config.yaml` 里有订阅正文 |

### G. `Scripts/check/flagship-e2e.sh` 与 `mihomo-real-e2e.sh` 的代理相关段

| 旧断言 | 处置 | 说明 |
|---|---|---|
| FS1 旗舰链四步(on → 切模式 → 选节点 → 更新订阅)在**同一宿主实例**上成功 | **顺延 10** | 旗舰 e2e 对 `a2` 重写是 10 票的面(spec 测试决策第 4 条);本票把四步各自的单元/CLI 缝断言都建好了,10 票把它们串成一条链 |
| FS2 全链零 GUI 打断的三条证据(确认档位 / 无 `[confirm]` 行 / 无 pending) | **部分映射(08)+ 顺延 10** | 「确认档位」的对位物已就位:旗舰链四步全是 safe/normal,`cli-arbitration.test.ts` ▸ 零轮询…… 断言 **safe 档一条事件都不产**、normal 档直通 0 退出;「无 pending」的对位物是 `arbitration.status` 的 `state.pending` 为空。**串成一条链**仍归 10 票 |
| FS3 反向对照:dangerous 换源确实触发确认且 deny 挡住 | **映射(08)** | ▸ add 被确认器拒绝:`confirmation_denied` + 退出码 2 + 清单没出现(串进旗舰链仍归 10) |
| FS4 全链只经 `aa`:argv 逐行核对 + UDS 流量对账 | 顺延 10 | 属旗舰链的审计面 |
| FS5 `aa docs agents-md` 提到的能力 id 都真实存在 | 顺延 13 | agent 指引物随分发工件走(04 票已标) |
| MK2「真核状态 E2E **未修改**系统代理后端」(`cmp -s` 逐字节) | 映射(更强) | ▸ 观测是只读的:整场没有对系统代理发过**任何**调用(`networkCalls` 为空数组,比"文件没变"更强 —— 连读都没有) |

### H. 07 票能力集对照(旧 12 条 → 新 17 条)

| 旧 id | 新 id | 变化 |
|---|---|---|
| `proxy.status` | `proxy.status` | 保留;output 加 `endpoint`(跟谁说话)与 `systemProxy` 摘要 |
| `proxy.license` | — | **顺延 13**:GPL 义务面收缩为「调用外部程序」,落点改为 `a2 about` 子命令 + 随包静态文本(ADR 0007 修订版) |
| `proxy.system.enable` / `.disable` | 同名 | 保留(risk / cliAlias 逐字不变) |
| — | `proxy.system.status` | **新增**:接管快照与系统实况可查(旧实现只能从 `proxy.status` 间接看出来) |
| `proxy.groups.list` | 同名 | 保留 |
| `proxy.latency.test` | 同名 | 保留(默认 URL、默认 5000ms、钳制 1..600000 逐字不变) |
| `proxy.mode.set` | 同名 | 保留 |
| — | `proxy.mode.get` | **新增**(票面要求 mode get/set) |
| `proxy.node.select` | 同名 | 保留 |
| `proxy.subscription.list` / `.activate` / `.update` / `.add` | 同名 | 保留(risk 逐字不变:list=safe、activate/update=normal、add=**dangerous**) |
| — | `proxy.subscription.remove` | **新增**(票面要求 remove)。定为 **dangerous**:它抹掉的是用户自己攒的东西且**不可逆**,而 normal 档的定义是"可逆写"。旧系统没有这条命令,故无对等约束 |
| — | `proxy.config.get` / `.set` | **新增**:自管配置的可调项(mixedPort / allowLan / logLevel / mode)。旧实现的配置是**随包静态 YAML**,没有可调项这回事(06 票留的「mixedPort 做成配置项」归本票) |
| — | `proxy.supervision.get` | **新增**:存活观测(旧实现没有常驻监督,只有 `proxy.status` 被调用时的一次性探活) |

### I. 07 票自己的新账(供 08/10 票对照)

| # | 行为 | 断言落点 |
|---|---|---|
| 1 | **收编档的写面到配置为止**:改模式/选节点可以,换配置文件类(config.set / 订阅激活)一律 `mihomo_not_managed` | `cli-proxy.test.ts` ▸ 收编档 + `cli-subscriptions.test.ts` ▸ 收编档 |
| 2 | a2 拥有配置头部:订阅正文里撞名的顶层键被摘除,控制端点与 secret 保住 | ▸ activate(断言配置里没有订阅那份 external-controller / secret / mixed-port) |
| 3 | 配置收敛是**逐字比较**的幂等:同样的设置再来一次 `actions` 为空、不打扰内核 | ▸ proxy config(末段) |
| 4 | 重载失败即回滚,磁盘配置**逐字**回到上一份 | ▸ config set 内核不认新配置 / ▸ activate 内核不认那份配置 |
| 5 | 系统代理接管**先落快照再动系统**;失败回滚且首次失败连快照标记一起清 | ▸ 接管写到一半失败 |
| 6 | 系统代理还原**不要求内核可达**(善后动作最需要它能跑通的时候恰恰是内核没了的时候) | ▸ 内核 daemon 被杀…新 daemon 起来后照样能显式还原 |
| 7 | 存活观测**只读**:整场零 networksetup 调用、零改状态的 supervisor 命令 | `cli-supervision.test.ts` ▸ 观测是只读的 / ▸ 实例掉了(断言 supervisor 只有 print 与 install 那几条) |
| 8 | 报警自带「人类如何完成」,且收编档明说「生命周期归原托管方」 | ▸ 实例掉了 / ▸ 被收编的实例死了 |
| 9 | 事件落 NDJSON 日志且**跨 daemon 世代追加**(不是每次重来) | ▸ 杀掉内核 daemon…(断言两条 `watch_started` + 一条 `watch_stopped`) |
| 10 | 域子命令是 argv 门面而非第二条通路 | ▸ 域子命令 ≡ 能力调用(proxy 与 system 各一条) |
| 11 | 红线:整场对 networksetup 说过的话只有内核认得的那几条子命令、只针对沙盒里的服务 | `cli-system-proxy.test.ts` ▸ 红线 |
| 12 | **a2 拥有的顶层键三种写法都摘**(裸键 / 单引号 / 双引号),且不误伤前缀相同的键、块标量整段丢 | `mihomo-config.test.ts` ▸ 三种写法都摘 / ▸ 不误伤前缀相同的键 / ▸ 块标量 / ▸ 嵌套层不动 / ▸ 表与实现不许脱节 |
| 13 | **订阅正文含 YAML 文档分隔符即拒绝**(不摘除):否则拼出来是多文档流,mihomo 只读第一份,订阅整份静默失效而重载报"成功" | `mihomo-config.test.ts` ▸ findDocumentSeparator 正反例 + `cli-subscriptions.test.ts` ▸ update 拉到含 `---` 的正文 / ▸ activate 物化配置被改成多文档 |
| 14 | 重载失败的三种收场**文案各不相同**(回滚了 / 没有可回滚的 / 回滚也失败),不共用一句含糊的话 | `proxy/config.ts` 的 `ROLLBACK_MESSAGE` 表;▸ config set 内核不认新配置 断言的是"已回滚"那一支 |

**一处做不到项(如实记账,与 5 条人工项同批考虑)**:
**写盘失败类的故障注入**(S-15 回滚写失败不再发第二次 reload、SP-7 快照持久化失败即 fail-closed):
要一层"让某次写盘失败"的假文件系统,本票没造。相关判断在代码里且有注释成文
(`proxy/config.ts::rollback` 的 catch、`system-proxy.ts::writeSnapshot` 的 catch)。

**CR 前另记的两条已被证伪、现已补齐**:SP-9(重放接管失败只撤销本次调用)与订阅源 http(s) 分支 ——
前者用 `A2_FAKE_NETSETUP_FAIL_AT` 的写次计数就能命中,后者起一个回环 `Bun.serve` 即可,
都不需要新造基建。记账时把"我没做"写成"做不到"是本票 CR 抓到的一处不实,记此备查。

---

## 08 票登记:三层仲裁完全体 + 角色注册 + 订阅推送

本票没有"新的一族旧断言"要搬 —— 它兑现的是**前面几票欠下的账**:04 票 A 组 6/7/9(确认器在场的三条)、
C 组 D1/D1b/D2/2''、07 票 B 组 S-2/S-4/S-5/S-6、F 组场景 2 与 F2、G 组 FS3。上面各处已就地改判,
本节只登记**新建的、旧仓根本没有对位物**的那部分,以及一处如实的做不到项。

### A. 新建行为(旧 Swift 无对位物 —— 新架构才有的东西)

| # | 新行为 | 断言 | 为什么旧仓没有 |
|---|---|---|---|
| N-1 | 角色注册:长连接上注册 confirm-agent / subscriber,一条连接可两者兼有,重复注册幂等 | `cli-arbitration.test.ts` ▸ 注册即全量快照 / ▸ 一条连接可以既是确认器又是订阅者 | 旧架构里"确认"是宿主进程内的一个**函数回调**,不是协议;宿主与内核是同一个进程,没有"在不在场"这回事 |
| N-2 | **在场 = 长连接**:确认器断线即离场,在途请求立即降回默拒(不等超时) | ▸ 在途挂起时确认器断线 → 立即降回默拒 / ▸ 确认器走了之后:下一条 dangerous 立刻回到第①层 | 同上:进程内回调不会"断线" |
| N-3 | 全量快照 + 增量推送、**零轮询** | ▸ 注册即全量快照 / ▸ 零轮询:注册之后一条请求都不再发…… / `cli-supervision.test.ts` ▸ 事件同时推给订阅者 | 旧壳与宿主同进程,状态靠直接读;推送面是新架构才需要的 |
| N-4 | **确认内容不外泄**:input 只发给 confirm-agent,订阅者只看得到在途请求的坐标 | ▸ 确认内容不外泄 | 旧实现里 input 只在宿主进程内部流转,不存在"发给谁"的问题 |
| N-5 | 对端 UID 校验(`getpeereid` / `SO_PEERCRED`),非同 UID 连接当场被拒 + 留痕 | ▸ 对端 UID 与内核不符:连接当场被拒 + 留痕 | 旧 UDS 面没有任何对端校验(03 票只做了文件权限两道门) |
| N-6 | 仲裁审计:请求/批准/拒绝/超时/降级/角色进出/被拒对端,NDJSON 落盘 + 可查询 + 推送 | ▸ 审计留痕:请求与收场配对可查 / ▸ 无确认器的默拒也留痕 | 旧实现只有宿主的自由文本日志(`hostLog`),不是结构化审计,也无从查询 |
| N-7 | 协议面的三条拒绝:未注册角色就做决定 / 决定一条不存在的确认 / 注册未知角色 | ▸ 角色是连接的属性 / ▸ 协议面的两条拒绝 | 新协议面才有的错误族 |
| N-8 | **活体拒绝报文 ≡ 金标**(除 id、路径类字段与超时窗口值) | ▸ 活体默拒/拒绝/超时报文 ≡ 金标(三条) | 04 票 CR 的建议;旧仓的 E2E 只 grep 关键字,不做整份报文对照 |
| N-9 | 全命令面无 `--yes`;内核里没有任何读 stdin / 认 TTY 的代码 | ▸ `--yes` 旁路在**每一条**命令面上都不存在(7 条命令面逐条)/ ▸ 永不交互阻塞(结构性断言,扫 `src/**/*.ts`) | 旧仓只在能力面验过一次 `--yes`;"内核里根本没有这类代码"是结构性承诺,旧仓没立过 |
| N-10 | **Linux 形态由构造保证**:角色协议与仲裁层没有任何平台分支 | ▸ Linux 形态由构造保证(扫 6 个文件,并反证平台差异只住在 `peer.ts`) | 旧仓是 mac-only,没有这条承诺 |

### B. 一处做不到项(如实记账)

**Linux 上的 `SO_PEERCRED` 未在真 Linux 上实测**。`daemon/peer.ts` 里那条分支的代码与 macOS 分支同构
(同一个 fd、换一个 `dlopen` 符号),但本机只有 macOS。与仓库既有 Linux 口径一致:代码路径进门禁
(tsc 覆盖,且「协议层无平台分支」这条有活体断言守着 —— 平台差异只住在 `peer.ts` 那一处),
**实机验收随 5 条人工项顺延**。
macOS 分支是**实测**的(见下"一处对研究文档的更正")。

### C. 08 票 CR 修复带来的契约增补(09 票需同步)

CR 修的两条真缺陷与一条语义钉死,都**没有改任何已登记报文的形状**(字段与嵌套一字未动),
但 `AuditAction` 这张封闭词表**增加了三个取值** —— Swift 侧的 enum 要跟着补,否则读到会解析失败:

| 新取值 | 何时产生 | 为什么必须是新的一个,而不是复用旧的 |
|---|---|---|
| `cancelled` | **发起那次调用的连接断开** → 在途确认取消 | 与 `downgraded`(确认器全断)是**相反的一侧**:一个是"没人能批",一个是"没人要这个答案了"。混用会让事后复盘分不清是谁走了 |
| `peer_unverified` | 对端凭据问不出来,连接照常放行(fail-open) | 这是「UID 校验这条路失效了」的唯一信号,与 `peer_rejected`(问出来了、对不上)是两件事 |
| `backpressure_dropped` | 推送积压超限,判定慢消费者并断连 | 它是内核**主动**掐掉一条连接,与客户端自己走的 `*_left` 不同 —— 事后要能分清"它走了"和"我把它请走了" |

另有一条**语义钉死**(形状不变,行为收窄),09/10 票的客户端要依赖它:
**`roles.register` 的响应是该连接上的第一帧,且内核不把「自己进场」这条增量推给注册者自己**——
快照里的计数已经含它,再推一次会让严格按「快照 + 增量」记账的客户端重复计入。
契约文字见 `wire.ts` 的 `KernelSnapshotSchema` 头注;活体断言见
`cli-arbitration.test.ts` ▸ 快照即基线(断第一帧是响应 + 自己收不到自己的进场事件 + 别人收得到)。

### D. 一处对研究文档的更正(实测)

`docs/research/ts-kernel-runtime-bun.md` §4.4 记的是:「`Bun.listen` 的 Socket 不暴露 fd,得改走 `node:net`
兼容层的 `socket._handle.fd`」。**本票在 Bun 1.3.14 上实测:`Bun.listen` 的 Socket 原型链上就有 `fd` 取值器**,
`getpeereid(socket.fd)` 直接返回真实 UID/GID(501/20,与 `id -u`/`id -g` 吻合)。所以内核**不必**为了取凭据
而换掉 `Bun.listen`(那会牵动每连接状态 `socket.data` 的整套写法)。`_handle?.fd` 仍留作兜底。

## 10 票收口:壳原子切换(**本表在此收账,不许留悬账**)

本票是蓝图第⑤步,`Scripts/check/` 整棵(15 模块 / 429 条 PASS)与 `Tests/AA*`(182 条 `@Test`)
随旧 Swift 逻辑面一并退场。前面各票已登记的族不再重复;本节把**此前没有任何登记的那几族**逐条落定,
并在末尾给出全表统计。

### A. `Tests/AAAgentTestKitTests` 七套(89 条 @Test)+ `Scripts/check/agent-e2e.sh`(A-E2E 组)—— 整族**顺延**

| 旧套件 | 条数 | 处置 | 去处 |
|---|---|---|---|
| `AAAgentCoreConformanceTests`(端口协议/消息归一/中断策略) | 8 | 顺延 | agent-delegation spec 修订指令第 2 条 |
| `ClaudeAdapterTests`(stream-json 归一,读 01 spike 真样本) | 10 | 顺延 | 同上 |
| `CodexAdapterTests`(exec JSON 归一,读 02 spike 真样本) | 13 | 顺延 | 同上 |
| `AgentTaskTests`(任务状态机 / 工作区 / 报告) | 23 | 顺延 | 同上 |
| `AgentWatchdogTests`(看门狗与取消) | 13 | 顺延 | 同上 |
| `AgentLaunchAssemblerTests`(命令行组装 / CODEX_HOME) | 11 | 顺延 | 同上 |
| `SystemAgentPortTests`(**真进程** / 进程组 / 反孤儿) | 11 | 顺延 | 同上 |
| `Scripts/check/agent-e2e.sh`(`aa-agent` CLI × 假 agent 全链 + 反孤儿信号两路径) | 21(运行时) | 顺延 | 同上 |

**「21 条」的记账口径(11 票 CR 尾款 c 补记,2026-08-05)**:这个 21 数的是脚本里 **`assert_*` 的调用点**(退场前那一版逐条数得 21 处)。它**不是**该脚本的全部断言点:另有 **8 处内联的 `echo "PASS: …" / echo "FAIL: …"` 判定分支**(反孤儿探针那两段:进程组存活、atexit 清空、SIGTERM 前存活、SIGTERM 后清空,以及样本缺失的兜底),它们不走 `assert_*` 因而没被计入 —— **断言点合计 29**。顺延的是整族行为规范,不因数字口径而变;写在这里是免得将来有人拿 29 去对 21 时以为漏了账。本表其余各组的数字凡取自脚本的,一律是「`assert_*` 调用点」这一口径。

**为什么是顺延而不是淘汰**:05 票裁定「agent-delegation 审批**收敛到内核统一仲裁**;
**执行器将来在内核内以 TS 重生**」,01 票已把这四条修订指令写进 `.scratch/agent-delegation/spec.md` 文末。
这 89 + 21 条描述的是**执行器的行为规范**(怎么归一 Claude/Codex 的输出、任务状态机怎么走、
看门狗与反孤儿怎么保证),重生时逐条兑现它们正是那份 spec 的活儿。

⚠️ **这是全表里唯一一处「顺延的去处不是本效应的某张票」**,如实记明白:
本 spec 的迁移六步表里**没有** agent-delegation 的位置(Out of Scope 也没列它 —— 那是一处遗漏,
本票撞上了)。所以这批账现在挂在 agent-delegation 那份 spec 上,**排期未定**。
要不要为它单立一张票,是编排者/用户的决定,不是本票能裁的。

### B. 14 票菜单栏轻壳:`MenuModelConformanceTests`(2 条)+ `Scripts/check/menubar.sh`(MB 组 5 条)

| # | 旧断言 | 处置 | 新落点 |
|---|---|---|---|
| MB-1 | 覆盖面与可追溯性(结论行 `MENUBAR_ASSERT1`):04 票 In 清单六项全覆盖 + 每项追溯到**真注册表**里存在的能力 + 认领即绑定 + 反向核对 + 参数过集中校验 | **映射(判据更强)** | 拆成 5 条独立断言(`A2PanelTests` ▸ 可追溯 / ▸ 无空头认领 / ▸ 六项逐项覆盖(参数化)/ ▸ 反向核对 / ▸ 豁免表诚实),**外加**旗舰 e2e 的 `PANEL_COVERAGE`:对账对象从「同进程的假注册表」换成**真的跑着的那个内核** |
| MB-2 | 三态如实反映(结论行 `MENUBAR_ASSERT2`) | **映射(扩到四态)** | ▸ 状态①/②/③ 各一条 + **新增** ▸ 状态④(与内核断连)—— 新架构才有的一态,而且是用户最容易误读的一态 |
| MB-3 | 快照产物有效性(尺寸由模型算得出来、PNG 可解码) | 映射 | `A2PanelSnapshotTests` ▸ 快照尺寸由模型算得出来 + ▸ 快照确定性 |
| MB-4 | golden 比对(像素 ≤ 容差 + 模型文本逐字节) | 映射 | ▸ 四种主要状态逐张与 golden 一致(参数化;**判据搬进 `swift test`**,shell 中间层退役) |
| MB-5 | dangerous 从菜单路径发起仍走确认(`AA_MENU_CLICK_PROBE` 起真宿主点真 NSMenuItem) | **合并 + 改判** | 旧断言靠两个 `#if AA_TESTING` 的 env seam(`AA_MENU_PROMPT_AUTO` / `AA_MENU_CLICK_PROBE`)去点真菜单项。新架构里「菜单项 → 能力调用」这条路由**在协议层就是同一个出口**,而 dangerous 是否走仲裁**由内核裁**、与调用方是谁无关(`cli-capabilities.test.ts` ▸ 裸 UDS 直连绕开 CLI 仍默拒已经证过)。旗舰 e2e 的确认链跑的正是壳的真代码路径。**代价如实记**:「人点了那一项、AppKit 真的把 action 发出去了」这一步没有自动化断言 —— 那是 GUI 交互,归人工项 |
| MB-6 | 两个 `#if AA_TESTING` env seam「13 票分发前须处置」 | **淘汰(前提没了)** | 新壳里**一个测试专用 seam 都没有**(人的替身住在 `a2-panel-probe` 这个独立可执行里,不进 products、不进 `.app`)。13 票那条待办随之销账 |

### C. `Scripts/check/app-bundle.sh`(APP 组 10 条)

| # | 旧断言 | 处置 | 新落点 |
|---|---|---|---|
| APP-1 | production 档 `.app` 结构:Info.plist / `MacOS/aahost` / `MacOS/aa` / 资源 bundle / 内核可执行 | **部分映射 + 部分淘汰** | 映射:`build-app.sh` APP1(主可执行就位)。**淘汰**:`aa` 与内核资源 bundle 那三条 —— 前提没了(CLI 归内核 bin 走单文件分发;不再分发 GPL 二进制) |
| APP-2 | Info.plist 键:bundle id / CFBundleExecutable / LSUIElement | 映射(更严) | APP2 / APP3 / APP4 / APP5(多验一条**显示名**「A2 Panel」,spec 命名节钉死) |
| APP-3 | `codesign -dv` 主可执行与内核签名信息 | 部分映射 | APP7(签名标识符);内核那半边随 GPL 二进制淘汰 |
| APP-4 | `codesign --verify --strict` 通过 | 映射 | APP6 |
| APP-5 | e2e 档 `.app` 内 `aahost` 真起得来、UDS/能力面/`install-cli` 全链 | **淘汰(前提没了)** | `.app` 里已无 CLI、无内嵌内核;壳的活体那一关由旗舰 e2e 承担(它跑的是壳的真代码路径)。**代价如实记**:「双击 `.app` 真能起来并挂上状态栏」没有自动化断言 —— 那要 GUI 会话,归人工项 |
| APP-6 | 内核 argv 的绝对路径确实在 `.app` 内(`Bundle.module` 落点结论的运行时证明) | **淘汰(前提没了)** | 不再随包分发内核,没有落点问题可证。实测结论留在 git 历史与 `build-app.sh` 的历史注释里 |
| APP-7 | 随包 GPL-3.0 全文完整(SHA-256 现算现比) | **改判** | 不再随包分发二进制 → 义务面收缩为「调用外部程序」(ADR 0007 修订版)。全文移到 `docs/legal/`,声明落点改为 `a2 about`(顺延 13)+ `A2AboutWindow.declaration`(静态文本) |
| APP-8 | `.app` 内全部 Mach-O 已签且身份一致 | **映射(改判为结构红线)** | APP8:包里**只该有一个** Mach-O —— 多一个就说明有人悄悄改了分发形态(把「都签了」升级成「不该有第二个」) |
| APP-9 | `aa proxy license` 报出的内核版本与 `MIHOMO-VERSION.txt` 一致 | **顺延 13** | `proxy.license` 能力随 GPL 义务面收缩淘汰(07 票 H 组已登记);版本单一来源已搬到 `kernel/contract/MIHOMO-VERSION.txt`,`cli-mihomo.test.ts` ▸ 锁版元数据同源 守着 |
| APP-10 | 子进程红线原文经能力面暴露 | 顺延 13 | 同上,落点改为 `a2 about` 的随包静态文本 |

### D. `Scripts/check/architecture-and-cli.sh`(四组)

| 组 | 旧断言 | 处置 | 新落点 |
|---|---|---|---|
| 3(49 条 PASS) | **架构铁律**:`PluginProxy` / `AAAgentCore` / `AAAgentSystem` 不 import 任何 `Host*`;反孤儿钩子的依赖闭包守卫 | **改判(同一条精神,新的载体)** | 旧铁律护的是「插件域不得依赖宿主」。新架构里那条边界由**进程边界**承担:插件是进程外子进程、只经协议白名单拿能力(ADR 0011);壳这侧的对位物是 `Package.swift` 的依赖图本身(`A2Panel` 零 AppKit、`A2Contract` 零依赖)+ `A2PanelTests` ▸ 菜单只投影 proxy 域。**插件侧的新断言已由 11 票落地(2026-08-05,此账销清)**:`kernel/test/cli-plugin.test.ts` ▸ 红线①插件 pid ≠ 内核 pid(进程外)、▸ 红线②插件环境里一个 `A2_*` 都没有(协议白名单)、▸ 红线③ spawn 恒带 `--no-install` 且 import 不在的包当场硬失败(不联网现装)、▸ 红线④内置能力无一以 `plugin.` 开头(命名空间隔离);外加 `Scripts/a2-plugin-e2e.sh` 幕 3 在**真内核 + 真插件子进程**上把前两条再验一遍(3-1/3-2)。旧铁律靠 49 条 grep 守「不许 import」,新铁律靠**进程事实**守「根本不在一个进程里」—— 后者更难被绕过 |
| 4(7 条) | `aa --help` 逐码打印退出码语义表 | 合并 | `usage.ts` 的 USAGE 里仍有整行退出码表;`cli-basics.test.ts` ▸ help --json 断言帮助可机读(04 票 C 组已登记同款) |
| 5(8 条) | `aa docs agents-md` 接入片段(prefix_rule / require_escalated / capabilities call / pending / exit code) | **顺延 13** | 04 票 C 组已标顺延 13(agent 指引物随分发工件走)。**注意其中两条已作废**:`capabilities result <request-id>` 与 `"pending":true` —— pending 态整体淘汰(见「有意的契约变更」6),重写指引时不许照抄 |
| 6(约 12 条) | `aa install-cli` 幂等 / 覆盖 / canonical 化 / `--uninstall` | **淘汰(前提没了)** | `aa` 已退场;CLI 就是内核 bin `a2` 自己,分发形态改判为**单文件下载 + curl 安装脚本**(ADR 0008 / spec 分发节),没有「把 `.app` 里的 CLI 链进 PATH」这回事了。安装脚本的断言归 **13 票** |

### E. `Scripts/check/unit-and-domain.sh`(96 条 `assert_contains`)

**整组合并**,不另计数。按本表开头的记账口径:它 grep 的**就是** `swift test` 输出里那些 `@Test` 的名字
(`Tests/README.md` 与 `RegistryConformanceTests.swift` 头注都成文写着这条隐形契约),
一条行为的两个投影算**一条**。那 96 条对应的 `@Test` 已在 04/06/07 票各组逐条落定。
新门禁里这一层**结构性地消失了**:判据就是 `swift test` 本身的红绿,不再有「shell 侧 grep 用例名」
这条会漂的中间层(改一个 `@Test` 名不再等于改门禁)。

### F. `Scripts/check/flagship-e2e.sh`(FS 组)—— 兑现 07 票 G 组标「顺延 10」的四条

| # | 旧断言 | 处置 | 新落点 |
|---|---|---|---|
| FS1 | 旗舰链四步(on → 切模式 → 选节点 → 更新订阅)在**同一宿主实例**上成功 | **映射** | `Scripts/a2-flagship-e2e.sh` 幕 1(1-2 … 1-7):同一个 daemon、同一条壳连接,四步逐条断退出码 + 改后读回 |
| FS2 | 全链零 GUI 打断的三条证据(确认档位 / 无 `[confirm]` 行 / 无 pending) | **映射(判据更强)** | 1-12:确认器**真的在场**(不是被 env 短路),而链上**只弹了一次**(dangerous 换源那次)。旧断言证的是「没弹窗」,新断言证的是「该弹的弹了、不该弹的一次都没弹」——反证更硬 |
| FS3 | 反向对照:dangerous 换源确实触发确认且 deny 挡住 | **映射(三收场并存)** | 幕 2(批准)/ 幕 3(拒绝,`confirmation_denied`)/ 幕 4(无确认器,`confirmation_unavailable`)—— 旧的一条 deny 分支现在有三种对位物 |
| FS4 | 全链只经 `aa`:argv 逐行核对 + UDS 流量对账 | **改判** | 「只经 CLI」在新架构里是**结构事实**:agent 只有 `a2 … --json` 一条路(内核里没有第二条通路,08 票 N-9 的结构性断言守着)。对账的对象换成了更有意义的一个:**壳发出去的请求数**(`PANEL_IDLE: before==after`)—— 证的是「零轮询」,那才是新拓扑下会被搞砸的东西 |
| FS5 | `aa docs agents-md` 提到的能力 id 都真实存在 | 顺延 13 | 同 D 组第 5 行 |

### G. `Scripts/check/mihomo-real-e2e.sh`(MK 6 条 + MK2 7 条)—— **淘汰(前提没了)+ 一条如实的能力损失**

06 票 A 组已把这两组逐条改判(锁版校验从「比对随包物」→「比对下载物」;
「宿主退出回收内核」→ 反过来的「卸内核 pid 不变」)。本票只补一条**记账**:

> **旧门禁跑的是一个真 mihomo 二进制,新门禁跑的是假件。**
> 于是「**真** mihomo 接受 a2 渲染的那份 `config.yaml`」「**真** mihomo 的 `PATCH /configs` /
> `PUT /proxies` / `GET /group/<n>/delay` 与我们的客户端对得上」这两条事实,此后**没有任何自动化断言**。
> 假 mihomo 忠实复刻的是我们**以为**的那套 REST 语义 —— 它验不了「我们以为的」对不对。
> 这不是本票制造的缺口(06 票起 mihomo 就不随包了),但**在这里才第一次没有兜底**。
> 落定:**顺延到人工项**,与 5 条人工项同批 —— 在干净机器上装一次真 mihomo 跑一遍旗舰链。
> 要提前做需要用户裁定(本机跑着用户自己的 mihomo,是最硬的施工红线)。

### H. 门禁基建(`bootstrap` / `build` / `swift-test` / `test-support` / `finalize`)

不是行为断言,是脚手架。逐条对位:

| 旧 | 新 |
|---|---|
| `bootstrap.sh` 的 swift 工具链探测(`dump-package` rc=0) | `check.sh` 同一条判据、同一个候选顺序,原样保留 |
| `build.sh` 两档构建(`-DAA_TESTING` / `-DAA_E2E`)+ 零 warning | 新壳**没有任何编译期 seam** → 只剩一档;零 warning 成了 `check.sh` 的 ⓪b 步 |
| `swift-test.sh`(把 `swift test` 记作一条断言) | `check.sh` 的 ② 步(同样按**步**判红绿,不按用例数 —— 理由与旧脚本头注逐字相同:否则每加一个 `@Test`,总数就漂一次) |
| `test-support.sh` 的宿主生命周期助手(`teardown_hosts` / `wait_host_ready`) | **淘汰**:没有 GUI 宿主要起停了。旗舰 e2e 的 daemon 生命周期由它自己的 trap 管 |
| `finalize.sh` 的清场核验(R 组:无残留宿主 / stub / 孤儿 + 用户 mihomo pid 前后一致 + 未污染真实 AppSupport) | **映射(判据换了落点)** | 旗舰 e2e 的红线自查段(R-1 真实 `~/.a2` 不存在 / R-2 全程无用户 mihomo 端口 / R-3 只对 `com.a2.*` 说过话)+ 沙盒本身(一切落临时 `A2_HOME`,`pkill -9 -f "$BOX"` 按本次独有路径精确回收) |

### I. 10 票本次退场那批的统计

按**族**统计(逐条明细在上面各表;条数按旧仓的可数断言口径):

| 处置 | 族数 | 代表 |
|---|---|---|
| 映射 | 14 | MB-1…MB-4、APP-2/4/8、FS1/FS2/FS3、E 组 96 条的 `@Test` 本体、finalize 清场 |
| 合并 | 3 | 组 4(帮助退出码表)、E 组(shell grep 层整组)、MB-5 |
| 淘汰 | 8 | APP-1 的三条 / APP-5 / APP-6 / MB-6 / 组 6(install-cli)/ `test-support.sh` / MK·MK2 / 组 3(改判为进程边界) |
| 顺延 | 4 | A 组(agent-delegation 89+21 条)、组 5 与 FS5(顺延 13)、APP-9/APP-10(顺延 13)、G 组的真 mihomo 实测(顺延人工项) |

### J. 全表(04–10 票)累计

统计口径:数的是各表「处置」列**有值的行**;按首关键词归类(`映射(形态改判)` / `映射(判据更强)` /
`部分映射 + …` 一律计入 `映射`,`合并 + 改判` 计入 `合并`)。各票的「自己的新账」表(05 票 C / 06 票 C /
07 票 H·I / 08 票 A / 10 票 H·I)没有「处置」列 —— 它们登记的是**新建行为**,不是旧断言的去向,故不进本统计。

| 处置 | 行数 | 说明 |
|---|---|---|
| 映射 | 100 | 旧行为在新侧有对应断言(其中 9 处明写「判据更强 / 形态改判」) |
| 合并 | 12 | 被另一条更强的断言覆盖 |
| 淘汰 | 13 | 只属旧实现细节,或**前提被拆掉了**(逐条成文,不许只写「不要了」) |
| 改判 | 4 | 同一个位置换了一条**相反**或**同精神不同载体**的承诺(如「宿主退出回收内核」→「卸内核 pid 不变」) |
| 保留实现,无活体断言 | 2 | 代码在、判断在、注释成文,但缺一层故障注入假件(S-15 / SP-7) |
| 顺延 | 22 | 见下表 |
| **合计** | **153 行** | |

**22 条顺延的去处(本票逐条核对,`已兑现` 的那些不再是悬账)**:

| 去处 | 行数 | 状态 |
|---|---|---|
| 顺延 07(含 05 票改标的 2 条) | 5 | **已兑现**(07 票代理控制面落地时逐条登记) |
| 顺延 10 | 2 | **已兑现**(本票 F 组 FS1 / FS2) |
| 顺延 13 | 7 | **已兑现**(13 票分发工件落地时逐条销账,明细见文末「13 票收口」一节) |
| 顺延(agent-delegation spec) | 8 | **未兑现,且去处不是本效应的票**(见 A 组末尾的 ⚠️) |

另有两条**不在表格里的顺延**(散文形态,一并记此免得漏账):G 组「真 mihomo 的 REST 语义与配置兼容性」
顺延人工项;08 票 B 组「Linux `SO_PEERCRED` 实机验证」顺延人工项。

**收口结论**:旧仓的可数行为断言**全部落定**,没有一条"没提过"。~~未兑现的 15 条表内顺延~~
**(2026-08-05 13 票更新:顺延 13 的 7 条已全部兑现,剩 8 条)** 各有明确去处,
其中 agent-delegation 那 8 条的**排期未定** —— 那是本票撞到的一处 spec 遗漏,已在 A 组如实记明。

**四条做不到项**(全表汇总,与 5 条人工项同批考虑):
1. 写盘失败类故障注入(S-15 / SP-7)—— 07 票记;
2. Linux `SO_PEERCRED` 未实机验证 —— 08 票记;
3. mihomo 侧无活体冒烟(真 supervisor 拉起真 mihomo)—— 06 票记;
4. **真 mihomo 的 REST 语义与配置兼容性**(本票 G 组)、**GUI 交互本身**(点菜单项 / 双击 `.app` /
   Touch ID 弹窗)—— 本票记。

---

## 有意的契约变更(不是丢失,是改判 —— 逐条有出处)

1. **`--json` 输出一律是包封**。旧 `aa` 的 list/describe/call 直接打裸 payload(`{"capabilities":[…]}`、
   裸 descriptor、裸 output),失败时才打信封;新内核成功失败**同一形状**,agent 一次 `JSON.parse` 就能分支
   (ADR 0008 第 2 条)。代价:旧的 `assert_contains '"id":"demo.echo"'` 这类 grep 仍成立,但取值路径多一层 `result.`。
2. **`denied` 拆成三码(08 票补齐)**。旧实现里「无确认通道」与「用户点了拒绝」共用 `denied`,只靠 detail
   文案区分。新内核按 ADR 0005 修订后的三层仲裁分开:`confirmation_unavailable`(第①层:**没人能替你确认**,
   含「在途时确认器全断」的降级)、`confirmation_denied`(第③层:**有人看了,他不同意**)、
   `confirmation_timeout`(第③层:**有人在场但没人做决定**)。前两者退出码仍是 **2**,旧的退出码断言不受影响;
   超时归 **3**(见第 8 条)。08 票另加一个同样映射到 2 的 `peer_rejected`(对端 UID 不符,连接当场被拒)。
3. **`WireError` 加 `message`(必填)与 `guidance`(可选)**。旧只有 `{code, detail}`,没有任何机器可读的
   「人类如何完成」;「拒绝即指引」(ADR 0005 第 4 条第②层)要求拒绝自带精确命令,故加字段。
4. **参数类型词汇 `bool` → `boolean`**。旧 Swift 用 `bool`;新契约取 JSON Schema 的词,少一层翻译
   (这张词表要同时喂 agent 和 11 票的插件 describe 输出)。旧断言只 grep 过 `"type":"string"`,不受影响。
5. **`schemaSummary` 与 `cliAlias` 淘汰**。前者是可由 `parameters` 派生的展示串,不进契约(旧 E2E 只断言过
   这个键存在);后者属域子命令面(`aa proxy on`),随该面一起**顺延 07**(05 票改标,理由见 05 票登记 B 段),
   届时如仍需要再进 manifest。
6. **`pending` 态与 `capabilities.result` op 整体淘汰(08 票裁定,不是顺延)**。旧实现之所以要「立即返回
   pending + 客户端拿 requestID 轮询」,是因为 GUI 模态框会占住宿主主线程、而客户端只肯等 5 秒 ——
   pending 是那个约束的补丁。新架构里同一个问题换了解法:**内核先推一帧 `confirmation-pending`**,
   写明「我把这条转给人了、最多等 timeoutMs」,客户端据此把自己的截止时间往后推。于是一次调用仍是
   **一次往返**、**零轮询**(spec 壳契约明写「零轮询」);而「确认窗口是内核的配置、超时判定发生在客户端」
   这个两处共享配置的隐患也一并消失 —— 一致性由**协议**保证,不靠两个进程读同一个环境变量。
   **代价(已知限制)**:等确认期间那条连接是占着的(不能复用它并发别的请求)。对 CLI 一次一命令的形态无影响;
   将来若有客户端要在一条连接上并发多请求,再按「可选字段追加」补一条异步态。顺带解掉旧的一处名字不一致
   (线协议 `requestID` vs CLI 输出 `requestId`)——新契约里只有 `confirmation` 一个拼法。
7. **重复能力 id 从"静默后者覆盖前者"改为"启动即抛"**。旧 `Registry.init` 的字典覆盖是已记账的债;
   能力 id 是 agent 的调用坐标,重名必须在启动时炸,而不是在调用时给出一个"看起来成了"的结果。
8. **退出码 3 的语义被改判:从「socket 等腻了」变成「人没做决定」(08 票裁定)**。旧 `aa` 的 3 来自
   `AA_TIMEOUT_SECONDS` + `SO_RCVTIMEO`——那是**传输层**超时。新客户端把「等不到响应」一律归为
   daemon 不可达(**4**):对调用方而言「对面卡死」与「对面不在」是同一件事,这条路走不通。
   3 现在只有一个产出面 —— **`confirmation_timeout`**:确认请求送到了、确认器也在场,但没有人在窗口内做决定。
   这才值得单独一个退出码,因为 agent 据此该做的事(提醒用户去点)与 4(引导安装服务)完全不同。
   旧断言 2''(假监听器不回应 → 3)的对位物见 C 组同名行。
9. **`demo.note.set` 多一个 `scope` 参数**(`allowedValues: [session, persistent]`,旧 Swift 同名能力无此参数)。
   理由:`allowedValues` 是 manifest 的一部分(07 票的 `proxy.mode.set`、11 票的插件都要用),但内置能力里
   没有任何一条用得上它 —— **写了却没有活体断言的校验代码是负债**。挂在 normal 档样本上,正反两条路径
   (合法放行 / 非法 → `invalid_params`)都能在 CLI 缝上验证。旧断言只调 `key`/`value` 两参,不受影响。
10. **旧 `unknown_command` 码并入 `usage`**。旧 `aa` 的域子命令面(`aa proxy on`)对未知**子命令**产出
   `unknown_command`(退出码 1),与能力面的 `unknown_capability`(退出码 6)是两条码;新 CLI 把"你敲的
   子命令/动作我不认识"整体归到 `usage`(退出码 1 不变),`unknown_capability` 仍是独立码(退出码 6)——
   **两档的区分被保留了,少的只是一个码名**。理由:`usage` 的语义就是"这条命令行不成立",再分一个码
   对 agent 的分支没有新增信息量,而每多一个码 Swift 侧(09 票)与插件侧都要多认一次。
   对应旧断言见 C 组 2M 行(那里只在映射行内提过一句,此处正式记账)。
11. **mihomo 的"回收/反孤儿"整族淘汰,取而代之的是它的反面**。旧架构里 mihomo 是宿主的子进程,所以
   `ProxyConformanceTests` 与 `mihomo-real-e2e.sh` 有一整族"宿主退出必须回收内核 / 不留孤儿"的断言。
   新架构下 mihomo 挂**自己的** `com.a2.mihomo` unit,数据面不随控制面起落(spec/ADR 0007 修订版)——
   于是那族断言的正确形态是**反过来的**:卸掉内核之后 mihomo 的 pid 必须**没变**(06 票 C 组 13)。
   这不是丢失,是同一个位置换了一条相反的承诺。
12. **锁版校验从"比对随包物"改判为"比对下载物"**。旧门禁 MK 组比对的是仓库里那份随包二进制的 SHA-256;
   新架构不分发 GPL 二进制(ADR 0007 修订版),锁版的技术含义变成:下载物必须对得上摘要,否则 fail-closed
   且不落半成品。锁定版号与摘要仍**同源于**旧仓 `Sources/PluginProxy/Resources/MIHOMO-VERSION.txt`
   (有一条测试当场核对两处,换版本必须一起改)——⑤票旧 Swift 面退场时,这个来源要跟着搬家。
13. **`a2 mihomo` 不是能力,是 CLI 本地命令族**(与 `a2 service` 同一种安排)。04 票的提醒说"真能力往
   `BUILTIN_CAPABILITIES` 上加",那指的是 07 票的代理能力(`proxy.mode.set` 之类,必须经 daemon)。
   而"本机 mihomo 是个什么现状"问的是文件系统、supervisor 与 external-controller,**daemon 没跑时更要能答话**,
   所以它与 `a2 service` 一样不进注册表、不经 UDS,只是机读面完全一致(agent 看不出区别)。
14. **「域子命令 ≡ 能力调用」的判据从「逐字节一致」放宽为「`result` 逐字段相同」**(07 票)。旧 `aa` 的两种写法
   打出来的是同一串裸 payload,所以 `diff` 得动;新包封每条都带一个**每次现造的相关性 id**(`ResponseEnvelope.id`),
   逐字节必不相同。断言因此改成「两条命令的 `result` 完全相等」——它守的是同一件事(同一条路、同一个仲裁点),
   而且更精确:它排除了"两边都错成一样"之外的所有分叉。旧断言在 `proxy-e2e.sh` P1b/CP6/SP3 三处,合并成一条。
15. **`cliAlias` 收回契约**(第 5 条的部分撤销)。04 票把它与 `schemaSummary` 一起淘汰,05 票改标顺延 07;
   本票把域子命令面(`a2 proxy on`)建起来了,而**别名表必须由内核说了算** —— 11 票起插件也会往注册表里加能力,
   客户端存一份别名表就一定漂。所以 `CapabilityDescriptor.cliAlias` 回到 manifest(可选字段,不带即"这条能力
   只能用 `capabilities call` 调")。`schemaSummary` **仍然淘汰**(它是可由 `parameters` 派生的展示串)。
16. **`CapabilityFailedError` 可带 `code` 与 `guidance`**(07 票)。04 票的业务失败一律 `capability_failed`;
   代理域的失败大多有明确细因(连不上 / 不归我管 / 组不存在 / 订阅拉不到)与一条人类可执行的下一步,
   全塞进同一个码等于让 agent 去 grep 中文 message。故允许能力自带已登记的 `ErrorCode` 与 guidance;
   **退出码仍由 `exitCodeForErrorCode` 统一裁**(能力决定不了自己的退出码),不带这两样时行为与 04 票逐字相同。
17. **旧 `denied` 在订阅面的那一半也归 `confirmation_unavailable`**(第 2 条的延伸)。`subscriptions-e2e.sh`
   场景 2 的 deny 分支断言的是 `"code":"denied"` + 退出码 2;07 票产出的是 `confirmation_unavailable` + 退出码 2
   (**因为那时根本没有确认器,不存在「用户点了拒绝」**)。**08 票补上 `confirmation_denied` 之后,那条旧断言
   有了真正的对位物**(▸ add 被确认器拒绝),两条并存:同一条能力,无人在场与有人不同意是两种收场,
   各有各的报文与指引。退出码不变,旧的退出码判据不受影响。

---

## 13 票收口:顺延 13 的 7 条逐条销账(2026-08-05)

10 票收口时表内还剩 15 条未兑现的顺延,其中 **7 条挂在 13 票(分发工件)**。本节逐条落定 ——
**全部兑现,一条不留**。

| # | 原表位置 | 旧断言 | 新落点(可跑的那条) |
|---|---|---|---|
| 1 | 04 票 C 组 | `aa docs agents-md` 含 capabilities / dangerous / exit code 三段接入片段 | **改判为文档 + 对账断言**:指引物是 `docs/agents/a2-cli.md`(命令形态随 `aa` 退场);`docs-agent-guide.test.ts` ▸ 退出码表与 `exit-codes.ts` 逐值对得上 / ▸ dangerous 三条收场与「无 `--yes` 旁路」都写明 |
| 2 | 07 票 G 组 FS5 | `aa docs agents-md` 提到的能力 id 都真实存在 | **映射(判据更强)**:`docs-agent-guide.test.ts` ▸ 指引里提到的每一个能力 id,在**真的跑着的内核**(起 daemon 取 `capabilities list`)里都存在。旧断言对的是同进程的清单,新断言对的是活体注册表 |
| 3 | 10 票 D 组 组 5(8 条) | 接入片段逐条 grep(prefix_rule / require_escalated / capabilities call / **pending** / exit code) | **部分映射 + 部分淘汰**:能力调用、退出码、dangerous 口径映射到上面两条;`capabilities result <request-id>` 与 `"pending":true` **已作废**(pending 态整体淘汰,见「有意的契约变更」6),故不重写、反而立了一条**反向断言**:▸ 已作废的旧接入片段不许出现在指引里 |
| 4 | 10 票 F 组 FS5 | 同 #2(F 组重复登记的那一行) | 同 #2 |
| 5 | 07 票 H 组 | `proxy.license` 能力(GPL 义务经能力面暴露) | **改判为 CLI 子命令**:`a2 about`(**不经 daemon** —— 义务落点不许依赖一个可能没装、没跑的进程)。`cli-about.test.ts` ▸ GPL 义务:声明里有外部程序、许可证、源码获取地址与发布渠道 / ▸ 不依赖 daemon:一个字节的状态都不写 |
| 6 | 10 票 C 组 APP-9 | `aa proxy license` 报出的内核版本与 `MIHOMO-VERSION.txt` 一致 | **映射**:`cli-about.test.ts` ▸ 锁版同源:about 报的 mihomo 版本 = `MIHOMO-VERSION.txt` 里那一版(期望值从那份实测记录现读,不经 `pin.ts`);另有 `release-manifest.test.ts` ▸ mihomo 锁定版进元数据且与实测记录同源 —— 06 票安装档的版本源自此在**发布元数据**里也有一份 |
| 7 | 10 票 C 组 APP-10 | 子进程红线原文经能力面暴露 | **映射(落点换成 `a2 about` 的静态文本)**:`cli-about.test.ts` ▸ 独立子进程红线的原文出现在声明里(断言逐字含「独立子进程」「永不进程内链接」),而同一份字节随发布包落成 `NOTICE-external-programs.txt`(`release-assemble.sh` 的自检确认包里那个 a2 看得见它) |

**顺带说明两条本节没有、也不该有的账**:
* 10 票 B 组 MB-6(两个 `#if AA_TESTING` env seam「13 票分发前须处置」)**在 10 票就已销账** ——
  新壳里一个测试专用 seam 都没有,本票无事可做;
* 10 票 D 组第 6 行(`aa install-cli` 约 12 条)是**淘汰**不是顺延,但它那句"安装脚本的断言归 13 票"
  本票兑现了:`kernel/test/install-script.test.ts`(16 条,平台探测 / 摘要校验 fail-closed / 幂等 /
  升级显式 / PATH 提示 / 卸载先看后删)。

### 13 票自己的新账(不属旧断言的去向,不进上面的统计)

| 面 | 断言落点 |
|---|---|
| `a2 about`(GPL 义务) | `cli-about.test.ts` 13 条 + 金标样本 `about-result.json` / `invalid-about-bundled-gpl-binary.json`(`bundled` 恒 false 是契约层的承诺) |
| 安装脚本 | `install-script.test.ts` 16 条(被测体是真的 `Scripts/install.sh`,渠道是回环 `Bun.serve` 与本地目录两种夹具) |
| 发布元数据与组装脚本 | `release-manifest.test.ts` 14 条(结构约束 / 摘要对照系统 `shasum` / 每工件一行的格式约定 / TS 与 `install.sh` 的两处字面量对账 / 组装脚本真跑一遍 + 真产物自检) |
| agent 指引物 | `docs-agent-guide.test.ts` 7 条(见上表 #1–#4) |

**全表统计更新**:22 条顺延中 **已兑现 14 条**(顺延 07 五条 + 顺延 10 两条 + **顺延 13 七条**),
未兑现 8 条(全部是 agent-delegation,排期未定,去处不是本效应的票)。
