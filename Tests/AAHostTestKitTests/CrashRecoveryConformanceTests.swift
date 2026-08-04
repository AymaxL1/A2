// 17 票:从 `AAHostTestKit.CrashRecoveryConformanceTests` 迁到 swift-testing(迁移口径见 RegistryConformanceTests.swift 头注)。
//
// 08 崩溃自愈纯逻辑 + 执行编排测试(注入假 TakeoverStateStore / ProcessReaper / NetworkConfigPort,
//   绝不碰真 AppSupport、真 networksetup、真进程)。
//
// 迁移带来的一处形状变化(如实记):旧套件把「恢复 / 还原 / 用户改过 / 修盲杀」各自的一大串断言塞在同一个
//   sub-function 里,而 shell 侧对同一个场景 grep 了多条文案。swift-testing 下改成
//   **每个 grep 文案一个 `@Test`,共用一个场景装配助手**(`recoverScenario()` 之流)——
//   装配是纯内存假件,重复跑代价可忽略,换来的是「哪一条断言红了」一眼可辨。

import Foundation
import Testing
import AAContracts
import AAPluginSDK
import PluginProxy
import AAHostTestKit

@Suite("08 崩溃自愈判定 / 执行编排纯逻辑(假 TakeoverStateStore + ProcessReaper + NetworkConfigPort)")
struct CrashRecoveryConformanceTests {

    // ============ ① 自愈判定纯函数(五分支,注入布尔信号,无 I/O)============

