// 16 票:**引导区段进菜单模型**的纯逻辑断言(ADR 0012)。
//
// 与 10 票那批「四态如实反映」同一种姿势:构造器是纯函数,喂两份状态进去、断言吐出来的模型。
// 快照(渲染器 B × 入库 golden)与这批断言喂的是**同一批固定装置**,所以不可能出现
// 「断言验的是 A、图片画的是 B」。

import Testing
import A2Contract
import A2Panel
import A2PanelFixtures

@Suite("16 引导区段进菜单(六条分支 + 两条红线)")
struct A2BootstrapMenuTests {

    private func model(_ fixture: A2PanelFixtures.Fixture) -> A2MenuModel {
        A2MenuModelBuilder.build(state: fixture.state, bootstrap: fixture.bootstrap)
    }
    private func items(_ m: A2MenuModel) -> [A2MenuItemModel] { m.flattened }
    private func item(_ m: A2MenuModel, titled title: String) -> A2MenuItemModel? {
        items(m).first { $0.title == title }
    }
    private func bootstrapItems(_ m: A2MenuModel) -> [A2MenuItemModel] {
        items(m).filter { $0.kind == .bootstrap }
    }

    // ========================================================================
    // 红线:没有内嵌 bin 就整块隐藏
    // ========================================================================

    @Test("16 没有内嵌 bin:引导区段一项都不出,菜单与 10 票**逐字相同**",
          arguments: [A2PanelFixtures.mihomoDown, A2PanelFixtures.mihomoRunning,
                      A2PanelFixtures.activeSubscription, A2PanelFixtures.disconnected])
    func hiddenWithoutEmbeddedBin(_ fixture: A2PanelFixtures.Fixture) {
        let m = model(fixture)
        #expect(bootstrapItems(m).isEmpty)
        #expect(item(m, titled: "高级") == nil)
        // 与"不带 bootstrap 参数"逐字相同 —— 既有 golden 因此一个字节都不用动。
        #expect(m.textSnapshot == A2MenuModelBuilder.build(state: fixture.state).textSnapshot)
    }

    @Test("16 没有内嵌 bin 时,断连那一行仍是 10 票的原文(不改现状文案)")
    func disconnectedLineIsUnchanged() {
        let m = model(A2PanelFixtures.disconnected)
        let line = items(m).first { $0.kind == .info && $0.title.hasPrefix("内核:未连接") }
        #expect(line?.title.contains("代理不受影响,仅本面板失联") == true)
    }

    // ========================================================================
    // 六条分支
    // ========================================================================

    @Test("16 分支①断连 + 未装:出「安装并启动内核」,可点,绑 install")
    func branchNotInstalled() throws {
        let m = model(A2PanelFixtures.bootstrapNotInstalled)
        let install = try #require(item(m, titled: "安装并启动内核"))
        #expect(install.kind == .bootstrap)
        #expect(install.enabled)
        #expect(install.bootstrapAction == .install)
        // 断连那一行照旧在场:引导项是"那我该怎么办"的答案,不是替换。
        #expect(items(m).contains { $0.kind == .info && $0.title.hasPrefix("内核:未连接") })
    }

    @Test("16 分支②断连 + 已装未跑:标题变「启动内核」,动作仍是**同一条幂等 install**")
    func branchInstalledNotRunning() throws {
        let m = model(A2PanelFixtures.bootstrapInstalledNotRunning)
        #expect(item(m, titled: "安装并启动内核") == nil)
        let start = try #require(item(m, titled: "启动内核"))
        #expect(start.bootstrapAction == .install, "标题变了,命令不变 —— 白名单里没有第五条")
        #expect(start.enabled)
    }

    @Test("16 分支③在途:项**留着但禁用** + 一条「安装中…」;高级项一并禁用")
    func branchInFlight() throws {
        let m = model(A2PanelFixtures.bootstrapInstalling)
        let install = try #require(item(m, titled: "安装并启动内核"))
        #expect(install.enabled == false)
        #expect(install.disabledReason == "安装中,请稍候")
        #expect(items(m).contains { $0.kind == .info && $0.title.hasPrefix("⏳ 安装中…") })
        let uninstall = try #require(item(m, titled: "停止并卸载内核服务…"))
        #expect(uninstall.enabled == false)
        #expect(uninstall.disabledReason == "有引导操作在途")
    }

