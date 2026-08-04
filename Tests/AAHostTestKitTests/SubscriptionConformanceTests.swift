// 17 票:从 `AAHostTestKit.SubscriptionConformanceTests` 迁到 swift-testing(迁移口径见 RegistryConformanceTests.swift 头注)。
//
// 10 票订阅管理纯逻辑测试(注入假 SubscriptionStore / SubscriptionSourcePort + 假 HTTPPort,
//   绝不碰真 AppSupport、真网络、真内核)。

import Foundation
import Testing
import AAContracts
import AAPluginSDK
import PluginProxy
import AAHostTestKit

@Suite("10 订阅管理状态机纯逻辑(id 生成 / list / add / activate / update+回滚 / 损坏清单 / 能力暴露)")
struct SubscriptionConformanceTests {

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
        http.requests.filter { $0.method == .put && $0.url.hasSuffix("/configs") }.count
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

    /// 造一个「A 已 add」的管理器(add 场景的共同前置)。
    private static func addFixture() -> (mgr: SubscriptionManager, store: FakeSubscriptionStore, src: FakeSubscriptionSourcePort) {
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        let mgr = makeManager(store: store, source: src, http: FakeHTTPPort())
        src.program(source: "file:///s/a.conf", [.success(Data("CONFIG-A1".utf8))])
        return (mgr, store, src)
    }

