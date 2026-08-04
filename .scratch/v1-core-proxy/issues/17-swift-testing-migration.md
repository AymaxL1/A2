# 17 — swift-testing 全量迁移

**What to build:** 把 `Sources/AAHostTestKit/` 与 `Sources/AAAgentTestKit/` 里手写 `TestReport` 断言搬进 `Tests/`,
改写为 swift-testing 的 `#expect`,由 `swift test` 驱动。**行为不变、断言覆盖面不减**是硬约束。

**Blocked by:** 11(已解除)。

**Status:** done —— `bash Scripts/check.sh` 连跑两次 **PASS=429 FAIL=0 rc=0**(与迁移前基线逐数字相同)。

**验证环:** `bash Scripts/check.sh`。工具链同 11 票:`~/Library/Developer/Toolchains/swift-latest.xctoolchain`,**不需要 Xcode.app**。

---

## 一、落地结果(逐条 checkbox 的真实状态)

- [x] 九套断言全部搬进 `Tests/` 并改写为 `#expect` / `#require` / `Issue.record`,**逐条对应,无删减**
      —— 机械核验见「三、断言数对齐的证据」。
- [x] 两份手写 `TestReport` 框架已删除(`Sources/AAHostTestKit/AAHostTestKit.swift` 里的 `TestReport`、
      `Sources/AAAgentTestKit/AgentTestReport.swift` 里的 `AgentTestReport`)。**迁移后确认零调用方**。
- [ ] ~~`Sources/registry-tests/` 及其 `.executableTarget` 已删除~~ —— **刻意不做,票面这条改判**。
      理由见「四、`registry-tests` 为什么必须留」。这是本票**唯一一处与原票面写法相反的决定**。
- [ ] ~~迁移后 `swift test` 的**用例数 ≥ 迁移前九套的断言条数之和**(基线 `ALL_UNIT passed=721`)~~
      —— **判据改写**。实际是 **182 个 `@Test` / 800 个断言点**。原判据把「用例数」当成「断言数」的同义词,
      而 swift-testing 里一个 `@Test` 天然承载多条 `#expect`;真正要守的是**断言点不减**(800 ≥ 790,见下)。
      硬凑到 721 个 `@Test` 只会毁掉「一个用例 = 一个可独立复现的场景」这件事。
- [x] `bash Scripts/check.sh` **FAIL=0、rc=0**;门禁总断言数 **429 → 429,一条不减**。
- [x] 行为不变:没有任何一条断言的判据被弱化。
  ⚠️ **措辞更正(双轴 CR 抓到)**:此处原写「每条 `#expect` 的条件表达式与旧 `report.check` 的第一参数**逐字相同**」——
  **说过头了**。抽样可见变量因 scenario 助手重构而改名(例:`r.decision` → `s.result.decision`),
  **语义相同、字面不同**。准确的说法是:**判据的语义逐条未弱化**,而不是字面逐字相同。
  支撑证据是三条机械核验(逐文件断言点不减 + 826 条中文文案逐字反查 + 98 条 shell grep 逐条命中),
  不是「字面一致」。
- [x] `Scripts/check.sh` 的接口契约不变:一条命令、非零退出即失败。

### 两次门禁(连跑,确认稳定)

| | PASS | FAIL | rc | 墙钟耗时 |
| --- | --- | --- | --- | --- |
| 迁移前基线 | 429 | 0 | 0 | ≈118 s |
| 第 1 次 | **429** | **0** | **0** | **2 m 08.98 s** |
| 第 2 次 | **429** | **0** | **0** | **2 m 03.49 s** |

慢了约 **6–11 秒**(+5 ~ +9%)。来源已定位,不是玄学:
① `swift test` 现在要多编译两个 test target;
② `--no-parallel`(见「五」)让真进程那套严格顺序跑;
③ 旧 runner 那十几秒被 `swift test` 的 5.9 秒取代 —— 这一项其实是**变快**的,只是被 ① 抵消。

两次的「用户自己的 mihomo 未被碰到」守卫原文(pid 553 是用户此刻的上网通道):

```
PASS: 未触碰仓库外的 mihomo 进程(跑前后一致: [553 ])      ← 第 1 次
PASS: 未触碰仓库外的 mihomo 进程(跑前后一致: [553 ])      ← 第 2 次
```

