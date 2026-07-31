// AAHostTestKit —— 08 崩溃自愈纯逻辑 + 执行编排测试(注入假 TakeoverStateStore / ProcessReaper / NetworkConfigPort,
//   绝不碰真 AppSupport、真 networksetup、真进程)。
// 依赖边:AAHostTestKit → AAPluginSDK、PluginProxy、AAContracts。
//
// 覆盖阶段 B 断言(08):
//   * 自愈判定纯函数 SelfHealDecision.decide 逐分支:①无标记→clean;②用户改过→userChanged;③a 残留+可重启→recover;
//     ③b 残留+不可重启→restore;④指向且端口活→alreadyHealthy。
//   * 执行编排(经 ProxyPlugin.selfHeal + 假件):恢复接管(代理指向存活端口)/ 还原快照(降级直连,精确)/ 用户改过(不覆盖只清标记)/
//     无标记 clean(不读网络);孤儿 pid 先 reap;**核心不变式:任一自愈路径后系统代理都不指向死端口**。

import Foundation
import AAContracts
import AAPluginSDK
import PluginProxy

extension ProxyConformanceTests {

    /// 08 票自愈套件入口(由 ProxyConformanceTests.run() 调用,汇入同一 runner 输出)。
    static func testCrashSelfHeal(_ report: inout TestReport) {
        testDecidePureBranches(&report)
        testIdentityPureLogic(&report)
        testExecutorRecover(&report)
        testExecutorRestore(&report)
        testExecutorUserChanged(&report)
        testExecutorCleanNoMarker(&report)
        testExecutorPidIdentityMismatch(&report)   // 修盲杀:pid 身份不符 → 不杀,走网络自愈
        testExecutorRestoreFailureKeepsMarker(&report) // 修清标记 bug:还原失败 → 保留标记待重试
        testExecutorCaptureFailureDefers(&report)  // 修误判:读代理失败 → deferred 保留标记,不误判用户改过
        testCorruptMarkerDefers(&report)
        testUnreadableMarkerDefers(&report)
        testInvalidMarkerFallbackFailureBlocksKernel(&report)
    }

