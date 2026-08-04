// 17 票:从 `AAHostTestKit.SystemProxyConformanceTests` 迁到 swift-testing(迁移口径见 RegistryConformanceTests.swift 头注)。
//
// 07 票系统代理接管/还原纯逻辑测试(注入内存假 NetworkConfigPort,**绝不碰真 networksetup**)。
// 依赖边:AAHostTestKitTests → AAHostTestKit(假件)、AAPluginSDK、PluginProxy、AAContracts。

import Foundation
import Testing
import AAContracts
import AAPluginSDK
import PluginProxy
import AAHostTestKit

@Suite("07 系统代理快照 / 接管 / 还原纯逻辑(注入内存假 NetworkConfigPort)")
struct SystemProxyConformanceTests {

    /// 构造一份「典型」初始系统代理状态:Wi-Fi 全关;Ethernet 原本就有第三方代理(HTTP/HTTPS 指向 203.0.113.9:8080,SOCKS 关)。
    static func sampleInitialState() -> [ServiceProxyState] {
        [
            ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off),
            ServiceProxyState(service: "Ethernet",
                              http: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                              https: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                              socks: .off)
        ]
    }

    /// 内核 REST 报 mixed-port=7890(enable 读它作为接管目标端口)。
    private static func kernelReadyHTTP() -> FakeHTTPPort {
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", json: #"{"mode":"rule","mixed-port":7890,"port":0}"#)
        return http
    }

    // ============ ① SystemProxyController:capture → takeover → restore 全纯逻辑 ============

    @Test("07 快照:capture 捕获全部服务(Wi-Fi + Ethernet) / 07 快照:capture 记录 Ethernet 原第三方 HTTP 代理(开关+host+port)")
    func controllerCapture() throws {
        let net = FakeNetworkConfigPort(initial: Self.sampleInitialState())
        let controller = SystemProxyController(net: net)
        let snapshot = try #require(try? controller.capture(), "07 快照:capture 应成功")

        #expect(snapshot.services.count == 2, "07 快照:capture 捕获全部服务(Wi-Fi + Ethernet)")
        let ethSnap = snapshot.services.first { $0.service == "Ethernet" }
        #expect(ethSnap?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                "07 快照:capture 记录 Ethernet 原第三方 HTTP 代理(开关+host+port)")
        #expect(ethSnap?.socks == .off, "07 快照:capture 记录 Ethernet 原 SOCKS 为关闭")
        let wifiSnap = snapshot.services.first { $0.service == "Wi-Fi" }
        #expect(wifiSnap?.http == .off, "07 快照:capture 记录 Wi-Fi 原状态为关闭")
    }

    @Test("07 接管:enable 后各服务的 HTTP/HTTPS/SOCKS 均指向内核端口 127.0.0.1:7890")
    func controllerTakeover() throws {
        let net = FakeNetworkConfigPort(initial: Self.sampleInitialState())
        let controller = SystemProxyController(net: net)
        let snapshot = try #require(try? controller.capture(), "07 接管:前置 capture 应成功")

        let takeoverSnap = (try? controller.takeover(host: "127.0.0.1", port: 7890, into: nil)) ?? snapshot
        #expect(takeoverSnap == snapshot, "07 接管:takeover 并入的快照(无新服务)== capture 全量快照")
        for service in ["Wi-Fi", "Ethernet"] {
            let s = net.currentState(service: service)
            let allToKernel = [s?.http, s?.https, s?.socks].allSatisfy {
                $0 == ProxySetting(enabled: true, host: "127.0.0.1", port: 7890)
            }
            #expect(allToKernel, "07 接管:enable 后 \(service) 的 HTTP/HTTPS/SOCKS 均指向内核端口 127.0.0.1:7890")
        }
        #expect(net.currentState(service: "Ethernet")?.http.host == "127.0.0.1",
                "07 接管:Ethernet 原第三方代理被内核端口覆盖")
    }

    @Test("07 还原:原本第三方代理→精确还原成第三方 203.0.113.9:8080(不是一律关闭) / 07 还原:Ethernet 原本关闭的 SOCKS → 还原成关闭 / 07 还原:还原后再次快照 == 接管前快照(终态精确复原)")
    func controllerRestore() throws {
        let net = FakeNetworkConfigPort(initial: Self.sampleInitialState())
        let controller = SystemProxyController(net: net)
        let snapshot = try #require(try? controller.capture(), "07 还原:前置 capture 应成功")
        _ = try? controller.takeover(host: "127.0.0.1", port: 7890, into: nil)

        try? controller.restore(snapshot)
        let ethAfter = net.currentState(service: "Ethernet")
        #expect(ethAfter?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                "07 还原:原本第三方代理→精确还原成第三方 203.0.113.9:8080(不是一律关闭)")
        #expect(ethAfter?.https == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                "07 还原:Ethernet HTTPS 亦精确还原成第三方")
        #expect(ethAfter?.socks == .off, "07 还原:Ethernet 原本关闭的 SOCKS → 还原成关闭")
        let wifiAfter = net.currentState(service: "Wi-Fi")
        #expect(wifiAfter?.http == .off && wifiAfter?.https == .off && wifiAfter?.socks == .off,
                "07 还原:原本全关的 Wi-Fi → 精确还原成全关")
        #expect((try? controller.capture()) == snapshot,
                "07 还原:还原后再次快照 == 接管前快照(终态精确复原)")
    }

    // ============ ② ProxyPlugin.enable/disable 幂等 ============

    @Test("07 幂等:重复 enable 不覆盖首次快照(disable 精确还原到最初的第三方代理,非 7890)")
    func pluginEnableDisableIdempotent() {
        let net = FakeNetworkConfigPort(initial: Self.sampleInitialState())
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: Self.kernelReadyHTTP(),
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090)

        // 首次 enable:快照 = 最初状态,接管指向 7890。
        switch plugin.enableSystemProxy() {
        case .success(let out):
            #expect(out.objectValue?["enabled"] == .bool(true), "07 接管:首次 enable 成功 enabled=true")
            #expect(out.objectValue?["port"] == .number(7890), "07 接管:enable 指向内核 mixed-port 7890")
        case .failure:
            Issue.record("07 接管:首次 enable 应成功")
        }
        #expect(net.currentState(service: "Ethernet")?.http.host == "127.0.0.1",
                "07 接管:enable 后 Ethernet 指向内核端口")

        // 重复 enable:不应覆盖首次快照(内存态此刻已是「全指向 7890」,若被当成新快照,disable 就会还原成 7890 而非最初)。
        _ = plugin.enableSystemProxy()

        switch plugin.disableSystemProxy() {
        case .success(let out):
            #expect(out.objectValue?["restored"] == .bool(true), "07 还原:disable 报告已还原 restored=true")
        case .failure:
            Issue.record("07 还原:disable 应成功")
        }
        #expect(net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                "07 幂等:重复 enable 不覆盖首次快照(disable 精确还原到最初的第三方代理,非 7890)")
        #expect(net.currentState(service: "Wi-Fi")?.http == .off, "07 还原:disable 后 Wi-Fi 还原成关闭")

        // disable 幂等:已还原后再 disable → no-op 成功(restored=false)。
        switch plugin.disableSystemProxy() {
        case .success(let out):
            #expect(out.objectValue?["restored"] == .bool(false), "07 幂等:未接管时 disable → no-op 成功(restored=false)")
        case .failure:
            Issue.record("07 幂等:重复 disable 应 no-op 成功")
        }
    }

    // ============ ③ 内核端口未就绪 ============

    @Test("07 业务失败:内核端口未就绪时 enable 报 capability_failed(退出码5,不崩)")
    func pluginEnableKernelNotReady() {
        let net = FakeNetworkConfigPort(initial: Self.sampleInitialState())
        let http = FakeHTTPPort()   // 无 /configs 预置 → configs() 抛错 → 读不到 mixed-port
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http,
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090)
        switch plugin.enableSystemProxy() {
        case .success:
            Issue.record("07 业务失败:内核端口未就绪时 enable 不应成功")
        case .failure(let err):
            #expect(err.code == WireErrorCode.capabilityFailed,
                    "07 业务失败:内核端口未就绪时 enable 报 capability_failed(退出码5,不崩)")
        }
        #expect(net.setCalls.isEmpty, "07 业务失败:enable 失败时未对系统代理做任何写入(不留半接管态)")
        #expect(net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                "07 业务失败:enable 失败后 Ethernet 原第三方代理保持不变")
    }

    // ============ ④' 重放快照漏洞回归 ============

    @Test("07 重放漏洞修复:还原覆盖接管后新增的服务→回到接管前第三方代理(不残留指向内核死端口)")
    func enableReplayMergesNewService() {
        // 初始只有 Wi-Fi(全关)。
        let net = FakeNetworkConfigPort(initial: [ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: Self.kernelReadyHTTP(),
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090)

        _ = plugin.enableSystemProxy()   // 首次 enable:快照 = { Wi-Fi off }

        // 模拟接管后**新增**一个服务:Ethernet 原本就有第三方代理(198.51.100.7:3128)。
        net.addService(ServiceProxyState(service: "Ethernet",
                                         http: ProxySetting(enabled: true, host: "198.51.100.7", port: 3128),
                                         https: .off, socks: .off))

        _ = plugin.enableSystemProxy()   // 再 enable(重放)
        #expect(net.currentState(service: "Ethernet")?.http.host == "127.0.0.1",
                "07 重放:再 enable 接管了接管后新增的服务(指向内核端口)")

        _ = plugin.disableSystemProxy()
        #expect(net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "198.51.100.7", port: 3128),
                "07 重放漏洞修复:还原覆盖接管后新增的服务→回到接管前第三方代理(不残留指向内核死端口)")
        #expect(net.currentState(service: "Ethernet")?.https == .off,
                "07 重放:新增服务的其余各类也精确还原(HTTPS 回到关闭)")
        #expect(net.currentState(service: "Wi-Fi")?.http == .off,
                "07 重放:最初的 Wi-Fi 仍精确还原为关闭(既有快照未被覆盖)")
    }

    // ============ P0 事务性回归 ============

    @Test("07 事务:P0 持久化接管清单失败 → fail-closed、系统代理零写入")
    func enablePersistenceFailureDoesNotWrite() {
        let initial = Self.sampleInitialState()
        let net = FakeNetworkConfigPort(initial: initial)
        let store = FakeTakeoverStateStore()
        store.failSaves = true
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: Self.kernelReadyHTTP(),
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090,
                                 stateStore: store)

        if case .failure = plugin.enableSystemProxy() {
            #expect(Bool(true), "07 事务:P0 持久化失败 → enable 失败")
        } else {
            Issue.record("07 事务:P0 持久化失败时 enable 不得成功")
        }
        #expect(net.setCalls.isEmpty && net.disableCalls.isEmpty, "07 事务:P0 持久化失败 → 系统代理零写入")
        #expect((try? SystemProxyController(net: net).capture()) == SystemProxySnapshot(services: initial),
                "07 事务:P0 持久化失败 → 系统代理保持原样")
    }

    @Test("07 事务:P0 接管写到一半失败 → 用完整快照回滚,不留半接管态")
    func enablePartialWriteRollsBack() {
        let initial = Self.sampleInitialState()
        let net = FakeNetworkConfigPort(initial: initial)
        net.failWriteAtCall = 3
        let store = FakeTakeoverStateStore()
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: Self.kernelReadyHTTP(),
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090,
                                 stateStore: store)

        if case .failure = plugin.enableSystemProxy() {
            #expect(Bool(true), "07 事务:P0 部分写失败 → enable 失败")
        } else {
            Issue.record("07 事务:P0 部分写失败时 enable 不得成功")
        }
        #expect((try? SystemProxyController(net: net).capture()) == SystemProxySnapshot(services: initial),
                "07 事务:P0 部分写失败 → 已写代理全部回滚到原快照")
        #expect(!store.isPersisted, "07 事务:P0 部分写失败且回滚成功 → 清除接管标记")
    }

    @Test("07 重放事务:重放失败只撤销本次调用,既有接管仍保持启用")
    func replayFailurePreservesExistingTakeover() {
        let net = FakeNetworkConfigPort(initial: [ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)])
        let store = FakeTakeoverStateStore()
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: Self.kernelReadyHTTP(),
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090, stateStore: store)
        _ = plugin.enableSystemProxy()
        net.addService(ServiceProxyState(service: "Ethernet",
                                         http: ProxySetting(enabled: true, host: "198.51.100.7", port: 3128),
                                         https: .off, socks: .off))
        net.failWriteAtCall = 5 // 首次 enable 3 写;重放第 2 写失败。
        _ = plugin.enableSystemProxy()

        #expect(net.currentState(service: "Wi-Fi")?.http.host == "127.0.0.1",
                "07 重放事务:重放失败后既有 Wi-Fi 接管仍保持启用")
        #expect(net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "198.51.100.7", port: 3128),
                "07 重放事务:重放失败后新增服务恢复到本次调用前状态")
        #expect(store.isPersisted, "07 重放事务:既有接管仍生效时保留持久化标记")
    }

    @Test("07 事务:P0 回滚失败 → 保留接管标记供下次启动自愈")
    func rollbackFailureKeepsMarker() {
        let net = FakeNetworkConfigPort(initial: Self.sampleInitialState())
        net.failWritesStartingAtCall = 3
        let store = FakeTakeoverStateStore()
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: Self.kernelReadyHTTP(),
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090, stateStore: store)
        _ = plugin.enableSystemProxy()
        #expect(store.isPersisted && store.clearCount == 0,
                "07 事务:P0 回滚失败 → 保留接管标记供下次启动自愈")
    }
}