`swift test` 那条:`PASS: swift test 全绿 —— ✔ Test run with 182 tests passed after 5.9 seconds.`

---

## 二、98 条 shell 断言:**一个字都没改**

`Scripts/check/unit-and-domain.sh`(96 条)+ `Scripts/check/menubar.sh`(2 条)一共 98 条
`assert_contains` 直接 grep runner 的输出文本。做法与票面预定的一致:

**每条被 grep 的旧断言文案,原样取作某个 `@Test` 的名字。** swift-testing 会把用例名打进
`swift test` 的输出(`◇ Test "…" started.` / `✔ Test "…" passed`),于是那 98 条 grep 原样继续成立。

机械核验(不是肉眼看的):把 98 条 grep 目标串从两个 shell 文件里抽出来,逐条 `grep -F` 真实的
`swift test` 输出 —— **0 条缺失**。

三类特殊目标的处置:

| grep 目标 | 旧来源 | 新来源 |
| --- | --- | --- |
| 86 条断言文案 | `TestReport.check` 打的 `PASS: <文案>` | `@Test("<同一文案>")` 的用例名 |
| `PROXY_TESTS passed=` 等 8 条套件汇总标记 | runner 末尾的 `print` | 嵌进 `@Suite("… XXX_TESTS passed=(逐条 @Test)")` 的套件名 —— `✔ Suite "…" passed` 是比旧汇总行**更强**的证据(它同时证明套件跑完且全绿) |
| `MENUBAR_ASSERT1/2: ok=1` 2 条结论行 | `TestReport.note(...)` | `MenuModelConformanceTests` 里直接 `print(...)`;`ok=` 仍由逐条断言累加,不是写死的 1 |
| `failed=0` 1 条 | runner 的 `ALL_UNIT passed=N failed=M` | `Scripts/check/swift-test.sh` 把 swift-testing 自己的收尾行**翻译**成同格式的一行 |

最后那条是本票唯一一处「shell 侧新增了产出」,必须说清它**不是凭空造事实**:
- 它只是把 `✔ Test run with 182 tests passed` 换算成旧格式;
- 而且是 **fail-closed**:`swift test` rc≠0、或汇总行解析不出数字,就**不追加这一行** →
  `assert_contains "$OUT" "failed=0"` 当场红。绝不会出现「跑挂了却因为拿不到数字而静默算过」。
- 已实测:原始 `swift test` 输出里 `failed=0` 出现 **0** 次,所以这条断言只能靠那条派生行满足,不存在误命中。

`unit-and-domain.sh` 只改了**开头三行**(第 3 行 `$OUT` 的来源、那行整份输出刷屏的 `printf`、
一条 `assert_exit` 的描述串),96 条 `assert_contains` 一个字节没动。`menubar.sh` 完全没动。

---

## 三、断言数对齐的证据(最大的风险是静默丢断言)

三条互相独立的核验,全部机械跑出来:

**① 断言调用点计数(静态)**

| 旧文件 | 旧断言点 | → 新文件 | 新断言点 |
| --- | --- | --- | --- |
| `AAHostTestKit.swift`(Registry) | 57 | `RegistryConformanceTests.swift` | 58 |
| `ProxyConformanceTests.swift` | 58 | 同名 | 60 |
| `SystemProxyConformanceTests.swift` | 43 | 同名 | 45 |
| `CrashRecoveryConformanceTests.swift` | 56 | 同名 | 56 |
| `SubscriptionConformanceTests.swift` | 52 | 同名 | 53 |
| `MenuModelConformanceTests.swift` | 28 | 同名 | 28 |
| `AAAgentCoreConformanceTests.swift` | 33 | 同名 | 34 |
| `ClaudeAdapterTests.swift` | 47 | 同名 | 48 |
| `CodexAdapterTests.swift` | 63 | 同名 | 64 |
| `AgentTaskTests.swift` | 153 | 同名 | 154 |
| `AgentWatchdogTests.swift` | 73 | 同名 | 73 |
| `AgentLaunchAssemblerTests.swift` | 77 | 同名 | 77 |
| `SystemAgentPortTests.swift` | 50 | 同名 | 50 |
| **合计** | **790** | | **800** |