    @Test("16 分支④失败:如实一行,含 error.code 与退出码语义(6 = 这个 bin 不能自装)")
    func branchFailure() throws {
        let m = model(A2PanelFixtures.bootstrapFailed)
        let line = try #require(items(m).first { $0.title.hasPrefix("⚠️ 引导失败:") })
        #expect(line.kind == .info)
        #expect(line.enabled == false, "失败行是只读信息,不该是个能点的东西")
        #expect(line.title.contains("service_self_copy_unsupported"))
        #expect(line.title.contains("退出码 6"))
        #expect(line.title.contains("这个 bin 不能自装"))
        // 失败之后那一项照样可点 —— 幂等命令,重试的代价是零。
        #expect(item(m, titled: "安装并启动内核")?.enabled == true)
    }

    @Test("16 分支⑤已连 + 版本失配:出「升级内核 vX→vY(重启服务,不断网)」,同一条 install")
    func branchUpgrade() throws {
        let m = model(A2PanelFixtures.bootstrapUpgrade)
        let upgrade = try #require(item(m, titled: "升级内核 v0.1.0→v0.2.0(重启服务,不断网)"))
        #expect(upgrade.kind == .bootstrap)
        #expect(upgrade.bootstrapAction == .install)
        #expect(upgrade.enabled)
    }

