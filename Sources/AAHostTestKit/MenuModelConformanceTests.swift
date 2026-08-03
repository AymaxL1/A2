// AAHostTestKit —— 14 票菜单模型的**纯逻辑一致性测试**(不起 GUI、不碰 AppKit、不发 UDS)。
//
// 门禁的第 1、2 条断言在这里成立,shell 侧只负责断言 runner 输出里出现对应的结论行。
// **为什么放纯逻辑而不是放 shell**:
//   ① 「菜单覆盖 04 票 in 清单的全部用户操作」要拿**注册表的实际清单**交叉核对 ——
//      那是 Swift 侧才拿得到的对象;shell 只能去 grep 字符串,那等于自己抄一份名单跟自己比,毫无价值。
//   ② 「状态变化在菜单里如实反映」要喂三种状态、比三份模型 —— 纯函数天然可做,起 GUI 反而什么都验不了。
// shell 侧因此只留一条 grep(每条断言恰好一次 PASS/FAIL),真正的判据在本文件。
//
// 依赖边:AAHostTestKit → AAUISystem / AAHostRuntime / AAContracts(+ MenuFixtures 用到的 PluginProxy)。

import Foundation
import AAContracts
import AAHostRuntime
import AAUISystem

/// 菜单模型的纯逻辑一致性测试。
public enum MenuModelConformanceTests {

    public static func run() -> TestReport {
        var report = TestReport()
        let ok1 = runCoverageAndTraceability(&report)
        let ok2 = runStateReflection(&report)
        // 结论行:shell 侧各 grep 一条,故每条门禁断言恰好记 1 次 PASS/FAIL。
        report.note(ok1.line)
        report.note(ok2.line)
        return report
    }

    // ========================================================================
    // 断言 1:覆盖面 + 可追溯性(拿真注册表交叉核对)
    // ========================================================================

    private struct Conclusion { let ok: Bool; let line: String }

    private static func runCoverageAndTraceability(_ report: inout TestReport) -> Conclusion {
        let registry = AAMenuFixtures.realRegistry()
        let capabilities = registry.list()
        // 覆盖面用**三种固定装置的并集**判:有些用户操作只在特定状态下才有项
        // (如「激活订阅」只在有订阅时出现)。并集才是「菜单能做的全部事」。
        let models = AAMenuFixtures.fixtures.map {
            AAMenuModelBuilder.build(capabilities: capabilities, state: $0.state)
        }
        let allItems = models.flatMap { $0.flattened }

        var ok = true
        func check(_ condition: Bool, _ desc: String) {
            report.check(condition, desc)
            if !condition { ok = false }
        }

        // ---- ① 每个带能力 id 的项都追溯得到**真实存在**的能力(注册表 describe 说了算)----
        let bound = allItems.filter { $0.capabilityID != nil }
        let unresolved = bound.filter { registry.describe($0.capabilityID!) == nil }
        check(!bound.isEmpty, "14 可追溯:菜单里存在绑定能力 id 的项(共 \(bound.count) 项)")
        check(unresolved.isEmpty,
              "14 可追溯:全部 \(bound.count) 个绑定项都能在**真注册表**里 describe 到"
              + (unresolved.isEmpty ? "" : ";追溯不到的: \(unresolved.compactMap { $0.capabilityID }.joined(separator: ","))"))

        // ---- ② 认领了用户操作的项必须绑能力(否则「覆盖」是空话)----
        let claimedWithoutCap = allItems.filter { $0.userAction != nil && $0.capabilityID == nil }
        check(claimedWithoutCap.isEmpty,
              "14 可追溯:认领了 04 票用户操作的项都绑了能力 id(无空头认领)")

        // ---- ③ 04 票 In 清单的六项用户操作**逐项**有菜单项 ----
        var covered = 0
        for action in AAMenuUserAction.allCases {
            let items = allItems.filter { $0.userAction == action && $0.capabilityID != nil }
            let hit = !items.isEmpty && items.allSatisfy { registry.describe($0.capabilityID!) != nil }
            if hit { covered += 1 }
            let ids = Set(items.compactMap { $0.capabilityID }).sorted().joined(separator: ",")
            check(hit, "14 覆盖:04 票 In 清单「\(action.displayName)」有菜单项且落到真实能力 [\(ids)]")
        }

        // ---- ④ 反向交叉核对:注册表里**每一条**用户可发起的 proxy 能力(normal/dangerous)都出现在菜单里 ----
        //     这一条是防「能力加了、菜单忘了露出来」。名单不是抄的,是从真注册表现算的。
        let actionable = capabilities.filter { $0.id.hasPrefix("proxy.") && ($0.risk == .normal || $0.risk == .dangerous) }
        let exposed = Set(allItems.compactMap { $0.capabilityID })
        let missing = actionable.map { $0.id }.filter { !exposed.contains($0) }
        check(!actionable.isEmpty, "14 反向核对:注册表里确实有可发起的 proxy 能力(共 \(actionable.count) 条)")
        check(missing.isEmpty,
              "14 反向核对:注册表里全部 \(actionable.count) 条 normal/dangerous 的 proxy 能力都在菜单里露出"
              + (missing.isEmpty ? "" : ";漏掉的: \(missing.joined(separator: ","))"))

        // ---- ⑤ 可点项带的参数经**真注册表的集中校验**是合法的 ----
        //     判据不是「我觉得参数对」,而是把它真的送进 `Registry.invoke` 走一遍校验层:
        //     只要不是 missing_parameter / type_mismatch / invalid_params 三种校验错,就说明参数形状对。
        //     (业务失败 / denied / pending 都算参数合法 —— 那些是校验之后的事,与本条无关。)
        //     只查 enabled 的项:置灰项按设计就不带参数(如无组时的「选择节点」),它们**不可能**被发出去。
        let paramErrors: Set<String> = [WireErrorCode.missingParameter, WireErrorCode.typeMismatch,
                                        WireErrorCode.invalidParams]
        var badParams: [String] = []
        var checkedCount = 0
        for item in allItems where item.kind == .action && item.enabled {
            guard let capID = item.capabilityID else { continue }
            var input = item.params
            // prompts 声明的参数由用户当场输入,这里用占位串代填(核验的是「形状对不对」,不是内容)。
            for p in item.prompts where input[p.name] == nil { input[p.name] = .string("占位") }
            checkedCount += 1
            if case .failure(let err) = registry.invoke(capabilityID: capID,
                                                        input: input.isEmpty ? nil : .object(input)),
               paramErrors.contains(err.code) {
                badParams.append("\(item.title)→\(capID): \(err.code) \(err.detail)")
            }
        }
        check(badParams.isEmpty,
              "14 参数合法:\(checkedCount) 个可点项的参数都过了真注册表的集中校验"
              + (badParams.isEmpty ? "" : ";不合法的: \(badParams.joined(separator: " | "))"))

        let line = "MENUBAR_ASSERT1: ok=\(ok ? 1 : 0) actions=\(covered)/\(AAMenuUserAction.allCases.count)"
            + " boundItems=\(bound.count) actionableCaps=\(actionable.count) checkedParams=\(checkedCount)"
            + "(04 票 In 清单全覆盖 + 每项追溯到真注册表里真实存在的能力 id)"
        return Conclusion(ok: ok, line: line)
    }