    /// 造一个「A、B 两条订阅都已 add、reload 会成功」的管理器(activate 场景的共同前置)。
    private static func activateFixture() throws -> (mgr: SubscriptionManager, http: FakeHTTPPort, idA: String, idB: String) {
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: .put, statusCode: 204)   // reload 成功
        let mgr = makeManager(store: store, source: src, http: http)
        src.program(source: "srcA", [.success(Data("A".utf8))])
        src.program(source: "srcB", [.success(Data("B".utf8))])
        let idA = try #require(idOf(mgr.add(name: "A", source: "srcA")), "10 activate:前置 add 应返回 id")
        let idB = try #require(idOf(mgr.add(name: "B", source: "srcB")), "10 activate:前置 add(B)应返回 id")
        return (mgr, http, idA, idB)
    }

    // ============ F1:id 生成(确定性 + 抗碰撞 + 空名拒绝)============

    @Test("10 F1 id:同名(大小写不敏感)→ 同 id / 10 F1 id:两个不同非 ASCII 名 → 不同 id(消除碰撞)")
    func subscriptionIDGeneration() {
        #expect(SubscriptionManager.makeID("Sub A") == SubscriptionManager.makeID("sub a")
                && SubscriptionManager.makeID("Sub A") != nil,
                "10 F1 id:同名(大小写不敏感)→ 同 id")
        // 两个不同**纯非 ASCII**名 → 不同 id(旧 normalize 会都塌成 '---' 碰撞)。
        let jiaID = SubscriptionManager.makeID("机场甲")
        let yiID = SubscriptionManager.makeID("机场乙")
        #expect(jiaID != nil && yiID != nil && jiaID != yiID,
                "10 F1 id:两个不同非 ASCII 名 → 不同 id(消除碰撞)")
        #expect((jiaID?.isEmpty == false),
                "10 F1 id:纯非 ASCII 名 → id 非空(带确定性哈希后缀)")
        #expect(SubscriptionManager.makeID("") == nil && SubscriptionManager.makeID("   ") == nil,
                "10 F1 id:空/纯空白名 → nil")
    }

    @Test("10 F1 add:空/纯空白名 → invalidParams(退出码6) / 10 F1 add:空名先于任何 I/O 拒绝(未 fetch、未写 config/清单)")
    func subscriptionAddEmptyName() {
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        src.program(source: "s", [.success(Data("X".utf8))])
        let mgr = Self.makeManager(store: store, source: src, http: FakeHTTPPort())
        let r = mgr.add(name: "   ", source: "s")
        #expect(Self.errCode(r) == WireErrorCode.invalidParams, "10 F1 add:空/纯空白名 → invalidParams(退出码6)")
        #expect(store.saveConfigCalls.isEmpty && store.saveCatalogCount == 0 && src.fetchCalls.isEmpty,
                "10 F1 add:空名先于任何 I/O 拒绝(未 fetch、未写 config/清单)")
    }

    // ============ ① list ============

    @Test("10 list:空清单 → active=null、subscriptions 为空")
    func subscriptionList() {
        let store = FakeSubscriptionStore()
        let mgr = Self.makeManager(store: store, source: FakeSubscriptionSourcePort(), http: FakeHTTPPort())
        if case .success(let out) = mgr.list() {
            let active = out.objectValue?["active"]
            let subsEmpty: Bool = { if case let .array(a)? = out.objectValue?["subscriptions"] { return a.isEmpty }; return false }()
            #expect(active == .null && subsEmpty, "10 list:空清单 → active=null、subscriptions 为空")
        } else {
            Issue.record("10 list:空清单应成功返回")
        }
    }

    // ============ ② add(upsert 替换源 / 失败不留痕 / 不自动激活)============

    @Test("10 add:新增订阅成功(added=true,id 带 slug 前缀 sub-a-) / 10 add:add 后 active 仍为 null(不自动激活)")
    func subscriptionAdd() {
        let (mgr, store, _) = Self.addFixture()
        let addR = mgr.add(name: "Sub A", source: "file:///s/a.conf")
        let idA = Self.idOf(addR)
        var addOK = false
        if case .success(let out) = addR {
            addOK = (idA?.hasPrefix("sub-a-") == true) && out.objectValue?["added"] == .bool(true)
        }
        #expect(addOK, "10 add:新增订阅成功(added=true,id 带 slug 前缀 sub-a-)")
        #expect(Self.activeOf(mgr) == .null, "10 add:add 后 active 仍为 null(不自动激活)")
        #expect(Self.subsCount(mgr) == 1, "10 add:list 反映新增(1 条)")
        #expect(idA != nil && store.currentConfig(id: idA!) == Data("CONFIG-A1".utf8), "10 add:配置字节被物化")
    }

    @Test("10 add:同 name 再 add → 同 id(确定性) / 10 add:upsert 同 name 覆盖=替换源(仍 1 条)")
    func subscriptionAddUpsert() {
        let (mgr, store, src) = Self.addFixture()
        let idA = Self.idOf(mgr.add(name: "Sub A", source: "file:///s/a.conf"))

        // 同 name 再 add(不同源)→ upsert 覆盖(仍 1 条,id 不变,source/config 换新)。
        src.program(source: "file:///s/a2.conf", [.success(Data("CONFIG-A2".utf8))])
        let addR2 = mgr.add(name: "Sub A", source: "file:///s/a2.conf")
        #expect(Self.idOf(addR2) == idA, "10 add:同 name 再 add → 同 id(确定性)")
        #expect(Self.subsCount(mgr) == 1, "10 add:upsert 同 name 覆盖=替换源(仍 1 条)")
        #expect(idA != nil && store.currentConfig(id: idA!) == Data("CONFIG-A2".utf8), "10 add:替换源后 config 物化为新字节")
    }

    @Test("10 add:拉取失败不留痕(未写 config、未写清单)")
    func subscriptionAddFetchFailureLeavesNoTrace() {
        let store2 = FakeSubscriptionStore()
        let src2 = FakeSubscriptionSourcePort()
        src2.program(source: "bad", [.failure(SubscriptionSourceError.fetchFailed("模拟不可达"))])
        let mgr2 = Self.makeManager(store: store2, source: src2, http: FakeHTTPPort())
        #expect(Self.isFailure(mgr2.add(name: "X", source: "bad")), "10 add:拉取失败 → 业务失败")
        #expect(store2.saveConfigCalls.isEmpty && store2.saveCatalogCount == 0 && Self.subsCount(mgr2) == 0,
                "10 add:拉取失败不留痕(未写 config、未写清单)")
    }

    @Test("10 add:空内容 → 业务失败")
    func subscriptionAddEmptyContent() {
        let store3 = FakeSubscriptionStore()
        let src3 = FakeSubscriptionSourcePort()
        src3.program(source: "empty", [.success(Data())])
        let mgr3 = Self.makeManager(store: store3, source: src3, http: FakeHTTPPort())
        #expect(Self.isFailure(mgr3.add(name: "Y", source: "empty")), "10 add:空内容 → 业务失败")
        #expect(store3.saveConfigCalls.isEmpty && Self.subsCount(mgr3) == 0, "10 add:空内容不留痕")
    }

    // ============ ③ activate ============

    @Test("10 activate:激活 A 成功(activated=true,active→idA) / 10 activate:已是 active 幂等成功且不重复重载(reload 计数不变)")
    func subscriptionActivateAndIdempotence() throws {
        let f = try Self.activateFixture()
        var actOK = false
        if case .success(let out) = f.mgr.activate(id: f.idA) { actOK = out.objectValue?["activated"] == .bool(true) }
        #expect(actOK && Self.activeOf(f.mgr) == .string(f.idA), "10 activate:激活 A 成功(activated=true,active→idA)")
        let reloadAfterA = Self.putConfigsCount(f.http)

        let idem = f.mgr.activate(id: f.idA)
        #expect(!Self.isFailure(idem) && Self.putConfigsCount(f.http) == reloadAfterA,
                "10 activate:已是 active 幂等成功且不重复重载(reload 计数不变)")
    }

    @Test("10 activate:切到 B 成功(active→idB) / 10 activate:不存在 id → 业务失败且 active 不变")
    func subscriptionActivateSwitchAndUnknown() throws {
        let f = try Self.activateFixture()
        _ = f.mgr.activate(id: f.idA)
        let reloadAfterA = Self.putConfigsCount(f.http)

        #expect(!Self.isFailure(f.mgr.activate(id: f.idB)) && Self.activeOf(f.mgr) == .string(f.idB),
                "10 activate:切到 B 成功(active→idB)")
        #expect(Self.putConfigsCount(f.http) == reloadAfterA + 1, "10 activate:切换触发一次内核重载")

        #expect(Self.isFailure(f.mgr.activate(id: "zzz-does-not-exist")) && Self.activeOf(f.mgr) == .string(f.idB),
                "10 activate:不存在 id → 业务失败且 active 不变")
    }

    @Test("10 activate:重载失败后 active 不变(无半态,仍未激活)")
    func subscriptionActivateReloadFails() throws {
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: .put, statusCode: 500)   // reload 失败
        let mgr = Self.makeManager(store: store, source: src, http: http)
        src.program(source: "srcA", [.success(Data("A".utf8))])
        let idA = try #require(Self.idOf(mgr.add(name: "A", source: "srcA")), "10 activate 重载失败:前置 add 应返回 id")
        #expect(Self.isFailure(mgr.activate(id: idA)), "10 activate:内核重载失败 → 业务失败")
        #expect(Self.activeOf(mgr) == .null, "10 activate:重载失败后 active 不变(无半态,仍未激活)")
    }

    // ============ ④ update ============

    @Test("10 update:激活项更新成功(updated=true,带 lastUpdatedAt)")
    func subscriptionUpdate() throws {
        let store = FakeSubscriptionStore()
        let src = FakeSubscriptionSourcePort()
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: .put, statusCode: 204)
        let mgr = Self.makeManager(store: store, source: src, http: http)

        src.program(source: "srcA", [.success(Data("v1".utf8))])
        let idA = try #require(Self.idOf(mgr.add(name: "A", source: "srcA")), "10 update:前置 add 应返回 id")
        _ = mgr.activate(id: idA)
        let reloadBefore = Self.putConfigsCount(http)
        src.program(source: "srcA", [.success(Data("v2".utf8))])
        var updOK = false
        if case .success(let out) = mgr.update(id: idA) {
            updOK = out.objectValue?["updated"] == .bool(true) && out.objectValue?["lastUpdatedAt"] != nil
        }
        #expect(updOK, "10 update:激活项更新成功(updated=true,带 lastUpdatedAt)")
        #expect(store.currentConfig(id: idA) == Data("v2".utf8), "10 update:配置物化为新字节 v2")
        #expect(Self.putConfigsCount(http) == reloadBefore + 1, "10 update:激活项更新触发一次内核重载(生效)")

        // 不存在 → 业务失败。
        let empty = Self.makeManager(store: FakeSubscriptionStore(), source: FakeSubscriptionSourcePort(), http: FakeHTTPPort())
        #expect(Self.isFailure(empty.update(id: "nope")), "10 update:不存在 id → 业务失败")
    }

    @Test("10 update:拉取失败什么都没改(未写 config,旧配置原封不动)")
    func subscriptionUpdateFetchFailure() {
        let s2 = FakeSubscriptionStore(catalog: Self.encodeCatalog(
            SubscriptionCatalog(subscriptions: [Subscription(id: "a", name: "A", source: "srcA")], activeId: nil)),
            configs: ["a": Data("v1".utf8)])
        let src2 = FakeSubscriptionSourcePort()
        src2.program(source: "srcA", [.failure(SubscriptionSourceError.fetchFailed("不可达"))])
        let mgr2 = Self.makeManager(store: s2, source: src2, http: FakeHTTPPort())
        #expect(Self.isFailure(mgr2.update(id: "a")), "10 update:拉取失败 → 业务失败")
        #expect(s2.saveConfigCalls.isEmpty && s2.currentConfig(id: "a") == Data("v1".utf8),
                "10 update:拉取失败什么都没改(未写 config,旧配置原封不动)")
    }

    @Test("10 update:空内容什么都没改(未写 config)")
    func subscriptionUpdateEmptyContent() {
        let s3 = FakeSubscriptionStore(catalog: Self.encodeCatalog(
            SubscriptionCatalog(subscriptions: [Subscription(id: "a", name: "A", source: "srcA")], activeId: nil)),
            configs: ["a": Data("v1".utf8)])
        let src3 = FakeSubscriptionSourcePort()
        src3.program(source: "srcA", [.success(Data())])
        let mgr3 = Self.makeManager(store: s3, source: src3, http: FakeHTTPPort())
        #expect(Self.isFailure(mgr3.update(id: "a")), "10 update:空内容 → 业务失败")
        #expect(s3.saveConfigCalls.isEmpty && s3.currentConfig(id: "a") == Data("v1".utf8),
                "10 update:空内容什么都没改(未写 config)")
    }

    // ============ ④' update 回滚 ============

    @Test("10 update 回滚:配置回退为旧 OLD(内核带回已知 good) / 10 update 回滚:saveConfig 序列 [新,旧] 且末次写回旧字节 / 10 update 回滚:尝试重载旧配置(reload 共 2 次:新失败 + 回滚旧)")
    func subscriptionUpdateRollback() {
        let store = FakeSubscriptionStore(catalog: Self.encodeCatalog(
            SubscriptionCatalog(subscriptions: [Subscription(id: "a", name: "A", source: "srcA", lastUpdatedAt: 100)], activeId: "a")),
            configs: ["a": Data("OLD".utf8)])
        let src = FakeSubscriptionSourcePort()
        src.program(source: "srcA", [.success(Data("NEW".utf8))])
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: .put, statusCode: 500)   // 新配置重载必失败
        let mgr = Self.makeManager(store: store, source: src, http: http)

        let r = mgr.update(id: "a")
        #expect(Self.isFailure(r), "10 update 回滚:激活项重载失败 → 业务失败")
        #expect(store.currentConfig(id: "a") == Data("OLD".utf8),
                "10 update 回滚:配置回退为旧 OLD(内核带回已知 good)")
        #expect(store.saveConfigCalls.map { $0.id } == ["a", "a"]
                && store.saveConfigCalls.last?.data == Data("OLD".utf8),
                "10 update 回滚:saveConfig 序列 [新,旧] 且末次写回旧字节")
        #expect(Self.putConfigsCount(http) == 2, "10 update 回滚:尝试重载旧配置(reload 共 2 次:新失败 + 回滚旧)")
    }

    // ============ ④'' F6 update 回滚自身失败 ============

    @Test("10 F6 回滚自身失败:写回旧失败则不再发第二次 reload(reload 仅 1 次)")
    func subscriptionUpdateRollbackSaveFails() {
        let store = FakeSubscriptionStore(catalog: Self.encodeCatalog(
            SubscriptionCatalog(subscriptions: [Subscription(id: "a", name: "A", source: "srcA")], activeId: "a")),
            configs: ["a": Data("OLD".utf8)])
        store.saveConfigFailAtCall = 2   // 第 1 次(写 NEW)成功,第 2 次(回滚写 OLD)失败
        let src = FakeSubscriptionSourcePort()
        src.program(source: "srcA", [.success(Data("NEW".utf8))])
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", method: .put, statusCode: 500)
        let mgr = Self.makeManager(store: store, source: src, http: http)

        #expect(Self.isFailure(mgr.update(id: "a")), "10 F6 回滚自身失败:业务失败")
        #expect(Self.putConfigsCount(http) == 1, "10 F6 回滚自身失败:写回旧失败则不再发第二次 reload(reload 仅 1 次)")
        #expect(store.saveConfigCalls.map { $0.id } == ["a"], "10 F6 回滚自身失败:仅第一次 saveConfig(NEW)成功,回滚写未记录")
    }

    // ============ ⑤ F5 catalog 损坏 ============

    @Test("10 F5 损坏清单:list → capabilityFailed(不臆造空清单) / 10 F5 损坏清单:未发生 saveCatalog 覆盖(不抹掉用户数据)")
    func subscriptionCatalogCorruption() {
        // 预置一坨无法解码为 SubscriptionCatalog 的字节。
        let store = FakeSubscriptionStore(catalog: Data("{ this is not valid catalog json ".utf8))
        let src = FakeSubscriptionSourcePort()
        src.program(source: "s", [.success(Data("X".utf8))])
        let mgr = Self.makeManager(store: store, source: src, http: FakeHTTPPort())

        #expect(Self.errCode(mgr.list()) == WireErrorCode.capabilityFailed, "10 F5 损坏清单:list → capabilityFailed(不臆造空清单)")
        #expect(Self.errCode(mgr.add(name: "A", source: "s")) == WireErrorCode.capabilityFailed, "10 F5 损坏清单:add → capabilityFailed")
        #expect(store.saveCatalogCount == 0, "10 F5 损坏清单:未发生 saveCatalog 覆盖(不抹掉用户数据)")
        #expect(store.saveConfigCalls.isEmpty && src.fetchCalls.isEmpty, "10 F5 损坏清单:add 在损坏探测处即止(未 fetch、未写 config)")
    }

    // ============ ⑥ 四能力暴露(风险级 + 必填参数)============

    @Test("10 能力暴露:proxy.subscription.add=dangerous 需必填 name+source(并逐条核 list/activate/update 的风险档)")
    func subscriptionCapabilityExposure() {
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(),
                                 networkConfigPort: FakeNetworkConfigPort(initial: []),
                                 kernelPath: nil, controlPort: 9090)
        let caps = plugin.capabilities()
        func desc(_ id: String) -> CapabilityDescriptor? { caps.first { $0.descriptor.id == id }?.descriptor }

        let l = desc("proxy.subscription.list")
        #expect(l?.risk == .safe && l?.parameters.isEmpty == true, "10 能力暴露:proxy.subscription.list=safe 无入参")
        let a = desc("proxy.subscription.activate")
        #expect(a?.risk == .normal && a?.parameters.first { $0.name == "id" }?.required == true,
                "10 能力暴露:proxy.subscription.activate=normal 需必填 id")
        let u = desc("proxy.subscription.update")
        #expect(u?.risk == .normal && u?.parameters.first { $0.name == "id" }?.required == true,
                "10 能力暴露:proxy.subscription.update=normal 需必填 id")
        let add = desc("proxy.subscription.add")
        #expect(add?.risk == .dangerous
                && add?.parameters.map { $0.name } == ["name", "source"]
                && add?.parameters.allSatisfy { $0.required } == true,
                "10 能力暴露:proxy.subscription.add=dangerous 需必填 name+source")
    }
}
