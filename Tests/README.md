# Tests/ —— swift-testing 用例(17 票起是本仓库单元/域断言的唯一落点)

## ⚠️ 先读这条:**裸跑 `swift test` 没有清场网**

`Tests/AAAgentTestKitTests/SystemAgentPortTests.swift` 会起**真进程**(`/bin/sh`、`cat`、`yes`,
以及唯一时长的 `sleep 87137`)。

* 经 `bash Scripts/check.sh` 跑时是安全的:`Scripts/check/bootstrap.sh` 装了 `trap cleanup EXIT`,
  `cleanup()` 里有 `pkill -f "sleep 87137"` —— 即使用例中途崩了、门禁被 Ctrl-C 了,残留进程也会被清掉。
* **直接手敲 `swift test` 时那层网不存在。** 如果用例在 `terminate` 之前被打断,
  `sleep 87137` 会留在你的机器上(约 24 小时后才自己退)。

所以:

```bash
# 推荐:走门禁(自带清场)
bash Scripts/check.sh

# 如果一定要单跑,跑完请自己收尾:
pkill -f "sleep 87137"
```

（`87137` 是刻意选的唯一时长,`pkill -f` 按它匹配不会误伤你机器上别的 `sleep`。
反孤儿探针另用 `87139`,同理。）

## 怎么跑

本机工具链(`~/Library/Developer/Toolchains/swift-latest.xctoolchain`)**不带 XCTest**,
故必须显式禁掉它、点名 swift-testing:

```bash
swift test --disable-xctest --enable-swift-testing --no-parallel
```

`--no-parallel` 不是可选装饰:`SystemAgentPortTests` 碰真进程/真信号,并有一条按耗时判定的
阻塞语义断言,并行会让它变得不确定。门禁(`Scripts/check/swift-test.sh`)也是这么跑的。

两个适配层套件读 01/02 spike 落盘的真实样本,路径经环境变量注入(缺失即 fail-closed,不静默跳过):

```bash
AA_SPIKE_DIR="$PWD/.scratch/agent-delegation/research" swift test --disable-xctest --enable-swift-testing --no-parallel
```

## target 布局

| target | 内容 | 备注 |
| --- | --- | --- |
| `AAContractsTests` | 退出码锁定表 | 11 票的 swift-testing 试点 |
| `AAHostTestKitTests` | Registry / Proxy / SystemProxy / CrashRecovery / Subscription / MenuModel 六套 | 全纯逻辑,假件驱动 |
| `AAAgentTestKitTests` | AgentCore / ClaudeAdapter / CodexAdapter / AgentTask / Watchdog / LaunchAssembler / SystemAgentPort 七套 | **最后一套碰真进程** |

**假件不在这里**:`ProxyFakes` / `NetworkConfigFakes` / `SelfHealFakes` / `SubscriptionFakes` /
`MenuFixtures` 仍住在 `Sources/AAHostTestKit/`,`FakeAgentPort` / `FakeTaskPorts` 仍住在
`Sources/AAAgentTestKit/`。理由是硬约束而不是偏好:它们还有**可执行**消费者
(`menu-snapshot` 用 `MenuFixtures`,`registry-tests` 用 `SystemAgentPortOrphanProbe`),
而 SPM 的 `executableTarget` 不能依赖 `testTarget`。

## 改用例名之前请先读这条

`Scripts/check/unit-and-domain.sh`(96 条)与 `Scripts/check/menubar.sh`(2 条)一共 **98 条**
`assert_contains` 直接 grep `swift test` 的输出文本,而它们 grep 的**就是这些 `@Test` 的名字**
(17 票迁移时逐字取自旧的手写断言文案)。

* 改一个被 grep 的 `@Test` 名 = 改门禁 → 必须同步改 `Scripts/check/*.sh` 里对应那条。
* `@Suite` 名里那些看着奇怪的 `XXX_TESTS passed=` 标记同理:旧 runner 打印过这样的汇总行,
  shell 侧拿它当「本套件确实跑了」的证据;迁移后由 `✔ Suite "…" passed` 承担,标记原样嵌在套件名里。
* `MenuModelConformanceTests` 里两行 `print("MENUBAR_ASSERT1/2: ok=…")` 也是门禁 grep 的目标,
  别当调试残留删掉。