口径:旧侧数 `report.check(` 调用点(`MenuModelConformanceTests` 数它的局部 `check(` 助手调用点,
不数助手体内那 2 条实现);新侧数 `#expect(` + `#require(` + `Issue.record(`
(`MenuModelConformanceTests` 同样数局部 `check(` 调用点 —— 它的助手体内是 `#expect`)。
另有 11 票试点 `AAContractsTests` 的 15 条,不在本表(不是本票搬的)。

**没有任何一个文件低于它的旧计数。** 多出来的 10 条全是「旧代码一个
`guard … else { check(false, …); return }` 在新写法里被拆成两个用例、各自要一次 `#require` 前置」
这类,逐条可指认,不是灌水。

**② 逐条文案反丢失(最硬的一条)**

从旧文件里抽出**全部含中文的字符串字面量** 826 条(断言文案全是中文;JSON 桩全是 ASCII,天然被排除),
逐条在新的 `Tests/` 树里做逐字查找 —— **只有 1 条找不到**:

```
FAIL: SystemAgentPort 测试整体超时(\(Int(seconds)) 秒)—— 某处读流阻塞未解
```

它不是断言,是看门狗超时时打的诊断行;因为看门狗从「整套件一个」改成「逐用例一个」(理由见「五」),
措辞相应改成 `SystemAgentPort 用例「<tag>」超时(<n> 秒)`。**这是唯一一条被改写的旧文本,如实记在这里。**

**③ 门禁总数**:429 → 429。`swift test` 仍只记 1 条(口径与 11 票一致,见「五」)。

**⚠️ 一处如实登记的可观测性损失**:旧 runner 会打 `ALL_UNIT passed=721 failed=0` —— 那是**运行时**执行到的
断言条数。swift-testing 只报用例数(182),不报 `#expect` 的执行次数。于是「某个用例中途 `return` 了、
后面几条 `#expect` 没跑到」这种情况,**没有一个数字会变**。现在挡这件事的是那 98 条 shell grep
(它们盯的是用例是否真的跑到并通过)。这不是本票引入的新洞(旧代码里 sub-function 提前 return 同样只是让
`passed=` 少几个、没人会盯),但迁移后失去了那个数字,应当记下来。

---

## 四、`registry-tests` 为什么必须留(与原票面相反的决定)

原票面写「九套搬完即可删 `Sources/registry-tests/` 与它的 `.executableTarget`」。**这条做不得**,理由是硬的:

`Scripts/check/agent-e2e.sh` 拿它当**反孤儿信号探针**的宿主:

```sh
PROBE_OUT="$(AA_ORPHAN_PROBE=exit "$TESTRUNNER" 2>&1)"         # 证明 atexit 钩子回收整个进程组
AA_ORPHAN_PROBE=signal "$TESTRUNNER" >"$SIGPROBE_LOG" 2>&1 &   # 证明 SIGTERM 钩子同样回收
```

这件事**在测试进程内根本验不了**:它要求宿主真的死一次(exit / 被 SIGTERM 杀),
而 `swift test` 的宿主进程一旦中途 `exit`,整轮测试就没了。SPM 的 `executableTarget` 又不能依赖 `testTarget`。

所以:

- `Sources/AAAgentTestKit/SystemAgentPortOrphanProbe.swift` —— 探针本体从
  `SystemAgentPortTests.swift` 里拆出来,留在 Sources/。**逻辑逐字一致;差异只有少了 2 行注释**
  (原说法「一行逻辑没改」为真,但「原样」二字掩盖了那 2 行注释的丢失,双轴 CR 抓到,在此说准)。
- `Sources/registry-tests/main.swift` —— 重写成只做一件事:有 `AA_ORPHAN_PROBE` 就跑探针;
  **没有就以 rc=2 退出并打印用法**。刻意非零:哪天有人把它当「跑单元测试」用,必须当场红,
  而不是静默地「全绿地什么都没跑」。
- `Package.swift` 里 `registry-tests` 的 `.executableTarget` **保留**(断言组 3f 的依赖闭包守卫会遍历
  executableTarget 清单;删了它那条守卫的覆盖面就悄悄缩小了),依赖边收窄成 `["AAAgentTestKit"]`
  —— 与 main.swift 的实际 import 一一对应。