    @Test("08 自愈判定:无持久化标记 → clean(无操作)")
    func decideClean() {
        #expect(CrashRecovery.decide(hasPersistedMarker: false,
                                     proxyStillPointsAtKernelPort: false,
                                     kernelPortHealthy: false,
                                     kernelHealthilyRestartable: false) == .clean,
                "08 自愈判定:无持久化标记 → clean(无操作)")
    }

    @Test("08 自愈判定:有标记但代理已不指向我方端口 → 用户手动改过(不覆盖,只清标记)")
    func decideUserChanged() {
        #expect(CrashRecovery.decide(hasPersistedMarker: true,
                                     proxyStillPointsAtKernelPort: false,
                                     kernelPortHealthy: false,
                                     kernelHealthilyRestartable: true) == .userChangedProxy,
                "08 自愈判定:有标记但代理已不指向我方端口 → 用户手动改过(不覆盖,只清标记)")
    }

    @Test("08 自愈判定:残留接管 + 内核可健康重启 → 恢复接管(重指存活端口)")
    func decideRecover() {
        #expect(CrashRecovery.decide(hasPersistedMarker: true,
                                     proxyStillPointsAtKernelPort: true,
                                     kernelPortHealthy: false,
                                     kernelHealthilyRestartable: true) == .recoverTakeover,
                "08 自愈判定:残留接管 + 内核可健康重启 → 恢复接管(重指存活端口)")
    }

    @Test("08 自愈判定:残留接管 + 内核不可健康重启 → 还原快照(降级直连)")
    func decideRestore() {
        #expect(CrashRecovery.decide(hasPersistedMarker: true,
                                     proxyStillPointsAtKernelPort: true,
                                     kernelPortHealthy: false,
                                     kernelHealthilyRestartable: false) == .restoreSnapshot,
                "08 自愈判定:残留接管 + 内核不可健康重启 → 还原快照(降级直连)")
    }

    @Test("08 自愈判定:代理指向我方端口且端口仍活 → 校正标记(视为正常)")
    func decideAlreadyHealthy() {
        #expect(CrashRecovery.decide(hasPersistedMarker: true,
                                     proxyStillPointsAtKernelPort: true,
                                     kernelPortHealthy: true,
                                     kernelHealthilyRestartable: true) == .alreadyHealthy,
                "08 自愈判定:代理指向我方端口且端口仍活 → 校正标记(视为正常)")
    }

    @Test("08 不变式辅助:systemProxyPointsAt 正反两向都判得准")
    func invariantHelper() {
        let residual = [ServiceProxyState(service: "Wi-Fi",
                                          http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                                          https: .off, socks: .off)]
        #expect(CrashRecovery.systemProxyPointsAt(host: "127.0.0.1", port: 7890, services: residual),
                "08 不变式辅助:检出系统代理仍指向我方端口(127.0.0.1:7890)")
        let direct = [ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)]
        #expect(!CrashRecovery.systemProxyPointsAt(host: "127.0.0.1", port: 7890, services: direct),
                "08 不变式辅助:直连态不指向我方端口(用户改过/还原后为假)")
    }

    // ============ ①' 身份核验纯逻辑(修 pid 复用盲杀)============

    @Test("08 身份核验:路径不符(pid 已复用为无辜进程)→ 判为非我方 → 不 reap")
    func identityPathMismatch() {
        #expect(CrashRecovery.isOurKernel(currentPath: "/opt/mihomo", expectedPath: "/opt/mihomo"),
                "08 身份核验:当前路径 == 记录内核路径 → 判为我方内核(允许 reap)")
        #expect(!CrashRecovery.isOurKernel(currentPath: "/usr/bin/innocent", expectedPath: "/opt/mihomo"),
                "08 身份核验:路径不符(pid 已复用为无辜进程)→ 判为非我方 → 不 reap")
    }

    @Test("08 身份核验:读不到当前路径(pid 已死 / EPERM 非本用户进程)→ 不 reap")
    func identityPathUnknown() {
        #expect(!CrashRecovery.isOurKernel(currentPath: nil, expectedPath: "/opt/mihomo"),
                "08 身份核验:读不到当前路径(pid 已死 / EPERM 非本用户进程)→ 不 reap")
        #expect(!CrashRecovery.isOurKernel(currentPath: "/opt/mihomo", expectedPath: ""),
                "08 身份核验:记录路径为空(未知)→ 保守不 reap")
    }

    // ============ ② 恢复接管(残留接管 + 内核可健康重启)============

    @Test("08 自愈执行:残留接管+内核可重启 → 恢复接管(并更新持久化)")
    func executorRecoverDecision() {
        let s = Self.recoverScenario()
        #expect(s.result.decision == .recoverTakeover, "08 自愈执行:残留接管+内核可重启 → 恢复接管")
        #expect(s.result.kernelRelaunched, "08 恢复接管:自愈重启了内核(kernelRelaunched=true)")
        #expect(s.store.isPersisted && s.store.saveCount >= 1,
                "08 恢复接管:接管态持久化被更新(仍处接管,清单在)")
    }

    @Test("08 孤儿清理:上世代残留内核 pid 4242 被先 reap(恢复前清孤儿)")
    func executorRecoverReapsOrphan() {
        let s = Self.recoverScenario()
        #expect(s.reaper.reapCalls == [4242], "08 孤儿清理:上世代残留内核 pid 4242 被先 reap(恢复前清孤儿)")
        #expect(s.result.reapedOrphanPID == 4242, "08 孤儿清理:自愈报告记录了被 reap 的孤儿 pid")
    }

    @Test("08 恢复接管:系统代理指向存活端口 127.0.0.1:7890(内核已重启)")
    func executorRecoverPointsAtLivePort() {
        let s = Self.recoverScenario()
        #expect(Self.netPointsAt(s.net, services: ["Wi-Fi"], port: 7890),
                "08 恢复接管:系统代理指向存活端口 127.0.0.1:7890(内核已重启)")
    }

    @Test("08 不变式(恢复):恢复接管后有存活受管内核(proxy.status running=true)→ 指向存活端口非死端口")
    func executorRecoverInvariant() {
        let s = Self.recoverScenario()
        if let statusHandler = s.plugin.capabilities().first(where: { $0.descriptor.id == "proxy.status" })?.handler,
           case .success(let out) = statusHandler(nil) {
            #expect(out.objectValue?["running"] == .bool(true),
                    "08 不变式(恢复):恢复接管后有存活受管内核(proxy.status running=true)→ 指向存活端口非死端口")
        } else {
            Issue.record("08 不变式(恢复):应能取到 proxy.status 且 running=true")
        }
    }

    // ============ ③ 还原快照(残留接管 + 内核不可健康重启)============

    @Test("08 自愈执行:残留接管+内核不可重启 → 还原快照(降级直连),并先 reap 上世代残留 pid")
    func executorRestoreDecision() {
        let s = Self.restoreScenario()
        #expect(s.result.decision == .restoreSnapshot, "08 自愈执行:残留接管+内核不可重启 → 还原快照(降级直连)")
        #expect(s.reaper.reapCalls == [5252], "08 孤儿清理:还原路径同样先 reap 上世代残留 pid 5252")
        #expect(!s.store.isPersisted && s.store.clearCount >= 1,
                "08 还原快照:清除持久化标记(无残留接管,下次启动 clean)")
    }

    @Test("08 还原快照:精确还原成接管前第三方代理 203.0.113.9:8080(非一律关闭)")
    func executorRestoreExactly() {
        let s = Self.restoreScenario()
        #expect(s.net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                "08 还原快照:精确还原成接管前第三方代理 203.0.113.9:8080(非一律关闭)")
        #expect(s.net.currentState(service: "Ethernet")?.socks == .off,
                "08 还原快照:原本关闭的 SOCKS 还原成关闭")
    }

    @Test("08 不变式(还原):还原后系统代理不再指向死端口 127.0.0.1:7890(降级直连/第三方)")
    func executorRestoreInvariant() {
        let s = Self.restoreScenario()
        #expect(!Self.netPointsAt(s.net, services: ["Ethernet"], port: 7890),
                "08 不变式(还原):还原后系统代理不再指向死端口 127.0.0.1:7890(降级直连/第三方)")
    }

    // ============ ④ 用户手动改过代理(有标记但不指向我方端口)============

    @Test("08 自愈执行:用户改过代理 → 不覆盖,只清陈旧标记")
    func executorUserChangedDecision() {
        let s = Self.userChangedScenario()
        #expect(s.result.decision == .userChangedProxy, "08 自愈执行:用户改过代理 → 不覆盖,只清陈旧标记")
        #expect(!s.store.isPersisted && s.store.clearCount >= 1,
                "08 用户改过:清除陈旧持久化标记(不再自作主张接管)")
    }

    @Test("08 用户改过:绝不覆盖用户设置(用户的第三方代理 198.51.100.5:1080 原封不动)")
    func executorUserChangedNeverOverwrites() {
        let s = Self.userChangedScenario()
        #expect(s.net.currentState(service: "Wi-Fi")?.http == Self.userProxy,
                "08 用户改过:绝不覆盖用户设置(用户的第三方代理 198.51.100.5:1080 原封不动)")
        #expect(s.net.setCalls.isEmpty && s.net.disableCalls.isEmpty,
                "08 用户改过:自愈未对系统代理做任何写入(不覆盖用户设置)")
    }

    @Test("08 不变式(用户改过):终态不指向我方死端口 7890(尊重用户直连/第三方设置)")
    func executorUserChangedInvariant() {
        let s = Self.userChangedScenario()
        #expect(!Self.netPointsAt(s.net, services: ["Wi-Fi"], port: 7890),
                "08 不变式(用户改过):终态不指向我方死端口 7890(尊重用户直连/第三方设置)")
    }

    // ============ ⑤ 无标记 clean(不读网络)============

    @Test("08 clean:无标记时不写系统代理(提前返回,避免无谓触达真 networksetup)")
    func executorCleanNoMarker() {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)
        ])
        let store = FakeTakeoverStateStore(initial: nil)   // 无持久化标记
        let reaper = FakeProcessReaper(alive: [])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: "/fake/mihomo", controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        #expect(r.decision == .clean, "08 自愈执行:无持久化标记 → clean")
        #expect(reaper.reapCalls.isEmpty, "08 clean:无标记时不 reap 任何进程")
        #expect(net.setCalls.isEmpty && net.disableCalls.isEmpty,
                "08 clean:无标记时不写系统代理(提前返回,避免无谓触达真 networksetup)")
    }

    // ============ ⑥ 修盲杀:持久化 pid 已被无关进程复用(路径不符)============

    @Test("08 修盲杀:持久化 pid 身份不符(路径≠记录内核路径)→ 绝不 reap(不杀无辜进程)")
    func executorPidIdentityMismatchNeverReaps() {
        let s = Self.pidMismatchScenario()
        #expect(s.reaper.reapCalls.isEmpty,
                "08 修盲杀:持久化 pid 身份不符(路径≠记录内核路径)→ 绝不 reap(不杀无辜进程)")
        #expect(s.result.reapedOrphanPID == nil, "08 修盲杀:自愈报告未记录任何被 reap 的 pid(未杀)")
    }

    @Test("08 修盲杀:自愈后系统代理不再指向死端口(网络照常复原)")
    func executorPidIdentityMismatchStillHeals() {
        let s = Self.pidMismatchScenario()
        #expect(s.result.decision == .restoreSnapshot, "08 修盲杀:不杀之余,网络仍走还原快照自愈(不冒杀错风险)")
        #expect(!Self.netPointsAt(s.net, services: ["Ethernet"], port: 7890),
                "08 修盲杀:自愈后系统代理不再指向死端口(网络照常复原)")
        #expect(!s.store.isPersisted, "08 修盲杀:还原成功后清除标记")
    }

    // ============ ⑦ 修清标记 bug:还原失败 → 保留标记待下次启动重试 ============

    @Test("08 修清标记 bug:还原失败 → 保留持久化标记(clearCount=0),下次启动重试(不留死端口后清标记)")
    func executorRestoreFailureKeepsMarker() {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Ethernet",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: .off, socks: .off)
        ])
        net.failWrites = true   // 还原(setProxy/disableProxy)必失败
        let store = FakeTakeoverStateStore(initial: Self.encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Ethernet",
                                  http: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  https: .off, socks: .off)
            ]), kernelPort: 7890, kernelPID: 5252, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [5252], paths: [5252: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        #expect(r.decision == .deferred && !r.allowsKernelLaunch, "08 还原失败:deferred 且禁止常规内核启停")
        #expect(store.isPersisted && store.clearCount == 0,
                "08 修清标记 bug:还原失败 → 保留持久化标记(clearCount=0),下次启动重试(不留死端口后清标记)")
    }

    // ============ ⑧ 修误判:读当前系统代理失败 → deferred ============

    @Test("08 修误判:读当前系统代理失败 → deferred(保守中止,不误判用户改过)")
    func executorCaptureFailureDefers() {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Ethernet",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: .off, socks: .off)
        ])
        net.failReads = true    // 读当前系统代理(networkServices/proxyState)必失败
        let store = FakeTakeoverStateStore(initial: Self.encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Ethernet", http: .off, https: .off, socks: .off)
            ]), kernelPort: 7890, kernelPID: 6363, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [6363], paths: [6363: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        #expect(r.decision == .deferred,
                "08 修误判:读当前系统代理失败 → deferred(保守中止,不误判用户改过)")
        #expect(store.isPersisted && store.clearCount == 0,
                "08 修误判:读代理失败 → 保留持久化标记(不清、不误判 userChanged),待下次启动重试")
        #expect(net.setCalls.isEmpty && net.disableCalls.isEmpty,
                "08 修误判:采集失败即中止,未对系统代理做任何写入")
    }

    // ============ 主/副标记与墓碑 ============

    @Test("08 损坏主标记:使用恢复副本走精确还原,用户本地第三方代理未被误删")
    func corruptPrimaryUsesRecoveryCopy() {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: .off, socks: .off)
        ])
        let recovery = Self.encodedState(TakeoverState(snapshot: SystemProxySnapshot(services: [
            ServiceProxyState(service: "Wi-Fi",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 8888),
                              https: .off, socks: .off)
        ]), kernelPort: 7890, kernelPID: 0, kernelExecutablePath: "", takeoverAt: 1000))
        let store = FakeTakeoverStateStore(initial: Data("not-json".utf8), initialRecovery: recovery)
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090, stateStore: store)
        let result = plugin.selfHeal()
        #expect(result.decision == .restoreSnapshot, "08 损坏主标记:使用恢复副本走精确还原")
        #expect(net.currentState(service: "Wi-Fi")?.http
                == ProxySetting(enabled: true, host: "127.0.0.1", port: 8888),
                "08 损坏主标记:用户本地第三方代理精确恢复，未被误删")
        #expect(!store.isPersisted && store.clearCount == 1, "08 损坏主标记:恢复成功后清除主副标记")
    }

    @Test("08 主标记不可读:使用恢复副本精确还原,解除 AA 死代理")
    func unreadablePrimaryUsesRecoveryCopy() {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: .off, socks: .off)
        ])
        let recovery = Self.encodedState(TakeoverState(snapshot: SystemProxySnapshot(services: [
            ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)
        ]), kernelPort: 7890, kernelPID: 0, kernelExecutablePath: "", takeoverAt: 1000))
        let store = FakeTakeoverStateStore(initial: Data("present".utf8), initialRecovery: recovery)
        store.failLoads = true
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090, stateStore: store)
        let result = plugin.selfHeal()
        #expect(result.decision == .restoreSnapshot, "08 主标记不可读:使用恢复副本精确还原")
        #expect(net.currentState(service: "Wi-Fi")?.http == .off, "08 主标记不可读:恢复副本解除 AA 死代理")
        #expect(!store.isPersisted, "08 主标记不可读:恢复成功后清除主副标记")
    }

    @Test("08 主副标记均无效:deferred 且禁止常规内核启停,不猜测 loopback 所有权")
    func invalidMarkerWithoutRecoveryBlocksKernel() {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 8888),
                              https: .off, socks: .off)
        ])
        let store = FakeTakeoverStateStore(initial: Data("not-json".utf8))
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090, stateStore: store)
        let result = plugin.selfHeal()
        #expect(result.decision == .deferred && !result.allowsKernelLaunch,
                "08 主副标记均无效:deferred 且禁止常规内核启停")
        #expect(net.currentState(service: "Wi-Fi")?.http
                == ProxySetting(enabled: true, host: "127.0.0.1", port: 8888)
                && net.setCalls.isEmpty && net.disableCalls.isEmpty,
                "08 主副标记均无效:不猜测 loopback 所有权，不改用户本地代理")
        #expect(store.isPersisted && store.clearCount == 0,
                "08 主副标记均无效:保留持久化证据供人工处理/下次重试")
    }

    @Test("08 tombstone:恢复副本物理删除失败时逻辑清理仍成功,陈旧副本被墓碑屏蔽")
    func clearTombstoneMasksStaleRecovery() {
        let bytes = Data("old-state".utf8)
        let store = FakeTakeoverStateStore(initial: bytes, initialRecovery: bytes)
        store.failRecoveryRemoval = true
        let cleared = (try? store.clear()) != nil
        let primary = try? store.load()
        let recovery = try? store.loadRecovery()
        #expect(cleared && store.hasStaleRecoveryBlob,
                "08 tombstone:恢复副本物理删除失败时逻辑清理仍成功")
        #expect(primary == nil && recovery == nil && !store.isPersisted,
                "08 tombstone:陈旧恢复副本被墓碑屏蔽，不再成为接管证据")
    }

    @Test("08 tombstone 写失败:deferred 且禁止常规内核启停,主副证据保持权威")
    func tombstoneWriteFailureDefers() {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: .off, socks: .off)
        ])
        let state = Self.encodedState(TakeoverState(snapshot: SystemProxySnapshot(services: [
            ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)
        ]), kernelPort: 7890, kernelPID: 0, kernelExecutablePath: "", takeoverAt: 1000))
        let store = FakeTakeoverStateStore(initial: state, initialRecovery: state)
        store.failTombstoneWrites = true
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090, stateStore: store)
        let result = plugin.selfHeal()
        #expect(result.decision == .deferred && !result.allowsKernelLaunch,
                "08 tombstone 写失败:deferred 且禁止常规内核启停")
        #expect(store.isPersisted && store.clearCount == 0,
                "08 tombstone 写失败:主副证据保持权威，未发生半清理")
    }

    // ============ 执行编排助手 ============

    static let userProxy = ProxySetting(enabled: true, host: "198.51.100.5", port: 1080)

    static func encodedState(_ s: TakeoverState) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(s)) ?? Data()
    }

    /// 判定 net 里是否还有任一服务指向 127.0.0.1:port(不变式断言用)。
    static func netPointsAt(_ net: FakeNetworkConfigPort, services: [String], port: Int) -> Bool {
        for svc in services {
            guard let s = net.currentState(service: svc) else { continue }
            for kind in ProxyKind.allCases {
                let setting = s.setting(for: kind)
                if setting.enabled && setting.host == "127.0.0.1" && setting.port == port { return true }
            }
        }
        return false
    }

    struct Scenario {
        let plugin: ProxyPlugin
        let net: FakeNetworkConfigPort
        let store: FakeTakeoverStateStore
        let reaper: FakeProcessReaper
        let result: SelfHealReport
    }

    /// 残留态:Wi-Fi 三类都指向 127.0.0.1:7890(上世代接管、宿主已死 → 死端口)。接管前原状态(快照)= Wi-Fi 全关。
    /// 上世代内核 pid 4242 仍存活且路径与记录一致 → 身份核验通过,允许 reap;REST 可达 + kernelPath 有值 → 可健康重启。
    static func recoverScenario() -> Scenario {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              socks: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890))
        ])
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/configs", json: #"{"mode":"rule","mixed-port":7890,"port":0}"#)
        let store = FakeTakeoverStateStore(initial: encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)   // 接管前原状态:全关
            ]), kernelPort: 7890, kernelPID: 4242, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [4242], paths: [4242: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: "/fake/mihomo", controlPort: 9090,
                                 stateStore: store, reaper: reaper)
        return Scenario(plugin: plugin, net: net, store: store, reaper: reaper, result: plugin.selfHeal())
    }

    /// 残留态:Ethernet 三类都指向 127.0.0.1:7890(死端口)。快照 = 第三方 203.0.113.9:8080 + SOCKS 关。
    /// REST 不可达 + kernelPath=nil → 不能健康重启 → 还原快照。
    static func restoreScenario() -> Scenario {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Ethernet",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              socks: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890))
        ])
        let store = FakeTakeoverStateStore(initial: encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Ethernet",
                                  http: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  https: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  socks: .off)
            ]), kernelPort: 7890, kernelPID: 5252, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [5252], paths: [5252: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090,
                                 stateStore: store, reaper: reaper)
        return Scenario(plugin: plugin, net: net, store: store, reaper: reaper, result: plugin.selfHeal())
    }

    /// 用户在崩溃后把系统代理改成了别的第三方代理(198.51.100.5:1080),不再指向我方 7890。
    static func userChangedScenario() -> Scenario {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi", http: userProxy, https: userProxy, socks: .off)
        ])
        let store = FakeTakeoverStateStore(initial: encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)
            ]), kernelPort: 7890, kernelPID: 6262, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [6262], paths: [6262: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: "/fake/mihomo", controlPort: 9090,
                                 stateStore: store, reaper: reaper)
        return Scenario(plugin: plugin, net: net, store: store, reaper: reaper, result: plugin.selfHeal())
    }

    /// 关键:pid 4242 仍存活,但它现在是**别的无辜进程**(路径 /usr/bin/innocent ≠ 记录的 /fake/mihomo)——pid 已被复用。
    static func pidMismatchScenario() -> Scenario {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Ethernet",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              socks: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890))
        ])
        let store = FakeTakeoverStateStore(initial: encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Ethernet",
                                  http: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  https: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  socks: .off)
            ]), kernelPort: 7890, kernelPID: 4242, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [4242], paths: [4242: "/usr/bin/innocent"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090,
                                 stateStore: store, reaper: reaper)
        return Scenario(plugin: plugin, net: net, store: store, reaper: reaper, result: plugin.selfHeal())
    }
}