    // ============ ① 自愈判定纯函数(五分支,注入布尔信号,无 I/O)============
    private static func testDecidePureBranches(_ report: inout TestReport) {
        // ① 无持久化标记 → clean(无操作)。
        report.check(CrashRecovery.decide(hasPersistedMarker: false,
                                             proxyStillPointsAtKernelPort: false,
                                             kernelPortHealthy: false,
                                             kernelHealthilyRestartable: false) == .clean,
                     "08 自愈判定:无持久化标记 → clean(无操作)")
        // ② 有标记但代理已不指向我方端口 → 用户手动改过,不覆盖只清标记。
        report.check(CrashRecovery.decide(hasPersistedMarker: true,
                                             proxyStillPointsAtKernelPort: false,
                                             kernelPortHealthy: false,
                                             kernelHealthilyRestartable: true) == .userChangedProxy,
                     "08 自愈判定:有标记但代理已不指向我方端口 → 用户手动改过(不覆盖,只清标记)")
        // ③a 残留接管 + 内核可健康重启 → 恢复接管。
        report.check(CrashRecovery.decide(hasPersistedMarker: true,
                                             proxyStillPointsAtKernelPort: true,
                                             kernelPortHealthy: false,
                                             kernelHealthilyRestartable: true) == .recoverTakeover,
                     "08 自愈判定:残留接管 + 内核可健康重启 → 恢复接管(重指存活端口)")
        // ③b 残留接管 + 内核不可重启 → 还原快照(降级直连)。
        report.check(CrashRecovery.decide(hasPersistedMarker: true,
                                             proxyStillPointsAtKernelPort: true,
                                             kernelPortHealthy: false,
                                             kernelHealthilyRestartable: false) == .restoreSnapshot,
                     "08 自愈判定:残留接管 + 内核不可健康重启 → 还原快照(降级直连)")
        // ④ 代理指向我方端口且端口仍活 → 视为正常,校正标记。
        report.check(CrashRecovery.decide(hasPersistedMarker: true,
                                             proxyStillPointsAtKernelPort: true,
                                             kernelPortHealthy: true,
                                             kernelHealthilyRestartable: true) == .alreadyHealthy,
                     "08 自愈判定:代理指向我方端口且端口仍活 → 校正标记(视为正常)")

        // 不变式辅助函数:systemProxyPointsAt 正/反。
        let residual = [ServiceProxyState(service: "Wi-Fi",
                                          http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                                          https: .off, socks: .off)]
        report.check(CrashRecovery.systemProxyPointsAt(host: "127.0.0.1", port: 7890, services: residual),
                     "08 不变式辅助:检出系统代理仍指向我方端口(127.0.0.1:7890)")
        let direct = [ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)]
        report.check(!CrashRecovery.systemProxyPointsAt(host: "127.0.0.1", port: 7890, services: direct),
                     "08 不变式辅助:直连态不指向我方端口(用户改过/还原后为假)")
    }

    // ============ ①' 身份核验纯逻辑(修 pid 复用盲杀)============
    private static func testIdentityPureLogic(_ report: inout TestReport) {
        report.check(CrashRecovery.isOurKernel(currentPath: "/opt/mihomo", expectedPath: "/opt/mihomo"),
                     "08 身份核验:当前路径 == 记录内核路径 → 判为我方内核(允许 reap)")
        report.check(!CrashRecovery.isOurKernel(currentPath: "/usr/bin/innocent", expectedPath: "/opt/mihomo"),
                     "08 身份核验:路径不符(pid 已复用为无辜进程)→ 判为非我方 → 不 reap")
        report.check(!CrashRecovery.isOurKernel(currentPath: nil, expectedPath: "/opt/mihomo"),
                     "08 身份核验:读不到当前路径(pid 已死 / EPERM 非本用户进程)→ 不 reap")
        report.check(!CrashRecovery.isOurKernel(currentPath: "/opt/mihomo", expectedPath: ""),
                     "08 身份核验:记录路径为空(未知)→ 保守不 reap")
    }

    // ============ 执行编排助手 ============
    private static func encodedState(_ s: TakeoverState) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(s)) ?? Data()
    }

    /// 判定 net 里是否还有任一服务指向 127.0.0.1:port(不变式断言用)。
    private static func netPointsAt(_ net: FakeNetworkConfigPort, services: [String], port: Int) -> Bool {
        for svc in services {
            guard let s = net.currentState(service: svc) else { continue }
            for kind in ProxyKind.allCases {
                let setting = s.setting(for: kind)
                if setting.enabled && setting.host == "127.0.0.1" && setting.port == port { return true }
            }
        }
        return false
    }

    // ============ ② 恢复接管(残留接管 + 内核可健康重启)============
    private static func testExecutorRecover(_ report: inout TestReport) {
        // 残留态:Wi-Fi 三类都指向 127.0.0.1:7890(上世代接管、宿主已死 → 死端口)。接管前原状态(快照)= Wi-Fi 全关。
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
        // 上世代内核 pid 4242 仍存活(kill -9 后残留孤儿),且其当前可执行路径与记录一致 → 身份核验通过,允许 reap。
        let reaper = FakeProcessReaper(alive: [4242], paths: [4242: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: "/fake/mihomo", controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        report.check(r.decision == .recoverTakeover, "08 自愈执行:残留接管+内核可重启 → 恢复接管")
        // 孤儿先 reap。
        report.check(reaper.reapCalls == [4242], "08 孤儿清理:上世代残留内核 pid 4242 被先 reap(恢复前清孤儿)")
        report.check(r.reapedOrphanPID == 4242, "08 孤儿清理:自愈报告记录了被 reap 的孤儿 pid")
        // 恢复后系统代理指向存活端口(7890 现由重启的内核承载)。
        report.check(netPointsAt(net, services: ["Wi-Fi"], port: 7890),
                     "08 恢复接管:系统代理指向存活端口 127.0.0.1:7890(内核已重启)")
        report.check(r.kernelRelaunched, "08 恢复接管:自愈重启了内核(kernelRelaunched=true)")
        // 有活着的受管内核佐证「端口不是死的」:proxy.status running=true。
        if let statusHandler = plugin.capabilities().first(where: { $0.descriptor.id == "proxy.status" })?.handler,
           case .success(let out) = statusHandler(nil) {
            report.check(out.objectValue?["running"] == .bool(true),
                         "08 不变式(恢复):恢复接管后有存活受管内核(proxy.status running=true)→ 指向存活端口非死端口")
        } else {
            report.check(false, "08 不变式(恢复):应能取到 proxy.status 且 running=true")
        }
        // 持久化被更新(新 pid/port 写回),仍处接管态。
        report.check(store.isPersisted && store.saveCount >= 1,
                     "08 恢复接管:接管态持久化被更新(仍处接管,清单在)")
    }

    // ============ ③ 还原快照(残留接管 + 内核不可健康重启)============
    private static func testExecutorRestore(_ report: inout TestReport) {
        // 残留态:Ethernet 三类都指向 127.0.0.1:7890(死端口)。接管前原状态(快照)= HTTP/HTTPS 第三方 203.0.113.9:8080,SOCKS 关。
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Ethernet",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              socks: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890))
        ])
        let http = FakeHTTPPort()   // 无 /configs 预置(REST 不可达);且 kernelPath=nil → 不能健康重启
        let store = FakeTakeoverStateStore(initial: encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Ethernet",
                                  http: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  https: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  socks: .off)
            ]), kernelPort: 7890, kernelPID: 5252, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [5252], paths: [5252: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        report.check(r.decision == .restoreSnapshot, "08 自愈执行:残留接管+内核不可重启 → 还原快照(降级直连)")
        report.check(reaper.reapCalls == [5252], "08 孤儿清理:还原路径同样先 reap 上世代残留 pid 5252")
        // 精确还原到接管前第三方代理(不是一律关闭)。
        report.check(net.currentState(service: "Ethernet")?.http == ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                     "08 还原快照:精确还原成接管前第三方代理 203.0.113.9:8080(非一律关闭)")
        report.check(net.currentState(service: "Ethernet")?.socks == .off,
                     "08 还原快照:原本关闭的 SOCKS 还原成关闭")
        // 核心不变式:不再指向死端口 127.0.0.1:7890。
        report.check(!netPointsAt(net, services: ["Ethernet"], port: 7890),
                     "08 不变式(还原):还原后系统代理不再指向死端口 127.0.0.1:7890(降级直连/第三方)")
        // 标记被清除(无残留接管)。
        report.check(!store.isPersisted && store.clearCount >= 1,
                     "08 还原快照:清除持久化标记(无残留接管,下次启动 clean)")
    }

    // ============ ④ 用户手动改过代理(有标记但不指向我方端口)============
    private static func testExecutorUserChanged(_ report: inout TestReport) {
        // 用户在崩溃后把系统代理改成了别的第三方代理(198.51.100.5:1080),不再指向我方 7890。
        let userProxy = ProxySetting(enabled: true, host: "198.51.100.5", port: 1080)
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi", http: userProxy, https: userProxy, socks: .off)
        ])
        let http = FakeHTTPPort()
        let store = FakeTakeoverStateStore(initial: encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)
            ]), kernelPort: 7890, kernelPID: 6262, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [6262], paths: [6262: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: "/fake/mihomo", controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        report.check(r.decision == .userChangedProxy, "08 自愈执行:用户改过代理 → 不覆盖,只清陈旧标记")
        // 绝不覆盖用户设置:用户的第三方代理原封不动。
        report.check(net.currentState(service: "Wi-Fi")?.http == userProxy,
                     "08 用户改过:绝不覆盖用户设置(用户的第三方代理 198.51.100.5:1080 原封不动)")
        report.check(net.setCalls.isEmpty && net.disableCalls.isEmpty,
                     "08 用户改过:自愈未对系统代理做任何写入(不覆盖用户设置)")
        // 陈旧标记被清除。
        report.check(!store.isPersisted && store.clearCount >= 1,
                     "08 用户改过:清除陈旧持久化标记(不再自作主张接管)")
        // 核心不变式:也不指向我方(死)端口。
        report.check(!netPointsAt(net, services: ["Wi-Fi"], port: 7890),
                     "08 不变式(用户改过):终态不指向我方死端口 7890(尊重用户直连/第三方设置)")
    }

    // ============ ⑤ 无标记 clean(不读网络)============
    private static func testExecutorCleanNoMarker(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi", http: .off, https: .off, socks: .off)
        ])
        let http = FakeHTTPPort()
        let store = FakeTakeoverStateStore(initial: nil)   // 无持久化标记
        let reaper = FakeProcessReaper(alive: [])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: "/fake/mihomo", controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        report.check(r.decision == .clean, "08 自愈执行:无持久化标记 → clean")
        report.check(reaper.reapCalls.isEmpty, "08 clean:无标记时不 reap 任何进程")
        // 无标记路径在 capture() 之前提前返回,故绝不写系统代理(结构上亦不读)——避免无谓触达真 networksetup。
        report.check(net.setCalls.isEmpty && net.disableCalls.isEmpty,
                     "08 clean:无标记时不写系统代理(提前返回,避免无谓触达真 networksetup)")
    }

    // ============ ⑥ 修盲杀:持久化 pid 已被无关进程复用(路径不符)→ 绝不 SIGKILL,仍走网络自愈 ============
    private static func testExecutorPidIdentityMismatch(_ report: inout TestReport) {
        // 残留态:Ethernet 指向 127.0.0.1:7890(死端口)。接管前原状态 = 第三方 203.0.113.9:8080。
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Ethernet",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              socks: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890))
        ])
        let http = FakeHTTPPort()   // REST 不可达 + kernelPath=nil → 走还原快照(不影响本用例焦点:是否误杀)
        let store = FakeTakeoverStateStore(initial: encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Ethernet",
                                  http: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  https: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  socks: .off)
            ]), kernelPort: 7890, kernelPID: 4242, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        // 关键:pid 4242 仍存活,但它现在是**别的无辜进程**(路径 /usr/bin/innocent ≠ 记录的 /fake/mihomo)——pid 已被复用。
        let reaper = FakeProcessReaper(alive: [4242], paths: [4242: "/usr/bin/innocent"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        // 核心:绝不 SIGKILL 那个身份不符的 pid(否则杀了用户机上无辜进程)。
        report.check(reaper.reapCalls.isEmpty,
                     "08 修盲杀:持久化 pid 身份不符(路径≠记录内核路径)→ 绝不 reap(不杀无辜进程)")
        report.check(r.reapedOrphanPID == nil, "08 修盲杀:自愈报告未记录任何被 reap 的 pid(未杀)")
        // 网络仍照常自愈:内核不可重启 → 还原快照,不指向死端口。
        report.check(r.decision == .restoreSnapshot, "08 修盲杀:不杀之余,网络仍走还原快照自愈(不冒杀错风险)")
        report.check(!netPointsAt(net, services: ["Ethernet"], port: 7890),
                     "08 修盲杀:自愈后系统代理不再指向死端口(网络照常复原)")
        report.check(!store.isPersisted, "08 修盲杀:还原成功后清除标记")
    }

    // ============ ⑦ 修清标记 bug:还原失败 → **保留标记**待下次启动重试(绝不清标记留死端口)============
    private static func testExecutorRestoreFailureKeepsMarker(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Ethernet",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: .off, socks: .off)
        ])
        net.failWrites = true   // 还原(setProxy/disableProxy)必失败
        let http = FakeHTTPPort()
        let store = FakeTakeoverStateStore(initial: encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Ethernet",
                                  http: ProxySetting(enabled: true, host: "203.0.113.9", port: 8080),
                                  https: .off, socks: .off)
            ]), kernelPort: 7890, kernelPID: 5252, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [5252], paths: [5252: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        report.check(r.decision == .restoreSnapshot, "08 还原失败:走还原分支(内核不可重启)")
        // 核心:还原真失败 → **绝不清标记**,下次启动重试(否则永久滞留死端口)。
        report.check(store.isPersisted && store.clearCount == 0,
                     "08 修清标记 bug:还原失败 → 保留持久化标记(clearCount=0),下次启动重试(不留死端口后清标记)")
    }

    // ============ ⑧ 修误判:读当前系统代理失败 → deferred,保留标记、不误判「用户改过」============
    private static func testExecutorCaptureFailureDefers(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Ethernet",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: .off, socks: .off)
        ])
        net.failReads = true    // 读当前系统代理(networkServices/proxyState)必失败
        let http = FakeHTTPPort()
        let store = FakeTakeoverStateStore(initial: encodedState(
            TakeoverState(snapshot: SystemProxySnapshot(services: [
                ServiceProxyState(service: "Ethernet", http: .off, https: .off, socks: .off)
            ]), kernelPort: 7890, kernelPID: 6363, kernelExecutablePath: "/fake/mihomo", takeoverAt: 1000)))
        let reaper = FakeProcessReaper(alive: [6363], paths: [6363: "/fake/mihomo"])
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: http, networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090,
                                 stateStore: store, reaper: reaper)

        let r = plugin.selfHeal()
        report.check(r.decision == .deferred,
                     "08 修误判:读当前系统代理失败 → deferred(保守中止,不误判用户改过)")
        report.check(store.isPersisted && store.clearCount == 0,
                     "08 修误判:读代理失败 → 保留持久化标记(不清、不误判 userChanged),待下次启动重试")
        report.check(net.setCalls.isEmpty && net.disableCalls.isEmpty,
                     "08 修误判:采集失败即中止,未对系统代理做任何写入")
    }

    /// 标记存在但损坏绝不能等同于“不存在”；可读写网络时应隔离本地死代理并降级直连。
    private static func testCorruptMarkerDefers(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: ProxySetting(enabled: true, host: "localhost", port: 7890),
                              socks: ProxySetting(enabled: true, host: "203.0.113.8", port: 1080))
        ])
        let store = FakeTakeoverStateStore(initial: Data("not-json".utf8))
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090, stateStore: store)
        let result = plugin.selfHeal()
        report.check(result.decision == .failSafeDirect,
                     "08 损坏标记:存在但解码失败 → failSafeDirect(不得误判 clean)")
        report.check(net.currentState(service: "Wi-Fi")?.http == .off
                     && net.currentState(service: "Wi-Fi")?.https == .off,
                     "08 损坏标记:禁用指向本机的代理，绝不滞留死端口")
        report.check(net.currentState(service: "Wi-Fi")?.socks.host == "203.0.113.8",
                     "08 损坏标记:保留非本机第三方代理")
        report.check(!store.isPersisted && store.clearCount == 1,
                     "08 损坏标记:降级直连成功后清除无效标记")
    }

    private static func testUnreadableMarkerDefers(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi",
                              http: ProxySetting(enabled: true, host: "::1", port: 7890),
                              https: .off, socks: .off)
        ])
        let store = FakeTakeoverStateStore(initial: Data("present".utf8))
        store.failLoads = true
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090, stateStore: store)
        let result = plugin.selfHeal()
        report.check(result.decision == .failSafeDirect,
                     "08 不可读标记:load 抛错 → failSafeDirect(不得误判 missing/clean)")
        report.check(net.currentState(service: "Wi-Fi")?.http == .off,
                     "08 不可读标记:禁用 IPv6 loopback 死代理")
        report.check(!store.isPersisted,
                     "08 不可读标记:降级直连成功后清除无效标记")
    }

    /// 无法完成隔离时必须保留证据并禁止宿主走常规内核启停。
    private static func testInvalidMarkerFallbackFailureBlocksKernel(_ report: inout TestReport) {
        let net = FakeNetworkConfigPort(initial: [
            ServiceProxyState(service: "Wi-Fi",
                              http: ProxySetting(enabled: true, host: "127.0.0.1", port: 7890),
                              https: .off, socks: .off)
        ])
        net.failWrites = true
        let store = FakeTakeoverStateStore(initial: Data("not-json".utf8))
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(), networkConfigPort: net,
                                 kernelPath: nil, controlPort: 9090, stateStore: store)
        let result = plugin.selfHeal()
        report.check(result.decision == .deferred && !result.allowsKernelLaunch,
                     "08 无效标记隔离失败:deferred 且禁止常规内核启停")
        report.check(store.isPersisted && store.clearCount == 0,
                     "08 无效标记隔离失败:保留持久化证据供下次重试")
    }
}
