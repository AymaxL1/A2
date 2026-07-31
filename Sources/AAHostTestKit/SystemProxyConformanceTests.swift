// AAHostTestKit —— 07 票系统代理接管/还原纯逻辑测试(注入内存假 NetworkConfigPort,绝不碰真 networksetup)。
// 依赖边:AAHostTestKit → AAPluginSDK、PluginProxy、AAContracts。
//
// 覆盖阶段 B 断言 1:
//   * 快照 capture 捕获各服务代理原状态;
//   * 接管 takeover → 各服务 HTTP/HTTPS/SOCKS 指向内核端口;
//   * 还原 restore → 精确还原(**原本第三方代理→还原成第三方,不是关闭**;原本关闭→还原关闭);
//   * ProxyPlugin.enable 幂等(重复 enable 不覆盖首次快照)+ 内核端口未就绪时报业务失败(不崩)。

import Foundation
import AAContracts
import AAPluginSDK
import PluginProxy

extension ProxyConformanceTests {

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

    /// 07 票纯逻辑套件入口(由 ProxyConformanceTests.run() 调用,汇入同一 runner 输出)。
    static func testSystemProxyTakeoverRestore(_ report: inout TestReport) {
        testControllerCaptureTakeoverRestore(&report)
        testPluginEnableDisableIdempotent(&report)
        testPluginEnableKernelNotReady(&report)
        testEnableReplayMergesNewService(&report)
        testEnablePersistenceFailureDoesNotWrite(&report)
        testEnablePartialWriteRollsBack(&report)
        testReplayFailurePreservesExistingTakeover(&report)
        testRollbackFailureKeepsMarker(&report)
    }

    // ① SystemProxyController:capture → takeover → restore 全纯逻辑(含第三方代理精确还原)。
    private static func testControllerCaptureTakeoverRestore(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: sampleInitialState())
        let controller = SystemProxyController(net: net)

        // 快照:捕获各服务原状态。
        guard let snapshot = try? controller.capture() else {
            report.check(false, "07 快照:capture 应成功"); return
        }
        report.check(snapshot.services.count == 2, "07 快照:capture 捕获全部服务(Wi-Fi + Ethernet)")
        let ethSnap = snapshot.services.first { $0.service == "Ethernet" }
        report.check(ethSnap?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                     "07 快照:capture 记录 Ethernet 原第三方 HTTP 代理(开关+host+port)")
        report.check(ethSnap?.socks == .off, "07 快照:capture 记录 Ethernet 原 SOCKS 为关闭")
        let wifiSnap = snapshot.services.first { $0.service == "Wi-Fi" }
        report.check(wifiSnap?.http == .off, "07 快照:capture 记录 Wi-Fi 原状态为关闭")

        // 接管:各服务三类代理都指向内核端口(无新服务时,并入的快照 == capture 全量快照)。
        let takeoverSnap = (try? controller.takeover(host: "127.0.0.1", port: 7890, into: nil)) ?? snapshot
        report.check(takeoverSnap == snapshot, "07 接管:takeover 并入的快照(无新服务)== capture 全量快照")
        for service in ["Wi-Fi", "Ethernet"] {
            let s = net.currentState(service: service)
            let allToKernel = [s?.http, s?.https, s?.socks].allSatisfy {
                $0 == ProxySetting(enabled: true, host: "127.0.0.1", port: 7890)
            }
            report.check(allToKernel, "07 接管:enable 后 \(service) 的 HTTP/HTTPS/SOCKS 均指向内核端口 127.0.0.1:7890")
        }
        // 接管后原第三方代理已被内核端口覆盖(内存态不再是 203.0.113.9)。
        report.check(net.currentState(service: "Ethernet")?.http.host == "127.0.0.1",
                     "07 接管:Ethernet 原第三方代理被内核端口覆盖")

