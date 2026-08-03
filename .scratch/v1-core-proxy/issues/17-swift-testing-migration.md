# 17 — swift-testing 全量迁移

**What to build:** 把 `Sources/AAHostTestKit/` 与 `Sources/AAAgentTestKit/` 里约 **5500 行**手写 `TestReport` 断言搬进 `Tests/`,改写为 swift-testing 的 `#expect`,由 `swift test` 驱动;搬完即可让门禁生成的 `registry-tests` 可执行退役。**行为不变、断言覆盖面不减**是硬约束。

**Blocked by:** 11 —— 11 票已把 `swift build` + `swift test` 接进门禁,并用 `Tests/AAContractsTests/` 做完试点(证明这条路走得通)。本票是把试点铺开。

**Status:** ready-for-agent

**验证环:** `bash Scripts/check.sh`(唯一红绿循环入口,一条命令、非零退出即失败)。工具链同 11 票:`~/Library/Developer/Toolchains/swift-latest.xctoolchain`,**不需要 Xcode.app**。

## 11 票留下的起点(接手时不必重跑)

- `Tests/AAContractsTests/ExitCodeContractTests.swift` 是已跑绿的试点(6 个 `@Test` / 18 个参数化用例),写法照它抄。
- `Scripts/check/swift-test.sh` 已把 `swift test --disable-xctest --enable-swift-testing` 接进门禁,**只记 1 条断言**(整体绿/红)。
  `--disable-xctest` 是必需的:本机独立工具链不带 XCTest。
- 现状:9 套断言由 `Sources/registry-tests/main.swift`(11 票固化的真 target)串行驱动,把结果 print 到 stdout,
  再由 `Scripts/check/unit-and-domain.sh` 用 `assert_contains` **grep 那些逐字文本**判定。
  → 这就是本票最大的坑:迁移会改掉那些 print,下游 grep 会成片变红。见下面「迁移顺序」。

## 待迁移清单(9 套)

`Sources/AAHostTestKit/`
- `AAHostTestKit.swift`(`RegistryConformanceTests`:注册表纯逻辑 + dangerous 三分支)
- `ProxyConformanceTests.swift`(Port 假件 / RESTClient / `proxy.status` 域逻辑)
- `SystemProxyConformanceTests.swift`、`CrashRecoveryConformanceTests.swift`、`SubscriptionConformanceTests.swift`
- 假件:`ProxyFakes.swift` / `NetworkConfigFakes.swift` / `SelfHealFakes.swift` / `SubscriptionFakes.swift`

`Sources/AAAgentTestKit/`
- `AAAgentCoreConformanceTests.swift` / `ClaudeAdapterTests.swift` / `CodexAdapterTests.swift` /
  `AgentTaskTests.swift` / `AgentWatchdogTests.swift` / `SystemAgentPortTests.swift` / `AgentLaunchAssemblerTests.swift`
- 假件:`FakeAgentPort.swift` / `FakeTaskPorts.swift`
- `AgentTestReport.swift`(手写框架本体,迁完即可删)

## 明确**搬不动**的部分(留在 `Scripts/check/`,别硬搬)

这些断言的被测对象是「真进程 / 真 socket / 真二进制的可观测行为」,不是 Swift 里可调用的纯逻辑:

- **进程级**:宿主起停、`SIGUSR1` 优雅退出、反孤儿(内核 / agent 子进程树零残留)、`pkill`/`pgrep` 清场核验 —— `proxy-e2e.sh` / `finalize.sh`。
- **UDS 级**:裸 socket 直连构造请求证明「不可绕过确认层」、宿主不可达退出码 4、超时(假监听器)—— `capabilities-e2e.sh`。
- **E2E / CLI 级**:`aa` / `aa-agent` 的退出码与 stdout 逐字节契约、`install-cli`、`docs agents-md`、
  域子命令 ≡ `capabilities call` 的逐字节一致性 —— `architecture-and-cli.sh` / `capabilities-e2e.sh` / `agent-e2e.sh`。
- **真内核 E2E**:锁版 mihomo 启动 / REST / 生产宿主全链 —— `mihomo-real-e2e.sh`。
- **架构守卫**:PluginProxy 的源码 grep(3a)与清单依赖边检查(3b)—— `architecture-and-cli.sh`。
- **未污染真实 AppSupport 的 md5 快照比对** —— `bootstrap.sh` + `finalize.sh`。

判据一句话:**要起真进程 / 碰真 socket / 读真二进制输出的,留在 shell;纯逻辑 + 假件驱动的,搬进 `Tests/`。**

## 迁移顺序(避免中途成片变红)

`registry-tests` 的每个 print 都被 `unit-and-domain.sh` grep,一次全搬会让下游断言成片失效。按套逐个搬:

1. 选一套(建议从 `AAAgentCoreConformanceTests` 起 —— 纯逻辑、无假件耦合)。
2. 在 `Tests/` 建对应 test target,断言改 `#expect`,**语义逐条对应**,不许顺手合并或删减。
3. 把 `Sources/registry-tests/main.swift` 里该套的调用与 print 删掉,同时把 `unit-and-domain.sh` 里针对它的 `assert_contains` 删掉。
4. 跑门禁,确认 **总断言数不减**(swift test 那条仍只记 1 条,故 shell 侧减掉几条就要在别处能解释清楚 —— 见验收)。
5. 九套全搬完后,删掉 `Sources/registry-tests/`、`Package.swift` 里对应的 `.executableTarget`、两份 `*TestReport.swift` 框架,
   以及 `unit-and-domain.sh` 里最后的残留。

## 验收

- [ ] `Sources/AAHostTestKit/` 与 `Sources/AAAgentTestKit/` 的断言全部搬进 `Tests/` 并改写为 `#expect`,**逐条对应,无删减**
- [ ] `Sources/registry-tests/` 及其 `.executableTarget` 已删除;两份手写 `TestReport` 框架已删除
- [ ] 迁移后 `swift test` 的**用例数 ≥ 迁移前 9 套的断言条数之和**(用迁移前 `registry-tests` 输出的 `ALL_UNIT passed=N` 作基线,写进本票)
- [ ] `bash Scripts/check.sh` **FAIL=0、rc=0**;门禁总断言数不减(shell 侧减掉的条数须逐条在本票记录去向)
- [ ] 行为不变:任何一条断言的**语义**都没有被弱化(不许把「精确相等」降成「包含」之类)
- [ ] `Scripts/check.sh` 的接口契约不变:一条命令、非零退出即失败