    // ========================================================================
    // 断言 2:状态变化在模型里如实反映
    // ========================================================================

    private static func runStateReflection(_ report: inout TestReport) -> Conclusion {
        let capabilities = AAMenuFixtures.realCapabilities()
        let down = AAMenuModelBuilder.build(capabilities: capabilities, state: AAMenuFixtures.kernelDown.state)
        let running = AAMenuModelBuilder.build(capabilities: capabilities, state: AAMenuFixtures.kernelRunning.state)
        let subbed = AAMenuModelBuilder.build(capabilities: capabilities, state: AAMenuFixtures.activeSubscription.state)

        var ok = true
        func check(_ condition: Bool, _ desc: String) {
            report.check(condition, desc)
            if !condition { ok = false }
        }
        func items(_ m: AAMenuModel) -> [AAMenuItemModel] { m.flattened }
        func item(_ m: AAMenuModel, titled title: String) -> AAMenuItemModel? {
            items(m).first { $0.title == title }
        }
        func modeItem(_ m: AAMenuModel, _ raw: String) -> AAMenuItemModel? {
            items(m).first { $0.capabilityID == "proxy.mode.set" && $0.params["mode"] == .string(raw) }
        }

        // ---- 状态①:内核未运行 ----
        check(items(down).contains { $0.kind == .info && $0.title == "内核:未运行" },
              "14 状态①(内核死):模型如实显示「内核:未运行」")
        check(modeItem(down, "rule")?.enabled == false && modeItem(down, "global")?.enabled == false,
              "14 状态①(内核死):模式项全部置灰(点了也只会失败,不给假入口)")
        check(item(down, titled: "开启系统代理")?.enabled == false,
              "14 状态①(内核死):「开启系统代理」置灰(接管会指向死端口)")
        check(item(down, titled: "关闭系统代理(还原)")?.enabled == true,
              "14 状态①(内核死):「关闭系统代理」仍可点(内核死了才更需要还原,08 票守的那条线)")
        check(items(down).contains { $0.kind == .info && $0.title.contains("内核未运行,不可用") },
              "14 状态①(内核死):代理组区块如实说明不可用")
        check(items(down).allSatisfy { $0.capabilityID != "proxy.node.select" || !$0.enabled },
              "14 状态①(内核死):选节点项不可点")
        check(item(down, titled: "更新订阅")?.enabled == false
              && item(down, titled: "更新订阅")?.children.isEmpty == true,
              "14 状态①(内核死 + 无订阅):「更新订阅」分组置灰且无子项(尚无订阅)")

        // ---- 状态②:内核运行中 + rule 模式 + 节点 HK-01 ----
        check(items(running).contains { $0.kind == .info && $0.title.contains("内核:运行中") && $0.title.contains("v1.19.28") },
              "14 状态②(内核活):模型显示「内核:运行中 v1.19.28」")
        check(items(running).contains { $0.kind == .info && $0.title.contains("模式:规则") && $0.title.contains("节点:HK-01") && $0.title.contains("端口:7890") },
              "14 状态②(内核活):基础状态行如实带出模式/节点/端口")
        check(modeItem(running, "rule")?.checked == true && modeItem(running, "rule")?.enabled == true,
              "14 状态②(rule 模式):「模式:规则」被勾选且可点")
        check(modeItem(running, "global")?.checked == false && modeItem(running, "direct")?.checked == false,
              "14 状态②(rule 模式):其余模式项未勾选")
        let hk = items(running).first { $0.capabilityID == "proxy.node.select"
            && $0.params["node"] == .string("HK-01") && $0.params["group"] == .string("PROXY") }
        check(hk?.checked == true, "14 状态②(节点 HK-01):PROXY 组里 HK-01 被勾选")
        check(items(running).contains { $0.capabilityID == "proxy.node.select" && $0.params["node"] == .string("JP-02") && $0.checked == false },
              "14 状态②:同组其余节点未勾选")
        check(items(running).contains { $0.capabilityID == "proxy.latency.test" && $0.params["group"] == .string("PROXY") && $0.enabled },
              "14 状态②:每组带一个可点的「测速本组」(参数为该组名)")
        check(items(running).contains { $0.kind == .group && $0.title == "PROXY:HK-01" },
              "14 状态②:代理组父项标题带出当前选中")

        // ---- 状态③:有激活订阅 ----
        let activeItem = items(subbed).first { $0.capabilityID == "proxy.subscription.activate"
            && $0.params["id"] == .string("sub-jichang-a-1a2b3c") }
        let inactiveItem = items(subbed).first { $0.capabilityID == "proxy.subscription.activate"
            && $0.params["id"] == .string("sub-jichang-b-4d5e6f") }
        check(activeItem?.checked == true, "14 状态③(激活订阅):激活项「机场 A」被勾选")
        check(inactiveItem?.checked == false, "14 状态③(激活订阅):未激活项「机场 B」未勾选")
        // In 清单的「手动更新」不限于激活项:每条订阅都要能单独更新,且各自参数指向自己的 id。
        let updGroup = item(subbed, titled: "更新订阅")
        check(updGroup?.enabled == true
              && updGroup?.children.count == AAMenuFixtures.activeSubscription.state.subscriptions.count
              && updGroup?.children.allSatisfy { c in
                     c.capabilityID == "proxy.subscription.update"
                     && c.params["id"] != nil
                 } == true
              && updGroup?.children.contains { $0.params["id"] == .string("sub-jichang-a-1a2b3c") } == true,
              "14 状态③(激活订阅):「更新订阅」分组逐条可更新,每项参数指向各自订阅 id(不只激活项)")
        check(modeItem(subbed, "global")?.checked == true,
              "14 状态③:模式勾选跟着状态走(global)")
        check(items(subbed).contains { $0.capabilityID == "proxy.subscription.add" && $0.enabled
                                       && Set($0.prompts.map { $0.name }) == ["name", "source"] },
              "14 状态③:「添加/替换订阅源」始终可点,且声明 name+source 两个待输入参数")

        // ---- 三态两两不同(否则上面的逐条断言可能在一个恒定模型上全绿)----
        check(down.textSnapshot != running.textSnapshot
              && running.textSnapshot != subbed.textSnapshot
              && down.textSnapshot != subbed.textSnapshot,
              "14 三态两两不同:同一构造器喂不同状态确实产出不同模型(排除「模型恒定」的假绿)")

        let line = "MENUBAR_ASSERT2: ok=\(ok ? 1 : 0) states=3"
            + "(内核死 / 内核活+rule 模式+节点 HK-01 / 有激活订阅 —— 三态在菜单模型里如实反映且两两不同)"
        return Conclusion(ok: ok, line: line)
    }
}
