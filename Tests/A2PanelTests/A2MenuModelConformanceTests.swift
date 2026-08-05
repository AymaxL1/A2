// 10 票:壳的**纯逻辑一致性测试**(不起 GUI、不碰 AppKit、不发 UDS)。
//
// 自 14 票 `Tests/AAHostTestKitTests/MenuModelConformanceTests.swift` 平移。两处差别:
//   ① 能力清单来自 `A2PanelFixtures.capabilities`(手写对照 manifest),
//      而 14 票用的是同进程的假注册表 —— 新架构里注册表在**内核进程**里,纯逻辑测试够不着它。
//      **防漂由旗舰 e2e 兜**:`a2-panel-probe` 连真内核后逐条核对装置与真快照(`PANEL_MANIFEST`),
//      漂了当场红。所以「拿真注册表交叉核对」这条验收没有丢,只是换了个更硬的缝。
//   ② 不再打 `MENUBAR_ASSERT1/2` 结论行 —— 14 票那两行是给 `Scripts/check/menubar.sh` grep 的,
//      而门禁在本票原子切换后直接跑 `swift test`,shell 中间层退役,结论行随之没有消费者。

import Testing
import A2Contract
import A2Panel
import A2PanelFixtures

@Suite("10 菜单模型纯逻辑(覆盖面/可追溯性 + 四态如实反映)")
struct A2MenuModelConformanceTests {

    // 覆盖面用**四种固定装置的并集**判:有些用户操作只在特定状态下才有项
    // (如「激活订阅」只在有订阅时出现)。并集才是「菜单能做的全部事」。
    private static let models = A2PanelFixtures.fixtures.map {
        A2MenuModelBuilder.build(state: $0.state)
    }
    private static let allItems = models.flatMap { $0.flattened }
    private static let capabilityIDs = Set(A2PanelFixtures.capabilities.map(\.id))

    // ========================================================================
    // 覆盖面 + 可追溯性
    // ========================================================================

    @Test("10 可追溯:每个绑定项都落到 manifest 里真实存在的能力 id")
    func boundItemsResolve() {
        let bound = Self.allItems.filter { $0.capabilityID != nil }
        #expect(!bound.isEmpty, "菜单里应当存在绑定能力 id 的项")
        let unresolved = Set(bound.compactMap { $0.capabilityID }).subtracting(Self.capabilityIDs)
        #expect(unresolved.isEmpty, "追溯不到的能力 id:\(unresolved.sorted())")
    }