        // 还原:按快照精确还原。
        try? controller.restore(snapshot)
        let ethAfter = net.currentState(service: "Ethernet")
        report.check(ethAfter?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                     "07 还原:原本第三方代理→精确还原成第三方 203.0.113.9:8080(不是一律关闭)")
        report.check(ethAfter?.https == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                     "07 还原:Ethernet HTTPS 亦精确还原成第三方")
        report.check(ethAfter?.socks == .off, "07 还原:Ethernet 原本关闭的 SOCKS → 还原成关闭")
        let wifiAfter = net.currentState(service: "Wi-Fi")
        report.check(wifiAfter?.http == .off && wifiAfter?.https == .off && wifiAfter?.socks == .off,
                     "07 还原:原本全关的 Wi-Fi → 精确还原成全关")
        // 还原终态 == 接管前快照(逐服务)。
        report.check((try? controller.capture()) == snapshot,
                     "07 还原:还原后再次快照 == 接管前快照(终态精确复原)")
    }

    // ② ProxyPlugin.enable/disable 幂等:重复 enable 不覆盖首次快照(disable 精确还原到「最初」)。
    private static func testPluginEnableDisableIdempotent(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: sampleInitialState())
        let http = FakeHTTPPort()
        // 内核 REST 报 mixed-port=7890(enable 读它作为接管目标端口)。
        http.setResponse(pathSuffix: "/configs", json: #"{"mode":"rule","mixed-port":7890,"port":0}"#)
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http,
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090)

        // 首次 enable:快照 = 最初状态,接管指向 7890。
        switch plugin.enableSystemProxy() {
        case .success(let out):
            report.check(out.objectValue?["enabled"] == .bool(true), "07 接管:首次 enable 成功 enabled=true")
            report.check(out.objectValue?["port"] == .number(7890), "07 接管:enable 指向内核 mixed-port 7890")
        case .failure:
            report.check(false, "07 接管:首次 enable 应成功")
        }
        report.check(net.currentState(service: "Ethernet")?.http.host == "127.0.0.1",
                     "07 接管:enable 后 Ethernet 指向内核端口")

        // 重复 enable:不应覆盖首次快照(内存态此刻已是「全指向 7890」,若被当成新快照,disable 就会还原成 7890 而非最初)。
        _ = plugin.enableSystemProxy()

        // disable:应精确还原到「最初」(Ethernet 第三方代理回来),证明重复 enable 未覆盖首次快照。
        switch plugin.disableSystemProxy() {
        case .success(let out):
            report.check(out.objectValue?["restored"] == .bool(true), "07 还原:disable 报告已还原 restored=true")
        case .failure:
            report.check(false, "07 还原:disable 应成功")
        }
        report.check(net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                     "07 幂等:重复 enable 不覆盖首次快照(disable 精确还原到最初的第三方代理,非 7890)")
        report.check(net.currentState(service: "Wi-Fi")?.http == .off,
                     "07 还原:disable 后 Wi-Fi 还原成关闭")

        // disable 幂等:已还原后再 disable → no-op 成功(restored=false)。
        switch plugin.disableSystemProxy() {
        case .success(let out):
            report.check(out.objectValue?["restored"] == .bool(false), "07 幂等:未接管时 disable → no-op 成功(restored=false)")
        case .failure:
            report.check(false, "07 幂等:重复 disable 应 no-op 成功")
        }
    }

    // ③ 内核端口未就绪时 enable → 业务失败(capability_failed → 退出码 5),不崩、不接管。
    private static func testPluginEnableKernelNotReady(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: sampleInitialState())
        let http = FakeHTTPPort()   // 无 /configs 预置 → configs() 抛错 → 读不到 mixed-port
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http,
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090)
        switch plugin.enableSystemProxy() {
        case .success:
            report.check(false, "07 业务失败:内核端口未就绪时 enable 不应成功")
        case .failure(let err):
            report.check(err.code == WireErrorCode.capabilityFailed,
                         "07 业务失败:内核端口未就绪时 enable 报 capability_failed(退出码5,不崩)")
        }
        // 未接管:各服务应保持原状(不被误改)。
        report.check(net.setCalls.isEmpty, "07 业务失败:enable 失败时未对系统代理做任何写入(不留半接管态)")
        report.check(net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                     "07 业务失败:enable 失败后 Ethernet 原第三方代理保持不变")
    }

    // ④' 重放快照漏洞回归(coordinator review 发现的硬 bug):已接管状态下再 enable 时,若两次 enable 之间**新出现**
    //    了网络服务(用户接了 Ethernet / iPhone USB 等),该新服务会被接管指向内核端口——它必须也进快照,否则
    //    disable/退出还原遍历不到它 → 永久指向已死的 127.0.0.1:<port>。本用例覆盖此前没测到的这条路径。
    private static func testEnableReplayMergesNewService(_ report: inout TestReport) {
        // 初始只有 Wi-Fi(全关)。
        let net = FakeNetworkConfigPort(initial: [ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)])
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", json: #"{"mode":"rule","mixed-port":7890,"port":0}"#)
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http,
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090)

        // 首次 enable:快照 = { Wi-Fi off }。
        _ = plugin.enableSystemProxy()

        // 模拟接管后**新增**一个服务:Ethernet 原本就有第三方代理(198.51.100.7:3128)。
        net.addService(ServiceProxyState(service: "Ethernet",
                                         http: ProxySetting(enabled: true, host: "198.51.100.7", port: 3128),
                                         https: .off, socks: .off))

        // 再 enable(重放):takeover 应捕获 Ethernet 接管前原状态并入快照,并把它指向内核端口。
        _ = plugin.enableSystemProxy()
        report.check(net.currentState(service: "Ethernet")?.http.host == "127.0.0.1",
                     "07 重放:再 enable 接管了接管后新增的服务(指向内核端口)")

        // disable 还原:新增服务也必须被还原回第三方代理(否则永久指向内核死端口——正是本 bug)。
        _ = plugin.disableSystemProxy()
        report.check(net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "198.51.100.7", port: 3128),
                     "07 重放漏洞修复:还原覆盖接管后新增的服务→回到接管前第三方代理(不残留指向内核死端口)")
        report.check(net.currentState(service: "Ethernet")?.https == .off,
                     "07 重放:新增服务的其余各类也精确还原(HTTPS 回到关闭)")
        report.check(net.currentState(service: "Wi-Fi")?.http == .off,
                     "07 重放:最初的 Wi-Fi 仍精确还原为关闭(既有快照未被覆盖)")
    }

    /// P0 回归:持久化接管清单是任何 networksetup 写入的前置条件。保存失败必须 fail-closed、零写入。
    private static func testEnablePersistenceFailureDoesNotWrite(_ report: inout TestReport) {
        let initial = sampleInitialState()
        let net = FakeNetworkConfigPort(initial: initial)
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", json: #"{"mode":"rule","mixed-port":7890,"port":0}"#)
        let store = FakeTakeoverStateStore()
        store.failSaves = true
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http,
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090,
                                 stateStore: store)

        if case .failure = plugin.enableSystemProxy() {
            report.check(true, "07 事务:P0 持久化失败 → enable 失败")
        } else {
            report.check(false, "07 事务:P0 持久化失败时 enable 不得成功")
        }
        report.check(net.setCalls.isEmpty && net.disableCalls.isEmpty,
                     "07 事务:P0 持久化失败 → 系统代理零写入")
        report.check((try? SystemProxyController(net: net).capture()) == SystemProxySnapshot(services: initial),
                     "07 事务:P0 持久化失败 → 系统代理保持原样")
    }

    /// P0 回归:接管写到一半失败时,必须用预先保存的完整快照回滚已落地部分,不得留下半接管态。
    private static func testEnablePartialWriteRollsBack(_ report: inout TestReport) {
        let initial = sampleInitialState()
        let net = FakeNetworkConfigPort(initial: initial)
        net.failWriteAtCall = 3
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", json: #"{"mode":"rule","mixed-port":7890,"port":0}"#)
        let store = FakeTakeoverStateStore()
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http,
                                 networkConfigPort: net, kernelPath: nil, controlPort: 9090,
                                 stateStore: store)

        if case .failure = plugin.enableSystemProxy() {
            report.check(true, "07 事务:P0 部分写失败 → enable 失败")
        } else {
            report.check(false, "07 事务:P0 部分写失败时 enable 不得成功")
        }
        report.check((try? SystemProxyController(net: net).capture()) == SystemProxySnapshot(services: initial),
                     "07 事务:P0 部分写失败 → 已写代理全部回滚到原快照")
        report.check(!store.isPersisted,
                     "07 事务:P0 部分写失败且回滚成功 → 清除接管标记")
    }

    /// 重复 enable 失败只能撤销本次调用，不能把此前已生效的接管一并关闭。
    private static func testReplayFailurePreservesExistingTakeover(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: [ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)])
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", json: #"{"mode":"rule","mixed-port":7890,"port":0}"#)
        let store = FakeTakeoverStateStore()
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090, stateStore: store)
        _ = plugin.enableSystemProxy()
        net.addService(ServiceProxyState(service: "Ethernet",
                                         http: ProxySetting(enabled: true, host: "198.51.100.7", port: 3128),
                                         https: .off, socks: .off))
        net.failWriteAtCall = 5 // 首次 enable 3 写；重放第 2 写失败。
        _ = plugin.enableSystemProxy()

        report.check(net.currentState(service: "Wi-Fi")?.http.host == "127.0.0.1",
                     "07 重放事务:重放失败后既有 Wi-Fi 接管仍保持启用")
        report.check(net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "198.51.100.7", port: 3128),
                     "07 重放事务:重放失败后新增服务恢复到本次调用前状态")
        report.check(store.isPersisted,
                     "07 重放事务:既有接管仍生效时保留持久化标记")
    }

    /// 回滚本身失败时必须保留标记，供下次启动继续自愈。
    private static func testRollbackFailureKeepsMarker(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: sampleInitialState())
        net.failWritesStartingAtCall = 3
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", json: #"{"mode":"rule","mixed-port":7890,"port":0}"#)
        let store = FakeTakeoverStateStore()
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090, stateStore: store)
        _ = plugin.enableSystemProxy()
        report.check(store.isPersisted && store.clearCount == 0,
                     "07 事务:P0 回滚失败 → 保留接管标记供下次启动自愈")
    }
}