同理,**假件不搬进 `Tests/`**:`ProxyFakes` / `NetworkConfigFakes` / `SelfHealFakes` / `SubscriptionFakes` /
`MenuFixtures` 留在 `Sources/AAHostTestKit/`,`FakeAgentPort` / `FakeTaskPorts` 留在 `Sources/AAAgentTestKit/`。
这不是偏好而是约束:`menu-snapshot`(可执行)要用 `MenuFixtures` 的三态渲染快照,`registry-tests`(可执行)
要用探针 —— 而 executableTarget 不能依赖 testTarget。搬进 Tests/ 会直接把这两个可执行打断。

---

## 五、三个环境耦合套件的处置

**① / ② `ClaudeAdapterTests` / `CodexAdapterTests`(读 `AA_SPIKE_DIR`)**

它们喂的是 01/02 spike 真调 agent 落盘的 NDJSON 样本 —— 单一真相源,不许复制成 Swift 常量。
注入点从 `unit-and-domain.sh`(调 registry-tests 时)搬到 `Scripts/check/swift-test.sh`
(以**命令前缀**的形式只给 `swift test` 那一条命令,刻意不 `export` 到全局,免得污染后续 E2E 组的环境),
路径不变:`$ROOT/.scratch/agent-delegation/research`。

**「缺失即 fail-closed」的设计一字未改**,而且落点更严:
- 目录变量缺失 → `#require(…, "…AA_SPIKE_DIR 已注入(缺失即 fail-closed)")` 抛出,用例红;
- 样本目录不存在 → 专门一个 `@Test` 断言它存在;
- 样本文件读不出 → `#require(FileManager.default.contents(atPath:), "…黄金样本可读 —— <name>(读不出即 fail-closed)")`。

绝不静默跳过 —— 「全绿地什么都没测」比红更危险,这条口径原样继承。

**③ `SystemAgentPortTests`(起真进程,唯一时长 `sleep 87137`)**

- **仍在门禁的清场网内**(已核实):`swift test` 是从 `check.sh` 里调起的,`bootstrap.sh` 的
  `trap cleanup EXIT` 覆盖它,`cleanup()` 里有 `pkill -f "$AGENT_SLEEP_SUITE"`(即 `sleep 87137`)。
  两次门禁跑完 `pgrep -f "sleep 87137"` 均无残留,`finalize.sh` 的「无残留 agent 被测子进程」也是绿的。
- **⚠️ 裸跑 `swift test`(不经门禁)没有这层网。** 这条写进了三处,免得日后有人踩:
  `Tests/README.md` 顶部第一节、`Tests/AAAgentTestKitTests/SystemAgentPortTests.swift` 文件头、
  以及 `Package.swift` 里该 testTarget 的注释。收尾办法:`pkill -f "sleep 87137"`。
- **看门狗从「整套件 120 秒」改成「逐用例 60 秒」**:旧实现在 `run()` 里起线程、跑完 `markFinished()`;
  swift-testing 下没有「整套件跑完」这个时刻。语义(挂死 → 打 FAIL 并 `exit(9)`,让门禁**失败**而不是挂死)
  一字未变,只是粒度更细、暴露更早。`exit(9)` 会触发端口的 atexit 反孤儿钩子,残留进程随之被 SIGKILL。

### 其它三条口径(与票面预定一致)

- **`swift test` 在门禁里仍只记 1 条断言**(整体绿/红)。用例级细节由那 98 条 shell grep 承担。
  不拆成几百条 PASS —— 那会让「PASS 总数」这个粗粒度回归信号失效,也与 11 票定的口径冲突。
- **`--no-parallel`(新增)**:swift-testing 默认并行,而 `SystemAgentPortTests` 碰真进程/真信号、
  还有一条按耗时判定的阻塞语义断言。旧 runner 是严格顺序的,这里保持同一语义 —— 门禁稳定性优先。
- **`Package.swift` 的铁律没被破**:两个新 testTarget 的依赖边与各自文件的实际 `import` 一一对应;
  `AAUISystem` 依赖边未动;`PluginProxy` 依赖边未动(断言组 3 / 3a / 3b / 3b2 / 3f 全绿)。
  顺带按同一口径收窄了两处**空头依赖**:`AAAgentTestKit` 去掉 `AAContracts`(剩下三个文件一行都没 import),
  `registry-tests` 去掉 `AAHostTestKit`(main.swift 不再 import 它)。

---

