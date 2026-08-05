// 10 票:代理域视图的**投影**断言 —— 三条 safe 能力的 output(任意 JSON)→ 菜单要的那几个字段。
//
// 这一层是 09 票那条豁免界的兑现处:`ProxyStatusResult` / `ProxyGroupsResult` /
// `SubscriptionListResult` **不建 typed struct**,经 `A2JSON` 取值。代价是取值可能取错,
// 所以取值本身要有断言 —— 尤其是「取不到就如实记一笔,绝不臆造默认值」那条。
//
// 期望值不是重算出来的:每份输入都逐字抄自 `kernel/contract/golden/` 里的同名样本形状
// (proxy-status-running / proxy-groups-result / subscription-list-result)。

import Testing
import A2Contract
import A2Panel

@Suite("10 代理域投影(A2JSON 取值 + 取不到就如实说)")
struct A2ProxyViewTests {

    private let statusRunning: A2JSON = .object([
        "running": .bool(true),
        "apiReachable": .bool(true),
        "endpoint": .object(["owner": .string("a2"), "controller": .string("127.0.0.1:19090"),
                             "managed": .bool(true)]),
        "version": .string("v1.19.28"),
        "mode": .string("rule"),
        "mixedPort": .int(7890),
        "node": .string("HK-01"),
        "systemProxy": .object(["supported": .bool(true), "takenOver": .bool(true),
                                "host": .string("127.0.0.1"), "port": .int(7890)]),
    ])

    private let groupsResult: A2JSON = .object([
        "endpoint": .object(["owner": .string("a2"), "controller": .string("127.0.0.1:19090"),
                             "managed": .bool(true)]),
        "groups": .array([
            .object(["name": .string("GLOBAL"), "type": .string("Selector"),
                     "all": .array([.string("PROXY"), .string("DIRECT")])]),
            .object(["name": .string("PROXY"), "type": .string("Selector"), "now": .string("HK-01"),
                     "all": .array([.string("HK-01"), .string("JP-02")])]),
        ]),
    ])

    private let subscriptionsResult: A2JSON = .object([
        "active": .string("sub-a-1a2b3c"),
        "directory": .string("/tmp/a2home/subscriptions"),
        "subscriptions": .array([
            .object(["id": .string("sub-a-1a2b3c"), "name": .string("机场 A"),
                     "source": .string("https://example.invalid/a.yaml")]),
        ]),
    ])

    @Test("10 三条 output 齐全:字段逐条落到视图上")
    func fullProjection() {
        let view = A2ProxyView.from(status: statusRunning, groups: groupsResult,
                                    subscriptions: subscriptionsResult)
        #expect(view.kernelRunning)
        #expect(view.apiReachable)
        #expect(view.kernelVersion == "v1.19.28")
        #expect(view.mode == "rule")
        #expect(view.mixedPort == 7890)
        #expect(view.currentNode == "HK-01")
        #expect(view.systemProxyTakenOver)
        #expect(view.systemProxySupported)
        #expect(view.groups.map(\.name) == ["GLOBAL", "PROXY"], "内核按组名排序,壳原样保留顺序")
        #expect(view.groups[0].now == nil, "GLOBAL 没有 now(契约里 `now` 为空串时已归一成缺省)")
        #expect(view.groups[1].now == "HK-01")
        #expect(view.subscriptions.map(\.id) == ["sub-a-1a2b3c"])
        #expect(view.activeSubscriptionID == "sub-a-1a2b3c")
        #expect(view.notes.isEmpty)
    }

    @Test("10 status 取不到:如实记一笔,不臆造 mode/端口/节点")
    func missingStatusIsHonest() {
        let view = A2ProxyView.from(status: nil, groups: groupsResult, subscriptions: subscriptionsResult)
        #expect(!view.kernelRunning)
        #expect(view.mode == nil && view.mixedPort == nil && view.currentNode == nil)
        #expect(view.notes.contains { $0.contains("proxy.status") })
    }

    @Test("10 groups 形状不符:空清单 + 一条说明(不假装有一个叫 PROXY 的组)")
    func malformedGroupsIsHonest() {
        let view = A2ProxyView.from(status: statusRunning, groups: .object(["oops": .bool(true)]),
                                    subscriptions: subscriptionsResult)
        #expect(view.groups.isEmpty)
        #expect(view.notes.contains { $0.contains("proxy.groups.list") })
    }

    @Test("10 订阅 active 为 null 是合法答案(没有激活项),不是读取失败")
    func nullActiveIsLegal() {
        let view = A2ProxyView.from(
            status: statusRunning, groups: groupsResult,
            subscriptions: .object(["active": .null, "directory": .string("/tmp/x"),
                                    "subscriptions": .array([])]))
        #expect(view.activeSubscriptionID == nil)
        #expect(view.subscriptions.isEmpty)
        #expect(!view.notes.contains { $0.contains("proxy.subscription.list") },
                "空清单 + 无激活项是正常状态,不该记成读取失败")
    }

    @Test("10 systemProxy 缺席:如实记一笔(接管态是要显示勾选的东西,猜不得)")
    func missingSystemProxySummaryIsHonest() {
        var members = statusRunning.objectValue!
        members.removeValue(forKey: "systemProxy")
        let view = A2ProxyView.from(status: .object(members), groups: nil, subscriptions: nil)
        #expect(!view.systemProxyTakenOver)
        #expect(view.notes.contains { $0.contains("systemProxy") })
    }

    @Test("10 条目缺必填键就整条丢掉,不造半条(id/name 缺一不可)")
    func malformedEntriesAreDropped() {
        let view = A2ProxyView.from(
            status: statusRunning, groups: .object(["groups": .array([
                .object(["type": .string("Selector"), "all": .array([])]),   // 无 name
                .object(["name": .string("OK"), "type": .string("Selector"), "all": .array([])]),
            ])]),
            subscriptions: .object(["active": .null, "subscriptions": .array([
                .object(["id": .string("only-id")]),                          // 无 name
                .object(["id": .string("full"), "name": .string("完整")]),
            ])]))
        #expect(view.groups.map(\.name) == ["OK"])
        #expect(view.subscriptions.map(\.id) == ["full"])
    }

    @Test("10 mixedPort 是 double 时也收得下(能力 output 是任意 JSON,不强求整数支)")
    func mixedPortAcceptsDouble() {
        var members = statusRunning.objectValue!
        members["mixedPort"] = .double(7890)
        let view = A2ProxyView.from(status: .object(members), groups: nil, subscriptions: nil)
        #expect(view.mixedPort == 7890)
    }
}
