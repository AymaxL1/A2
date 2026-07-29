// AAHostTestKit —— 10 票订阅管理纯逻辑测试(注入假 SubscriptionStore / SubscriptionSourcePort + 假 HTTPPort,
//   绝不碰真 AppSupport、真网络、真内核)。
// 依赖边:AAHostTestKit → AAPluginSDK、PluginProxy、AAContracts。
//
// 覆盖阶段 B 断言(10):
//   * id 生成(F1):同名(大小写不敏感)→ 同 id;异名(含纯非 ASCII)→ 异 id;空/纯空白名 → invalidParams(6)。
//   * list:空清单;add 后反映。
//   * add(dangerous 域逻辑,确认由 Registry 层管,这里只测状态机):upsert 替换源;拉取失败/空内容不留痕;不自动激活。
//   * activate(normal):成功切换 + 幂等不重载 + 不存在业务失败 + 重载失败 active 不变(无半态)。
//   * update(normal):激活项更新生效;**回滚**(新配置重载失败 → config 回退旧 + 尝试重载旧 + 业务失败;及回滚自身失败);不存在;拉取失败/空内容什么都不改。
//   * F5 损坏清单:add/list 均 capabilityFailed 且**未发生 saveCatalog 覆盖**。
//   * 四能力暴露:风险级 + 必填参数。

import Foundation
import AAContracts
import AAPluginSDK
import PluginProxy

extension ProxyConformanceTests {

    /// 10 票订阅套件入口(由 ProxyConformanceTests.run() 调用,汇入同一 runner 输出)。
    static func testSubscriptionManagement(_ report: inout TestReport) {
        testSubscriptionIDGeneration(&report)      // F1
        testSubscriptionList(&report)
        testSubscriptionAdd(&report)
        testSubscriptionActivate(&report)
        testSubscriptionActivateReloadFails(&report)
        testSubscriptionUpdate(&report)
        testSubscriptionUpdateRollback(&report)
        testSubscriptionUpdateRollbackSaveFails(&report)  // F6
        testSubscriptionCatalogCorruption(&report)        // F5
        testSubscriptionCapabilityExposure(&report)
    }

    // ============ 助手 ============

    private static func makeManager(store: FakeSubscriptionStore,
                                    source: FakeSubscriptionSourcePort,
                                    http: FakeHTTPPort) -> SubscriptionManager {
        SubscriptionManager(store: store, source: source, restClient: MihomoRESTClient(http: http, port: 9090))
    }

