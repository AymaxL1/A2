# Tests/ —— swift-testing 用例(壳侧断言的唯一落点)

10 票「壳原子切换」之后,本目录只剩 **a2 系**四套:旧的 `AAContractsTests` /
`AAHostTestKitTests` / `AAAgentTestKitTests`(182 条)随旧 Swift 逻辑面整族退场,
每一条的落定(映射 / 合并 / 淘汰 / 顺延)逐条写在 [`kernel/test/swift-parity-map.md`](../kernel/test/swift-parity-map.md)
的「10 票收口」一节。

## 怎么跑

```bash
bash Scripts/check.sh        # 推荐:门禁四件套(swift test 是其中第②件)
```

单跑壳侧那部分:

```bash
swift test --no-parallel
```

本机工具链(`~/Library/Developer/Toolchains/swift-latest.xctoolchain`)不带 XCTest,
必要时显式点名 swift-testing:`swift test --disable-xctest --enable-swift-testing --no-parallel`。

`--no-parallel` 不是可选装饰,两条理由:

* **壳快照要在主 actor 上做离屏渲染**,并行调度下渲染与断言的时序会变得不确定;
* 09 票撞过一次真的并行 flake(假内核跑在全局队列上、被并行用例的 sleep 占住线程池),
  修法是给假内核一条专用 `Thread` + 按判据差给余量,但门禁口径仍取 `--no-parallel`。

**这批用例不起任何进程、不碰真实 `~/.a2`、不发一条真网络请求**,所以裸跑是安全的
(唯一沾边的是 03 票那条看门狗用例:它建一个真的 `A2PanelSession`,socket 指向临时目录下一个
**不存在**的路径 —— 连接当场失败,既不起进程也不碰用户的内核,1.5s 后由看门狗收场)
(17 票时代那条「`sleep 87137` 会留在你机器上」的警告随 `AAAgentTestKitTests` 一起退场)。
起真 daemon 的那一关在 `Scripts/a2-flagship-e2e.sh`(门禁第③步),它自带 trap 清场。

## target 布局

| target | 内容 | 备注 |
| --- | --- | --- |
| `A2ContractTests` | 契约金标的 **Swift 半边**:范围对账 / 合法样本往返 / 非法样本必拒 / 封闭词表对账 / 可选字段松紧 | 读 `kernel/contract/golden/` 的同一批样本 |
| `A2KernelClientTests` | UDS 客户端的协议逻辑:字节级拆行 / id 相关 / 推送分流 / pending 顺延 | 假内核用 `socketpair()` 现造 |
| `A2PanelTests` | 壳纯逻辑:菜单覆盖面与可追溯性 / 四态如实反映 / 六族事件投影 / 确认原样呈现 / URL 转发与降级兜底(03 票四条硬边界,含源码级反向断言) | 零 AppKit |
| `A2PanelSnapshotTests` | **壳快照**:渲染器 B 离屏渲染 × 入库 golden(像素 + 模型文本) | 要 AppKit,`@MainActor` |

**固定装置不在这里**:`A2PanelFixtures` 住在 `Sources/`。理由是硬约束而不是偏好 ——
它还有**可执行**消费者(`a2-panel-snapshot` 重录 golden、`a2-panel-probe` 跑旗舰 e2e),
而 SPM 的 `executableTarget` 不能依赖 `testTarget`。

## 两条与门禁的隐形契约(改之前先读)

1. **golden 路径由 `#filePath` 推仓库根**,不经环境变量注入 —— 于是这批断言在任何 `swift test`
   下都成立,门禁脚本不必喂路径。代价是测试文件不能随便挪位置(挪了要同步改那段推导)。
2. `A2PanelFixtures.capabilities` 是一份**手写对照**的内核 manifest。它漂了,纯逻辑测试**不会**红 ——
   兜住它的是旗舰 e2e:`a2-panel-probe` 连上真内核后逐条核对(`PANEL_MANIFEST` / `PANEL_COVERAGE`)。
   改那份清单时,请把 `Scripts/a2-flagship-e2e.sh` 也跑一遍。