    @Test("16 分支⑥已连 + 版本一致:引导区段只剩「高级 → 停止并卸载内核服务」")
    func branchAdvancedOnly() throws {
        let m = model(A2PanelFixtures.bootstrapAdvanced)
        #expect(bootstrapItems(m).map(\.bootstrapAction) == [.uninstall],
                "版本一致时不该出任何安装/升级项")
        let advanced = try #require(item(m, titled: "高级"))
        #expect(advanced.kind == .group)
        let uninstall = try #require(item(m, titled: "停止并卸载内核服务…"))
        #expect(uninstall.enabled)
        #expect(uninstall.bootstrapAction == .uninstall)
        // 口径与 CLI 逐字同源:只拆服务,数据留下。
        #expect(advanced.children.contains {
            $0.kind == .info && $0.title.contains("只拆服务") && $0.title.contains("~/.a2")
        })
    }

    // ========================================================================
    // 升级检测的边界
    // ========================================================================

    @Test("16 版本一模一样就不提示升级(不制造「永远有个升级项」的噪音)")
    func sameVersionProducesNoUpgradeItem() {
        var state = A2PanelFixtures.mihomoDown.state
        state.kernelStatus = A2StatusResult(version: "9.9.9", pid: 1, startedAt: "t",
                                            uptimeMs: 1, home: "/h", socketPath: "/h/s")
        let m = A2MenuModelBuilder.build(
            state: state,
            bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                        embeddedKernelVersion: "9.9.9",
                                        serviceState: .running))
        #expect(m.flattened.filter { $0.bootstrapAction == .install }.isEmpty)
    }

    @Test("16 问不出内嵌 bin 的版本 → 不提示升级(宁可不提示,也不拿 nil 去比)")
    func unknownEmbeddedVersionProducesNoUpgradeItem() {
        let m = A2MenuModelBuilder.build(
            state: A2PanelFixtures.mihomoDown.state,
            bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                        embeddedKernelVersion: nil,
                                        serviceState: .running))
        #expect(m.flattened.filter { $0.bootstrapAction == .install }.isEmpty)
    }

    @Test("16 线上版本取 `snapshot.status.version`(hello 全量快照里那一个,不是 mihomo 的版本)")
    func liveVersionComesFromTheKernelSnapshot() throws {
        var state = A2PanelFixtures.mihomoRunning.state   // proxy.kernelVersion = v1.19.28(mihomo 的)
        state.kernelStatus = A2StatusResult(version: "0.3.0", pid: 1, startedAt: "t",
                                            uptimeMs: 1, home: "/h", socketPath: "/h/s")
        let m = A2MenuModelBuilder.build(
            state: state,
            bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                        embeddedKernelVersion: "0.4.0",
                                        serviceState: .running))
        let upgrade = try #require(m.flattened.first { $0.bootstrapAction == .install })
        #expect(upgrade.title.contains("v0.3.0→v0.4.0"))
        #expect(!upgrade.title.contains("1.19.28"), "别把 mihomo 的版本当成内核版本")
    }

    @Test("16 断连时不比版本:`kernelStatus` 是断开前的旧值,拿它提示升级就是撒谎")
    func disconnectedNeverShowsUpgrade() throws {
        let m = A2MenuModelBuilder.build(
            state: A2PanelFixtures.disconnected.state,   // kernelStatus 保留着 0.1.0
            bootstrap: A2BootstrapState(embeddedBinAvailable: true,
                                        embeddedKernelVersion: "0.2.0",
                                        serviceState: .installedNotRunning))
        let install = try #require(m.flattened.first { $0.bootstrapAction == .install })
        #expect(install.title == "启动内核", "断连态只该出「装/启」,不该出「升级 v…→v…」")
    }

    // ========================================================================
    // 高级子菜单的置灰口径
    // ========================================================================

    @Test("16 未安装时「停止并卸载」置灰并说明为什么(不整项消失 —— 与选节点那条同一种姿势)")
    func uninstallIsDisabledWhenNotInstalled() throws {
        let m = model(A2PanelFixtures.bootstrapNotInstalled)
        let uninstall = try #require(item(m, titled: "停止并卸载内核服务…"))
        #expect(uninstall.enabled == false)
        #expect(uninstall.disabledReason == "服务尚未安装,没有可卸的东西")
    }

    @Test("16 服务态读不到时也置灰,并说清是读不到(不假装可卸)")
    func uninstallIsDisabledWhenStateIsUnknown() throws {
        let m = A2MenuModelBuilder.build(
            state: A2PanelFixtures.disconnected.state,
            bootstrap: A2BootstrapState(embeddedBinAvailable: true, serviceState: nil))
        let uninstall = try #require(item(m, titled: "停止并卸载内核服务…"))
        #expect(uninstall.enabled == false)
        #expect(uninstall.disabledReason?.contains("读不到服务态") == true)
    }

    // ========================================================================
    // 两条模型级红线
    // ========================================================================

    @Test("16 红线:引导项**永不**绑能力 id(它不经 UDS —— 两条出口绝不混用一个字段)",
          arguments: A2PanelFixtures.fixtures.map(\.name))
    func bootstrapItemsNeverCarryCapabilityID(_ name: String) throws {
        let fixture = try #require(A2PanelFixtures.fixtures.first { $0.name == name })
        for item in bootstrapItems(model(fixture)) {
            #expect(item.capabilityID == nil, "引导项绑了能力 id:\(item.title)")
            #expect(item.userAction == nil, "引导项不该认领 04 票的用户操作:\(item.title)")
            #expect(item.params.isEmpty)
            #expect(item.prompts.isEmpty)
        }
    }

    @Test("16 红线:能力项**永不**带引导动作(反向同一条)",
          arguments: A2PanelFixtures.fixtures.map(\.name))
    func capabilityItemsNeverCarryBootstrapAction(_ name: String) throws {
        let fixture = try #require(A2PanelFixtures.fixtures.first { $0.name == name })
        for item in items(model(fixture)) where item.capabilityID != nil {
            #expect(item.bootstrapAction == nil, "能力项混进了引导动作:\(item.title)")
        }
    }

    @Test("16 文本快照带出引导项会跑的那条命令(角标 ⇒,与能力项的 → 一眼可分)")
    func textSnapshotCarriesTheCommand() {
        let text = model(A2PanelFixtures.bootstrapNotInstalled).textSnapshot
        #expect(text.contains("⇒ a2 service install --copy-to-home"))
        #expect(text.contains("⇒ a2 service uninstall"))
    }

    // ========================================================================
    // 分隔线收口(16 票新增 —— 全新用户那份菜单第一次让这件事显形)
    // ========================================================================

    @Test("16 任何装置的菜单都没有连续/首尾分隔线(整段缺席时不留下一排孤零零的横线)",
          arguments: A2PanelFixtures.fixtures.map(\.name))
    func noStraySeparators(_ name: String) throws {
        let fixture = try #require(A2PanelFixtures.fixtures.first { $0.name == name })
        func check(_ list: [A2MenuItemModel], _ where_: String) {
            #expect(list.first?.kind != .separator, "\(where_) 开头是分隔线")
            #expect(list.last?.kind != .separator, "\(where_) 结尾是分隔线")
            for (a, b) in zip(list, list.dropFirst()) {
                #expect(!(a.kind == .separator && b.kind == .separator),
                        "\(where_) 出现连续分隔线(「\(a.title)」之后)")
            }
            for item in list where !item.children.isEmpty {
                check(item.children, "\(where_) ▸ \(item.title)")
            }
        }
        check(model(fixture).items, name)
    }

    @Test("16 收口只动分隔线:非分隔线的项与顺序一个字都不变")
    func tidyingOnlyTouchesSeparators() {
        let raw: [A2MenuItemModel] = [
            .separator(), .separator(),
            .header("甲"), .separator(), .separator(), .info("乙"),
            .separator(),
        ]
        let tidied = A2MenuModelBuilder.tidySeparators(raw)
        #expect(tidied.map { $0.kind } == [.header, .separator, .info])
        #expect(tidied.map { $0.title } == ["甲", "", "乙"])
    }
}