    private static func encodeCatalog(_ c: SubscriptionCatalog) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(c)) ?? Data()
    }

    private static func activeOf(_ mgr: SubscriptionManager) -> JSONValue? {
        if case .success(let out) = mgr.list() { return out.objectValue?["active"] }
        return nil
    }

    private static func subsCount(_ mgr: SubscriptionManager) -> Int {
        if case .success(let out) = mgr.list(), case let .array(a)? = out.objectValue?["subscriptions"] { return a.count }
        return -1
    }

    private static func putConfigsCount(_ http: FakeHTTPPort) -> Int {
        http.requests.filter { $0.method == "PUT" && $0.url.hasSuffix("/configs") }.count
    }

    private static func isFailure(_ r: Result<JSONValue, WireError>) -> Bool {
        if case .failure = r { return true }; return false
    }

    private static func errCode(_ r: Result<JSONValue, WireError>) -> String? {
        if case .failure(let e) = r { return e.code }; return nil
    }

    private static func idOf(_ r: Result<JSONValue, WireError>) -> String? {
        if case .success(let out) = r { return out.objectValue?["id"]?.stringValue }
        return nil
    }

    // ============ F1:id 生成(确定性 + 抗碰撞 + 空名拒绝)============
    private static func testSubscriptionIDGeneration(_ report: inout TestReport) {
        // 同名(大小写不敏感)→ 同 id。
        report.check(SubscriptionManager.makeID("Sub A") == SubscriptionManager.makeID("sub a")
                     && SubscriptionManager.makeID("Sub A") != nil,
                     "10 F1 id:同名(大小写不敏感)→ 同 id")
        // 两个不同**纯非 ASCII**名 → 不同 id(旧 normalize 会都塌成 '---' 碰撞)。
        let jiaID = SubscriptionManager.makeID("机场甲")
        let yiID = SubscriptionManager.makeID("机场乙")
        report.check(jiaID != nil && yiID != nil && jiaID != yiID,
                     "10 F1 id:两个不同非 ASCII 名 → 不同 id(消除碰撞)")
        // id 永不空。
        report.check((jiaID?.isEmpty == false),
                     "10 F1 id:纯非 ASCII 名 → id 非空(带确定性哈希后缀)")
        // 空 / 纯空白名 → nil(add 收敛 invalidParams)。
        report.check(SubscriptionManager.makeID("") == nil && SubscriptionManager.makeID("   ") == nil,
                     "10 F1 id:空/纯空白名 → nil")
        // add 空名 → invalidParams(退出码 6),且不留痕。
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        src.program(source: "s", [.success(Data("X".utf8))])
        let mgr = makeManager(store: store, source: src, http: FakeHTTPPort())
        let r = mgr.add(name: "   ", source: "s")
        report.check(errCode(r) == WireErrorCode.invalidParams, "10 F1 add:空/纯空白名 → invalidParams(退出码6)")
        report.check(store.saveConfigCalls.isEmpty && store.saveCatalogCount == 0 && src.fetchCalls.isEmpty,
                     "10 F1 add:空名先于任何 I/O 拒绝(未 fetch、未写 config/清单)")
    }

    // ============ ① list ============
    private static func testSubscriptionList(_ report: inout TestReport) {
        let store = FakeSubscriptionStore()
        let mgr = makeManager(store: store, source: FakeSubscriptionSourcePort(), http: FakeHTTPPort())
        if case .success(let out) = mgr.list() {
            let active = out.objectValue?["active"]
            let subsEmpty: Bool = { if case let .array(a)? = out.objectValue?["subscriptions"] { return a.isEmpty }; return false }()
            report.check(active == .null && subsEmpty, "10 list:空清单 → active=null、subscriptions 为空")
        } else {
            report.check(false, "10 list:空清单应成功返回")
        }
    }

    // ============ ② add(upsert 替换源 / 失败不留痕 / 不自动激活)============
    private static func testSubscriptionAdd(_ report: inout TestReport) {
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        let mgr = makeManager(store: store, source: src, http: FakeHTTPPort())

        src.program(source: "file:///s/a.conf", [.success(Data("CONFIG-A1".utf8))])
        let addR = mgr.add(name: "Sub A", source: "file:///s/a.conf")
        let idA = idOf(addR)
        var addOK = false
        if case .success(let out) = addR {
            addOK = (idA?.hasPrefix("sub-a-") == true) && out.objectValue?["added"] == .bool(true)
        }
        report.check(addOK, "10 add:新增订阅成功(added=true,id 带 slug 前缀 sub-a-)")
        report.check(activeOf(mgr) == .null, "10 add:add 后 active 仍为 null(不自动激活)")
        report.check(subsCount(mgr) == 1, "10 add:list 反映新增(1 条)")
        report.check(idA != nil && store.currentConfig(id: idA!) == Data("CONFIG-A1".utf8), "10 add:配置字节被物化")

        // 同 name 再 add(不同源)→ upsert 覆盖(仍 1 条,id 不变,source/config 换新)。
        src.program(source: "file:///s/a2.conf", [.success(Data("CONFIG-A2".utf8))])
        let addR2 = mgr.add(name: "Sub A", source: "file:///s/a2.conf")
        report.check(idOf(addR2) == idA, "10 add:同 name 再 add → 同 id(确定性)")
        report.check(subsCount(mgr) == 1, "10 add:upsert 同 name 覆盖=替换源(仍 1 条)")
        report.check(idA != nil && store.currentConfig(id: idA!) == Data("CONFIG-A2".utf8), "10 add:替换源后 config 物化为新字节")

        // — 拉取失败不留痕 —
        let store2 = FakeSubscriptionStore()
        let src2 = FakeSubscriptionSourcePort()
        src2.program(source: "bad", [.failure(SubscriptionSourceError.fetchFailed("模拟不可达"))])
        let mgr2 = makeManager(store: store2, source: src2, http: FakeHTTPPort())
        report.check(isFailure(mgr2.add(name: "X", source: "bad")), "10 add:拉取失败 → 业务失败")
        report.check(store2.saveConfigCalls.isEmpty && store2.saveCatalogCount == 0 && subsCount(mgr2) == 0,
                     "10 add:拉取失败不留痕(未写 config、未写清单)")

        // — 空内容失败 —
        let store3 = FakeSubscriptionStore()
        let src3 = FakeSubscriptionSourcePort()
        src3.program(source: "empty", [.success(Data())])
        let mgr3 = makeManager(store: store3, source: src3, http: FakeHTTPPort())
        report.check(isFailure(mgr3.add(name: "Y", source: "empty")), "10 add:空内容 → 业务失败")
        report.check(store3.saveConfigCalls.isEmpty && subsCount(mgr3) == 0, "10 add:空内容不留痕")
    }

    // ============ ③ activate(成功切换 + 幂等不重载 + 不存在 + active 不变)============
    private static func testSubscriptionActivate(_ report: inout TestReport) {
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: "PUT", statusCode: 204)   // reload 成功
        let mgr = makeManager(store: store, source: src, http: http)

        src.program(source: "srcA", [.success(Data("A".utf8))])
        src.program(source: "srcB", [.success(Data("B".utf8))])
        guard let idA = idOf(mgr.add(name: "A", source: "srcA")),
              let idB = idOf(mgr.add(name: "B", source: "srcB")) else {
            report.check(false, "10 activate:前置 add 应返回 id"); return
        }

        var actOK = false
        if case .success(let out) = mgr.activate(id: idA) { actOK = out.objectValue?["activated"] == .bool(true) }
        report.check(actOK && activeOf(mgr) == .string(idA), "10 activate:激活 A 成功(activated=true,active→idA)")
        let reloadAfterA = putConfigsCount(http)

        let idem = mgr.activate(id: idA)
        report.check(!isFailure(idem) && putConfigsCount(http) == reloadAfterA,
                     "10 activate:已是 active 幂等成功且不重复重载(reload 计数不变)")

        report.check(!isFailure(mgr.activate(id: idB)) && activeOf(mgr) == .string(idB),
                     "10 activate:切到 B 成功(active→idB)")
        report.check(putConfigsCount(http) == reloadAfterA + 1, "10 activate:切换触发一次内核重载")

        report.check(isFailure(mgr.activate(id: "zzz-does-not-exist")) && activeOf(mgr) == .string(idB),
                     "10 activate:不存在 id → 业务失败且 active 不变")
    }

    // ============ ③' activate 重载失败 → active 不变(无半态)============
    private static func testSubscriptionActivateReloadFails(_ report: inout TestReport) {
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: "PUT", statusCode: 500)   // reload 失败
        let mgr = makeManager(store: store, source: src, http: http)
        src.program(source: "srcA", [.success(Data("A".utf8))])
        guard let idA = idOf(mgr.add(name: "A", source: "srcA")) else {
            report.check(false, "10 activate 重载失败:前置 add 应返回 id"); return
        }
        report.check(isFailure(mgr.activate(id: idA)), "10 activate:内核重载失败 → 业务失败")
        report.check(activeOf(mgr) == .null, "10 activate:重载失败后 active 不变(无半态,仍未激活)")
    }

    // ============ ④ update 正常 + 不存在 + 拉取失败/空内容什么都不改 ============
    private static func testSubscriptionUpdate(_ report: inout TestReport) {
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: "PUT", statusCode: 204)
        let mgr = makeManager(store: store, source: src, http: http)

        src.program(source: "srcA", [.success(Data("v1".utf8))])
        guard let idA = idOf(mgr.add(name: "A", source: "srcA")) else {
            report.check(false, "10 update:前置 add 应返回 id"); return
        }
        _ = mgr.activate(id: idA)
        let reloadBefore = putConfigsCount(http)
        src.program(source: "srcA", [.success(Data("v2".utf8))])
        var updOK = false
        if case .success(let out) = mgr.update(id: idA) {
            updOK = out.objectValue?["updated"] == .bool(true) && out.objectValue?["lastUpdatedAt"] != nil
        }
        report.check(updOK, "10 update:激活项更新成功(updated=true,带 lastUpdatedAt)")
        report.check(store.currentConfig(id: idA) == Data("v2".utf8), "10 update:配置物化为新字节 v2")
        report.check(putConfigsCount(http) == reloadBefore + 1, "10 update:激活项更新触发一次内核重载(生效)")

        // 不存在 → 业务失败。
        let empty = makeManager(store: FakeSubscriptionStore(), source: FakeSubscriptionSourcePort(), http: FakeHTTPPort())
        report.check(isFailure(empty.update(id: "nope")), "10 update:不存在 id → 业务失败")

        // 拉取失败 → 什么都没改(未写 config)。非激活项(activeId=nil)。
        let s2 = FakeSubscriptionStore(catalog: encodeCatalog(
            SubscriptionCatalog(subscriptions: [Subscription(id: "a", name: "A", source: "srcA")], activeId: nil)),
            configs: ["a": Data("v1".utf8)])
        let src2 = FakeSubscriptionSourcePort()
        src2.program(source: "srcA", [.failure(SubscriptionSourceError.fetchFailed("不可达"))])
        let mgr2 = makeManager(store: s2, source: src2, http: FakeHTTPPort())
        report.check(isFailure(mgr2.update(id: "a")), "10 update:拉取失败 → 业务失败")
        report.check(s2.saveConfigCalls.isEmpty && s2.currentConfig(id: "a") == Data("v1".utf8),
                     "10 update:拉取失败什么都没改(未写 config,旧配置原封不动)")

        // 空内容 → 什么都没改。
        let s3 = FakeSubscriptionStore(catalog: encodeCatalog(
            SubscriptionCatalog(subscriptions: [Subscription(id: "a", name: "A", source: "srcA")], activeId: nil)),
            configs: ["a": Data("v1".utf8)])
        let src3 = FakeSubscriptionSourcePort()
        src3.program(source: "srcA", [.success(Data())])
        let mgr3 = makeManager(store: s3, source: src3, http: FakeHTTPPort())
        report.check(isFailure(mgr3.update(id: "a")), "10 update:空内容 → 业务失败")
        report.check(s3.saveConfigCalls.isEmpty && s3.currentConfig(id: "a") == Data("v1".utf8),
                     "10 update:空内容什么都没改(未写 config)")
    }

    // ============ ④' update 回滚(激活项新配置重载失败 → 配置回退旧 + 尝试重载旧 + 业务失败)============
    private static func testSubscriptionUpdateRollback(_ report: inout TestReport) {
        let store = FakeSubscriptionStore(catalog: encodeCatalog(
            SubscriptionCatalog(subscriptions: [Subscription(id: "a", name: "A", source: "srcA", lastUpdatedAt: 100)], activeId: "a")),
            configs: ["a": Data("OLD".utf8)])
        let src = FakeSubscriptionSourcePort()
        src.program(source: "srcA", [.success(Data("NEW".utf8))])
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: "PUT", statusCode: 500)   // 新配置重载必失败
        let mgr = makeManager(store: store, source: src, http: http)

        let r = mgr.update(id: "a")
        report.check(isFailure(r), "10 update 回滚:激活项重载失败 → 业务失败")
        report.check(store.currentConfig(id: "a") == Data("OLD".utf8),
                     "10 update 回滚:配置回退为旧 OLD(内核带回已知 good)")
        report.check(store.saveConfigCalls.map { $0.id } == ["a", "a"]
                     && store.saveConfigCalls.last?.data == Data("OLD".utf8),
                     "10 update 回滚:saveConfig 序列 [新,旧] 且末次写回旧字节")
        report.check(putConfigsCount(http) == 2, "10 update 回滚:尝试重载旧配置(reload 共 2 次:新失败 + 回滚旧)")
    }

    // ============ ④'' F6 update 回滚自身失败(写回旧配置也失败 → 不再发第二次 reload,如实措辞)============
    private static func testSubscriptionUpdateRollbackSaveFails(_ report: inout TestReport) {
        let store = FakeSubscriptionStore(catalog: encodeCatalog(
            SubscriptionCatalog(subscriptions: [Subscription(id: "a", name: "A", source: "srcA")], activeId: "a")),
            configs: ["a": Data("OLD".utf8)])
        store.saveConfigFailAtCall = 2   // 第 1 次(写 NEW)成功,第 2 次(回滚写 OLD)失败
        let src = FakeSubscriptionSourcePort()
        src.program(source: "srcA", [.success(Data("NEW".utf8))])
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: "PUT", statusCode: 500)
        let mgr = makeManager(store: store, source: src, http: http)

        report.check(isFailure(mgr.update(id: "a")), "10 F6 回滚自身失败:业务失败")
        // 回滚写旧失败 → 不再发第二次 reload(putConfigs 只 1 次:新配置那次失败的)。
        report.check(putConfigsCount(http) == 1, "10 F6 回滚自身失败:写回旧失败则不再发第二次 reload(reload 仅 1 次)")
        // saveConfigCalls 只记成功的第 1 次(NEW);第 2 次抛错未记。
        report.check(store.saveConfigCalls.map { $0.id } == ["a"], "10 F6 回滚自身失败:仅第一次 saveConfig(NEW)成功,回滚写未记录")
    }

    // ============ ⑤ F5 catalog 损坏 → add/list 均 capabilityFailed 且未 saveCatalog 覆盖 ============
    private static func testSubscriptionCatalogCorruption(_ report: inout TestReport) {
        // 预置一坨无法解码为 SubscriptionCatalog 的字节。
        let store = FakeSubscriptionStore(catalog: Data("{ this is not valid catalog json ".utf8))
        let src = FakeSubscriptionSourcePort()
        src.program(source: "s", [.success(Data("X".utf8))])
        let mgr = makeManager(store: store, source: src, http: FakeHTTPPort())

        report.check(errCode(mgr.list()) == WireErrorCode.capabilityFailed, "10 F5 损坏清单:list → capabilityFailed(不臆造空清单)")
        report.check(errCode(mgr.add(name: "A", source: "s")) == WireErrorCode.capabilityFailed, "10 F5 损坏清单:add → capabilityFailed")
        // 关键:绝不用空清单覆盖损坏文件(saveCatalog 未被调用);add 也未 fetch/写 config。
        report.check(store.saveCatalogCount == 0, "10 F5 损坏清单:未发生 saveCatalog 覆盖(不抹掉用户数据)")
        report.check(store.saveConfigCalls.isEmpty && src.fetchCalls.isEmpty, "10 F5 损坏清单:add 在损坏探测处即止(未 fetch、未写 config)")
    }

    // ============ ⑥ 四能力暴露(风险级 + 必填参数)============
    private static func testSubscriptionCapabilityExposure(_ report: inout TestReport) {
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(),
                                 networkConfigPort: FakeNetworkConfigPort(initial: []),
                                 kernelPath: nil, controlPort: 9090)
        let caps = plugin.capabilities()
        func desc(_ id: String) -> CapabilityDescriptor? { caps.first { $0.descriptor.id == id }?.descriptor }

        let l = desc("proxy.subscription.list")
        report.check(l?.risk == .safe && l?.parameters.isEmpty == true, "10 能力暴露:proxy.subscription.list=safe 无入参")
        let a = desc("proxy.subscription.activate")
        report.check(a?.risk == .normal && a?.parameters.first { $0.name == "id" }?.required == true,
                     "10 能力暴露:proxy.subscription.activate=normal 需必填 id")
        let u = desc("proxy.subscription.update")
        report.check(u?.risk == .normal && u?.parameters.first { $0.name == "id" }?.required == true,
                     "10 能力暴露:proxy.subscription.update=normal 需必填 id")
        let add = desc("proxy.subscription.add")
        report.check(add?.risk == .dangerous
                     && add?.parameters.map { $0.name } == ["name", "source"]
                     && add?.parameters.allSatisfy { $0.required } == true,
                     "10 能力暴露:proxy.subscription.add=dangerous 需必填 name+source")
    }
}