    @Test("10 可追溯:认领了 04 票用户操作的项都绑了能力 id(无空头认领)")
    func noUnboundClaims() {
        let claimedWithoutCap = Self.allItems.filter { $0.userAction != nil && $0.capabilityID == nil }
        #expect(claimedWithoutCap.isEmpty,
                "空头认领:\(claimedWithoutCap.map(\.title))")
    }

    @Test("10 覆盖:04 票 In 清单六项用户操作逐项有菜单项且落到真实能力",
          arguments: A2MenuUserAction.allCases)
    func userActionCovered(_ action: A2MenuUserAction) {
        let items = Self.allItems.filter { $0.userAction == action && $0.capabilityID != nil }
        #expect(!items.isEmpty, "「\(action.displayName)」在菜单里没有任何项")
        #expect(items.allSatisfy { Self.capabilityIDs.contains($0.capabilityID!) },
                "「\(action.displayName)」有项落到了不存在的能力")
    }

    @Test("10 反向核对:manifest 里每条可发起的 proxy 能力都在菜单里露出,或在豁免表里记账")
    func actionableCapabilitiesExposed() {
        let actionable = A2PanelFixtures.capabilities
            .filter { $0.id.hasPrefix("proxy.") && ($0.risk == .normal || $0.risk == .dangerous) }
            .map(\.id)
        #expect(!actionable.isEmpty, "manifest 里应当有可发起的 proxy 能力")
        let exposed = Set(Self.allItems.compactMap { $0.capabilityID })
        let missing = actionable.filter {
            !exposed.contains($0) && A2PanelFixtures.menuExemptCapabilities[$0] == nil
        }
        #expect(missing.isEmpty, "既没进菜单也没记账的能力:\(missing.sorted())")
    }

    @Test("10 豁免表:每条都指向真实能力,且理由非空(空理由不接受)")
    func exemptionsAreHonest() {
        for (id, reason) in A2PanelFixtures.menuExemptCapabilities {
            #expect(Self.capabilityIDs.contains(id), "豁免表里有幽灵能力:\(id)")
            #expect(reason.count >= 20, "豁免理由太短,像是敷衍:\(id)")
        }
    }

    @Test("10 菜单只投影 proxy 域:demo 三条能力一项都不生成")
    func demoCapabilitiesNotExposed() {
        let demoItems = Self.allItems.filter { ($0.capabilityID ?? "").hasPrefix("demo.") }
        #expect(demoItems.isEmpty, "demo 能力不该出现在菜单里:\(demoItems.map(\.title))")
    }

    // ========================================================================
    // 状态如实反映
    // ========================================================================

    private func items(_ m: A2MenuModel) -> [A2MenuItemModel] { m.flattened }
    private func item(_ m: A2MenuModel, titled title: String) -> A2MenuItemModel? {
        items(m).first { $0.title == title }
    }
    private func modeItem(_ m: A2MenuModel, _ raw: String) -> A2MenuItemModel? {
        items(m).first { $0.capabilityID == "proxy.mode.set" && $0.params["mode"] == .string(raw) }
    }

    @Test("10 状态①(mihomo 未运行):如实显示未运行、写面置灰、还原永远可点")
    func stateMihomoDown() {
        let m = A2MenuModelBuilder.build(state: A2PanelFixtures.mihomoDown.state)
        #expect(items(m).contains { $0.kind == .info && $0.title == "mihomo:未运行" })
        #expect(modeItem(m, "rule")?.enabled == false && modeItem(m, "global")?.enabled == false,
                "mihomo 没跑时模式项应全部置灰(点了也只会失败,不给假入口)")
        #expect(item(m, titled: "开启系统代理")?.enabled == false,
                "mihomo 没跑时接管会指向死端口,应置灰")
        #expect(item(m, titled: "关闭系统代理(还原)")?.enabled == true,
                "还原永远可点 —— 内核死了才更需要它,而且「退出即还原」已废除,这是唯一的还原入口")
        #expect(items(m).contains { $0.kind == .info && $0.title.contains("mihomo 未运行,不可用") })
        #expect(items(m).allSatisfy { $0.capabilityID != "proxy.node.select" || !$0.enabled })
        #expect(item(m, titled: "更新订阅")?.enabled == false)
        #expect(item(m, titled: "删除订阅…")?.enabled == false)
    }

    @Test("10 状态②(mihomo 运行 + rule + HK-01 + 已接管):模式/节点/接管三处勾选都跟着状态走")
    func stateMihomoRunning() {
        let m = A2MenuModelBuilder.build(state: A2PanelFixtures.mihomoRunning.state)
        #expect(items(m).contains { $0.kind == .info && $0.title.contains("mihomo:运行中") && $0.title.contains("v1.19.28") })
        #expect(items(m).contains {
            $0.kind == .info && $0.title.contains("模式:规则") && $0.title.contains("节点:HK-01")
                && $0.title.contains("端口:7890")
        })
        #expect(modeItem(m, "rule")?.checked == true && modeItem(m, "rule")?.enabled == true)
        #expect(modeItem(m, "global")?.checked == false && modeItem(m, "direct")?.checked == false)
        let hk = items(m).first {
            $0.capabilityID == "proxy.node.select" && $0.params["node"] == .string("HK-01")
                && $0.params["group"] == .string("PROXY")
        }
        #expect(hk?.checked == true, "PROXY 组里 HK-01 应被勾选")
        #expect(items(m).contains {
            $0.capabilityID == "proxy.node.select" && $0.params["node"] == .string("JP-02") && $0.checked == false
        })
        #expect(items(m).contains {
            $0.capabilityID == "proxy.latency.test" && $0.params["group"] == .string("PROXY") && $0.enabled
        })
        #expect(items(m).contains { $0.kind == .group && $0.title == "PROXY:HK-01" })
        // 14 票记的那条「已知缺口」(接管态没有只读能力面 → 菜单不显示勾选)在新契约下已填上。
        #expect(item(m, titled: "开启系统代理")?.checked == true,
                "systemProxy.takenOver=true 时「开启系统代理」应勾选(14 票的已知缺口已由 07 票契约填上)")
        #expect(item(m, titled: "关闭系统代理(还原)")?.checked == false)
    }

    @Test("10 状态③(有激活订阅):激活项勾选、逐条可更新可删除、add 声明两个待输入参数")
    func stateActiveSubscription() {
        let m = A2MenuModelBuilder.build(state: A2PanelFixtures.activeSubscription.state)
        let active = items(m).first {
            $0.capabilityID == "proxy.subscription.activate" && $0.params["id"] == .string("sub-jichang-a-1a2b3c")
        }
        let inactive = items(m).first {
            $0.capabilityID == "proxy.subscription.activate" && $0.params["id"] == .string("sub-jichang-b-4d5e6f")
        }
        #expect(active?.checked == true)
        #expect(inactive?.checked == false)
        let update = item(m, titled: "更新订阅")
        #expect(update?.enabled == true)
        #expect(update?.children.count == 2, "「手动更新」不限于激活项,每条订阅各一个子项")
        #expect(update?.children.allSatisfy { $0.capabilityID == "proxy.subscription.update" && $0.params["id"] != nil } == true)
        let remove = item(m, titled: "删除订阅…")
        #expect(remove?.children.count == 2)
        #expect(remove?.children.allSatisfy { $0.capabilityID == "proxy.subscription.remove" } == true)
        #expect(modeItem(m, "global")?.checked == true, "模式勾选跟着状态走")
        #expect(items(m).contains {
            $0.capabilityID == "proxy.subscription.add" && $0.enabled
                && Set($0.prompts.map(\.name)) == ["name", "source"]
        })
        #expect(item(m, titled: "开启系统代理")?.checked == false)
    }

    @Test("10 状态④(与内核断连):菜单说清「代理不受影响」,不把断连说成断网")
    func stateDisconnected() {
        let m = A2MenuModelBuilder.build(state: A2PanelFixtures.disconnected.state)
        let line = items(m).first { $0.kind == .info && $0.title.hasPrefix("内核:未连接") }
        #expect(line != nil, "断连时应有一行明说未连接")
        #expect(line?.title.contains("代理不受影响") == true,
                "断连 ≠ 断网:数据面不随控制面起落,菜单必须把这两件事分清")
        // 断连时仲裁面未知 → 不该出现「确认器在场」这种没有依据的断言。
        #expect(!items(m).contains { $0.title.hasPrefix("确认器:") })
    }

    @Test("10 四态两两不同(排除「模型恒定」的假绿)")
    func fourStatesDiffer() {
        let snapshots = A2PanelFixtures.fixtures.map {
            A2MenuModelBuilder.build(state: $0.state).textSnapshot
        }
        #expect(Set(snapshots).count == snapshots.count,
                "同一构造器喂不同状态应当产出不同模型")
    }

    @Test("10 退出项措辞:必须写明「代理继续运行」(「退出即还原」已废除)")
    func quitWordingSaysProxyKeepsRunning() {
        let m = A2MenuModelBuilder.build(state: A2PanelFixtures.mihomoRunning.state)
        let quit = items(m).first { $0.kind == .quit }
        #expect(quit != nil)
        #expect(quit?.title.contains("代理继续运行") == true,
                "壳退出仅断连;标题不说清楚,用户会以为关掉面板等于关掉服务")
    }

    @Test("10 能力缺席即不出现:内核没登记的能力不生成假入口")
    func absentCapabilityProducesNoItem() {
        var state = A2PanelFixtures.mihomoRunning.state
        state.capabilities = state.capabilities.filter { $0.id != "proxy.mode.set" }
        let m = A2MenuModelBuilder.build(state: state)
        #expect(!items(m).contains { $0.capabilityID == "proxy.mode.set" },
                "能力不在快照里就不该有对应菜单项(宁可少一项,也不给点了报「未知能力」的假入口)")
    }

    @Test("10 取值域不硬编码:模式项来自 descriptor 的 allowedValues")
    func modeValuesComeFromDescriptor() {
        var state = A2PanelFixtures.mihomoRunning.state
        state.capabilities = state.capabilities.map { descriptor in
            guard descriptor.id == "proxy.mode.set" else { return descriptor }
            return A2CapabilityDescriptor(
                id: descriptor.id, risk: descriptor.risk, summary: descriptor.summary,
                parameters: [A2ParameterSpec(name: "mode", type: .string, required: true,
                                             description: "目标模式",
                                             allowedValues: ["rule", "global", "direct", "script"])],
                cliAlias: descriptor.cliAlias)
        }
        let m = A2MenuModelBuilder.build(state: state)
        let modes = items(m).filter { $0.capabilityID == "proxy.mode.set" }
            .compactMap { $0.params["mode"]?.stringValue }
        #expect(modes == ["rule", "global", "direct", "script"],
                "内核新增模式时菜单应当直接跟上(没翻译就显示原值),不靠壳里一份硬编码名单")
        #expect(items(m).contains { $0.title == "模式:script" }, "没有中文译名时如实显示原值")
    }
}