## 六、改动清单

**新增**
- `Tests/AAHostTestKitTests/`(6 文件,87 `@Test`):Registry / Proxy / SystemProxy / CrashRecovery / Subscription / MenuModel
- `Tests/AAAgentTestKitTests/`(7 文件,89 `@Test`):AgentCore / ClaudeAdapter / CodexAdapter / AgentTask / Watchdog / LaunchAssembler / SystemAgentPort
- `Tests/README.md`:跑法、「裸跑没有清场网」警告、target 布局、**「改 `@Test` 名 = 改门禁」**的告示
- `Sources/AAAgentTestKit/SystemAgentPortOrphanProbe.swift`:探针从旧套件里原样拆出

**删除**(共 4 551 行断言 + 2 份手写框架)
- `Sources/AAHostTestKit/`:`AAHostTestKit.swift`(含 `TestReport`)、`ProxyConformanceTests` /
  `SystemProxyConformanceTests` / `CrashRecoveryConformanceTests` / `SubscriptionConformanceTests` / `MenuModelConformanceTests`
- `Sources/AAAgentTestKit/`:`AgentTestReport.swift`(含 `AgentTestReport`)、七套断言文件

**修改**
- `Package.swift`:加两个 testTarget;`AAAgentTestKit` / `registry-tests` 的依赖边收窄;三处注释说明 17 票后的角色
- `Scripts/check/swift-test.sh`:export `AA_SPIKE_DIR`;加 `--no-parallel`;导出 `$SWIFT_TEST_OUT` 供下游 grep;
  派生 `ALL_UNIT passed=N failed=0`(fail-closed);T2 零警告把 `swift-test.log` 也纳入
  (`swift build` 默认不建 test target,不纳入的话 `Tests/` 里的警告永远查不到)
- `Scripts/check/unit-and-domain.sh`:只改开头三行。**96 条 `assert_contains` 一字未动。**
- `Sources/registry-tests/main.swift`:只剩反孤儿探针入口,误用即 rc=2

---

## 七、没做到 / 绕过的事(如实记)

1. **原票面「删掉 registry-tests」这条没做**,而且是**故意**的 —— 理由见「四」。这是与票面写法相反的唯一一处。
2. **原票面「用例数 ≥ 721」这条没做**,判据被改写成「断言点 800 ≥ 790 且逐条文案零丢失」—— 理由见「一」。
3. **运行时断言条数不再可见**(旧的 `ALL_UNIT passed=721`),见「三」末尾的登记。
4. 一条旧诊断文案被改写(看门狗超时行),见「三②」。
5. 门禁慢了 6–11 秒。
6. ~~**有一条断言现在是重复的**~~ —— **已由主会话解决,方式不是删掉而是换掉**。

   实施阶段的处置是:`unit-and-domain.sh` 开头那条 `assert_exit 0 $RC` 与断言组 T 盯同一个 rc,
   属重复,但**刻意没删**,理由是「删了 PASS 会变 428,而『不减』是硬约束」。
   —— 这个理由不成立:**为了保住一个数字而留一条冗余断言,那条断言除了让 PASS 好看之外没有价值**,
   等于用「不减」这条纪律换来了一格假充实。

   主会话把它**换成一条真有价值的**:**swift test 用例数棘轮**(下限 182)。
   它补的正是本票造成的那条真实损失(下面第 3 条):旧 runner 打 `ALL_UNIT passed=721`,
   断言没跑到那个数就会掉;swift-testing 只报用例数,于是「用例中途 return、后面的 `#expect`
   根本没执行」不再有任何数字会变。棘轮**挡不住**用例内部少执行几条 `#expect`(那层只能靠 96 条 grep 兜),
   但挡得住更粗也更常见的那种:**整个 `@Test` 被删掉、被禁用、或整个文件没编进去**。

   **已做变异测试**:把棘轮临时调到 999 → `FAIL: swift test 用例数 182 < 棘轮下限 999`,
   门禁 `PASS=428 FAIL=1`,**总条数仍是 429**(那一格从 PASS 翻成 FAIL,没有漂)。断言证明过自己会红。
   棘轮值随后还原为 182。要调低这个数必须是有意为之并在代码处说明理由 —— 那正是要拦的动作。
7. 本票**未 commit**(按委托要求),改动全部留在工作区。
