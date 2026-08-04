// 17 票:从 `AAHostTestKit.ProxyConformanceTests` 迁到 swift-testing(迁移口径见 RegistryConformanceTests.swift 头注)。
//
// 06 票插件域逻辑纯逻辑测试(注入假 ProcessPort/HTTPPort,不起真进程 / 不碰真网络)+ 09 票控制面能力包。
// 依赖边:AAHostTestKitTests → AAHostTestKit(假件)、AAPluginSDK、PluginProxy、AAContracts。

import Foundation
import Testing
import AAContracts
import AAPluginSDK
import PluginProxy
import AAHostTestKit

/// mihomo REST 预置 JSON(测试替身数据,与 Scripts/fake-mihomo.py 的输出保持一致)。
private enum StubJSON {
    static let version = #"{"version":"fake-mihomo-0.1 (TEST DOUBLE, NOT real mihomo)","meta":true}"#
    static let configs = #"{"mode":"rule","mixed-port":7890,"port":0,"socks-port":0}"#
    static let proxies = #"{"proxies":{"GLOBAL":{"type":"Selector","now":"","all":["PROXY","DIRECT"]},"PROXY":{"type":"Selector","now":"STUB-NODE","all":["STUB-NODE","DIRECT"]}}}"#

    /// 09 票用:两组(GLOBAL now="" / PROXY now=STUB-NODE),PROXY 三候选(含一个将超时的 SLOW-NODE)。
    static let proxiesWithGroups = #"""
    {"proxies":{
      "DIRECT":{"type":"Direct"},
      "GLOBAL":{"type":"Selector","now":"","all":["PROXY","DIRECT"]},
      "PROXY":{"type":"Selector","now":"STUB-NODE","all":["STUB-NODE","NODE-B","SLOW-NODE"]}
    }}
    """#
}

@Suite("06 插件域逻辑 + 09 控制面能力包纯逻辑 —— PROXY_TESTS passed=(逐条 @Test)")
struct ProxyConformanceTests {

    // ============ ① ProcessPort 假件纯逻辑 ============

    @Test("假 ProcessPort:拉起后探活为真")
    func processPortLaunch() throws {
        let pp = FakeProcessPort()
        let h = try #require(try? pp.launch(executablePath: "/fake/mihomo", arguments: ["--port", "9090"]),
                             "假 ProcessPort:launch 应成功返回句柄")
        #expect(pp.isAlive(h), "假 ProcessPort:拉起后探活为真")
        #expect(pp.launchCalls.first?.path == "/fake/mihomo", "假 ProcessPort:拉起路径被记录")
        #expect(pp.launchCalls.first?.args == ["--port", "9090"], "假 ProcessPort:拉起参数被记录")
    }

    @Test("假 ProcessPort:终止后探活为假 / 假 ProcessPort:回收调用被记录(反孤儿可核验)")
    func processPortTerminate() throws {
        let pp = FakeProcessPort()
        let h = try #require(try? pp.launch(executablePath: "/fake/mihomo", arguments: []),
                             "假 ProcessPort:launch 应成功返回句柄(终止用例前置)")
        pp.terminate(h)
        #expect(!pp.isAlive(h), "假 ProcessPort:终止后探活为假")
        #expect(pp.terminateCalls.count == 1 && pp.terminateCalls.first == h,
                "假 ProcessPort:回收调用被记录(反孤儿可核验)")
    }

    @Test("假 ProcessPort:外部死亡后探活为假(健康检查基石)")
    func processPortExternalDeath() throws {
        let pp = FakeProcessPort()
        let h2 = try #require(try? pp.launch(executablePath: "/fake/mihomo", arguments: []),
                              "假 ProcessPort:第二次 launch 应成功")
        #expect(pp.isAlive(h2), "假 ProcessPort:第二次拉起后存活")
        pp.simulateDeath(h2)
        #expect(!pp.isAlive(h2), "假 ProcessPort:外部死亡后探活为假(健康检查基石)")
    }

    // ============ ② REST 客户端纯逻辑(注入假 HTTPPort 预置 JSON)============

    @Test("REST 客户端:解析 /configs → mode=rule / REST 客户端:解析 /configs → mixed-port=7890 / REST 客户端:解析 /proxies → 当前节点 STUB-NODE(跳过空 now 的分组)")
    func restClientParsing() {
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/version", json: StubJSON.version)
        http.setResponse(pathSuffix: "/configs", json: StubJSON.configs)
        http.setResponse(pathSuffix: "/proxies", json: StubJSON.proxies)
        let rest = MihomoRESTClient(http: http, port: 9090)

        #expect((try? rest.version())?.hasPrefix("fake-mihomo-0.1") == true,
                "REST 客户端:解析 /version → version")
        let cfg = try? rest.configs()
        #expect(cfg?.mode == "rule", "REST 客户端:解析 /configs → mode=rule")
        #expect(cfg?.mixedPort == 7890, "REST 客户端:解析 /configs → mixed-port=7890")
        let node = try? rest.currentNode()   // Swift 5 try? 摊平 String? 返回,直接得 String?
        #expect(node == "STUB-NODE",
                "REST 客户端:解析 /proxies → 当前节点 STUB-NODE(跳过空 now 的分组)")

        // URL 构建正确性:确实按 baseURL 打了三条路径。
        #expect(http.requests.contains { $0.url.hasSuffix("/version") }, "REST 客户端:对 /version 发了请求")
        #expect(http.requests.allSatisfy { $0.url.hasPrefix("http://127.0.0.1:9090") },
                "REST 客户端:URL 构建含正确 host:port 前缀")
    }

    // ============ ③ proxy.status 域逻辑纯逻辑 ============

    @Test("status 域逻辑:内核存活 → running=true(并如实反映 mode/端口/节点/apiReachable)")
    func statusAlive() throws {
        let pp = FakeProcessPort()
        let rest = Self.stubbedREST()
        let h = try #require(try? pp.launch(executablePath: "/fake/mihomo", arguments: []),
                             "status 域逻辑:前置 launch 应成功")

        let alive = ProxyStatus.statusJSON(processPort: pp, handle: h, rest: rest)
        #expect(alive.objectValue?["running"] == .bool(true), "status 域逻辑:内核存活 → running=true")
        #expect(alive.objectValue?["apiReachable"] == .bool(true), "status 域逻辑:存活且 REST 可达 → apiReachable=true")
        #expect(alive.objectValue?["mode"]?.stringValue == "rule", "status 域逻辑:存活时反映真实 mode=rule")
        #expect(alive.objectValue?["mixedPort"] == .number(7890), "status 域逻辑:存活时反映真实监听端口 7890")
        #expect(alive.objectValue?["node"]?.stringValue == "STUB-NODE", "status 域逻辑:存活时反映当前节点 STUB-NODE")
    }

    @Test("status 域逻辑:内核死亡 → running=false(如实未运行,不报错) / status 域逻辑:无内核句柄 → running=false")
    func statusDeadOrAbsent() throws {
        let pp = FakeProcessPort()
        let rest = Self.stubbedREST()
        let h = try #require(try? pp.launch(executablePath: "/fake/mihomo", arguments: []),
                             "status 域逻辑:前置 launch 应成功(死亡用例)")

        pp.simulateDeath(h)
        let dead = ProxyStatus.statusJSON(processPort: pp, handle: h, rest: rest)
        #expect(dead.objectValue?["running"] == .bool(false),
                "status 域逻辑:内核死亡 → running=false(如实未运行,不报错)")
        #expect(dead.objectValue?["mode"] == nil, "status 域逻辑:未运行时不臆造 mode")

        let never = ProxyStatus.statusJSON(processPort: pp, handle: nil, rest: rest)
        #expect(never.objectValue?["running"] == .bool(false), "status 域逻辑:无内核句柄 → running=false")
    }

    @Test("status 域逻辑:进程活但 REST 不可达 → running 仍 true、apiReachable=false")
    func statusApiUnreachable() throws {
        let ppB = FakeProcessPort()
        let emptyHTTP = FakeHTTPPort()   // 无任何预置 → send 抛错
        let restB = MihomoRESTClient(http: emptyHTTP, port: 9090)
        let hb = try #require(try? ppB.launch(executablePath: "/fake", arguments: []),
                              "status 域逻辑:REST-不可达用例 launch 应成功")
        let s = ProxyStatus.statusJSON(processPort: ppB, handle: hb, rest: restB)
        #expect(s.objectValue?["running"] == .bool(true), "status 域逻辑:进程活但 REST 不可达 → running 仍 true")
        #expect(s.objectValue?["apiReachable"] == .bool(false), "status 域逻辑:REST 不可达 → apiReachable=false")
    }

    // ============ ④ 插件能力暴露 ============

    @Test("插件能力:ProxyPlugin 暴露 12 条能力,status/system.enable/system.disable 的风险档与 cliAlias 正确")
    func pluginCapabilityExposure() {
        let pp = FakeProcessPort()
        let http = FakeHTTPPort()
        let net = FakeNetworkConfigPort(initial: [])
        let plugin = ProxyPlugin(processPort: pp, httpPort: http, networkConfigPort: net, kernelPath: nil, controlPort: 9090)
        let caps = plugin.capabilities()
        #expect(caps.count == 12, "插件能力:ProxyPlugin 暴露 12 条能力(status + 15 license + system.enable/disable + 09 groups/latency/mode/node + 10 subscription.list/activate/update/add)")

        let status = caps.first { $0.descriptor.id == "proxy.status" }?.descriptor
        #expect(status?.risk == .safe, "插件能力:proxy.status 风险档为 safe")
        #expect(status?.parameters.isEmpty == true, "插件能力:proxy.status 无入参")

        // 07 票:enable/disable 为 normal(→ 零 GUI 确认),各带 cliAlias(aa proxy on|off)。
        let enable = caps.first { $0.descriptor.id == "proxy.system.enable" }?.descriptor
        #expect(enable?.risk == .normal, "插件能力:proxy.system.enable 风险档为 normal(零 GUI 确认)")
        #expect(enable?.cliAlias == ["proxy", "on"], "插件能力:proxy.system.enable 声明 cliAlias=[proxy,on]")
        let disable = caps.first { $0.descriptor.id == "proxy.system.disable" }?.descriptor
        #expect(disable?.risk == .normal, "插件能力:proxy.system.disable 风险档为 normal(零 GUI 确认)")
        #expect(disable?.cliAlias == ["proxy", "off"], "插件能力:proxy.system.disable 声明 cliAlias=[proxy,off]")

        // 未配置内核路径 → launchKernel 返回 false(不视为错误);proxy.status handler 产 running:false 且不报错。
        #expect(plugin.launchKernel() == false, "插件能力:未配置内核路径时 launchKernel()=false(不拉起、不报错)")
        if let handler = caps.first(where: { $0.descriptor.id == "proxy.status" })?.handler {
            switch handler(nil) {
            case .success(let out):
                #expect(out.objectValue?["running"] == .bool(false),
                        "插件能力:未运行时 handler 返回 .success(running:false),映射退出码 0")
            case .failure:
                Issue.record("插件能力:未运行时 handler 不应返回 .failure")
            }
        } else {
            Issue.record("插件能力:应能取到 proxy.status 的 handler")
        }
    }

    // ============ ⑤ 09 票:控制面 REST 写/读扩展 + 四能力暴露 ============

    @Test("09 groups.list:解析出分组 PROXY(含候选节点 STUB-NODE/NODE-B/SLOW-NODE) / 09 groups.list:PROXY 当前选中 now=STUB-NODE")
    func controlPlaneGroups() {
        let httpG = FakeHTTPPort()
        httpG.setResponse(pathSuffix: "/proxies", method: .get, json: StubJSON.proxiesWithGroups)
        let restG = MihomoRESTClient(http: httpG, port: 9090)
        let groups = (try? restG.groups()) ?? []
        let proxyGroup = groups.first { $0.name == "PROXY" }
        #expect(proxyGroup != nil && proxyGroup?.all == ["STUB-NODE", "NODE-B", "SLOW-NODE"],
                "09 groups.list:解析出分组 PROXY(含候选节点 STUB-NODE/NODE-B/SLOW-NODE)")
        #expect(proxyGroup?.now == "STUB-NODE", "09 groups.list:PROXY 当前选中 now=STUB-NODE")
        #expect(groups.first { $0.name == "GLOBAL" }?.now == nil,
                "09 groups.list:空 now 归一为 nil(GLOBAL now=\"\"→nil)")
    }

    @Test("09 mode.set:构造对的 PATCH /configs(body mode=global)")
    func controlPlaneSetMode() {
        let httpM = FakeHTTPPort()
        httpM.setResponse(pathSuffix: "/configs", method: .patch, statusCode: 204)
        let restM = MihomoRESTClient(http: httpM, port: 9090)
        let modeOK = (try? restM.setMode("global")) != nil
        let patchConfigs = httpM.requests.first { $0.method == .patch && $0.url.hasSuffix("/configs") }
        var modeBodyOK = false
        if let b = patchConfigs?.body, let j = try? JSONDecoder().decode(JSONValue.self, from: b) {
            modeBodyOK = j.objectValue?["mode"]?.stringValue == "global"
        }
        #expect(modeOK && patchConfigs != nil && modeBodyOK,
                "09 mode.set:构造对的 PATCH /configs(body mode=global)")
    }

    @Test("09 node.select:构造对的 PUT /proxies/PROXY(body name=NODE-B)")
    func controlPlaneSelectNode() {
        let httpN = FakeHTTPPort()
        httpN.setResponse(pathSuffix: "/proxies/PROXY", method: .put, statusCode: 204)
        let restN = MihomoRESTClient(http: httpN, port: 9090)
        let selOK = (try? restN.selectNode(group: "PROXY", node: "NODE-B")) != nil
        let putProxies = httpN.requests.first { $0.method == .put && $0.url.hasSuffix("/proxies/PROXY") }
        var nodeBodyOK = false
        if let b = putProxies?.body, let j = try? JSONDecoder().decode(JSONValue.self, from: b) {
            nodeBodyOK = j.objectValue?["name"]?.stringValue == "NODE-B"
        }
        #expect(selOK && putProxies != nil && nodeBodyOK,
                "09 node.select:构造对的 PUT /proxies/PROXY(body name=NODE-B)")
    }

    @Test("09 latency:逐节点延迟解析(STUB-NODE=120ms) / 09 latency:超时节点如实标注(SLOW-NODE delayMs=nil, timeout=true)")
    func controlPlaneLatency() {
        let httpL = FakeHTTPPort()
        httpL.setResponse(pathSuffix: "/proxies", method: .get, json: StubJSON.proxiesWithGroups)
        httpL.setResponse(pathSuffix: "/delay", method: .get,
                          json: #"{"STUB-NODE":120,"NODE-B":340}"#)   // SLOW-NODE 缺席 → 超时
        let restL = MihomoRESTClient(http: httpL, port: 9090)
        let results = (try? restL.testGroupLatency(group: "PROXY", testURL: "http://example/generate_204", timeoutMs: 5000)) ?? []
        #expect(results.count == 3 && results.map { $0.node } == ["STUB-NODE", "NODE-B", "SLOW-NODE"],
                "09 latency:逐候选节点对齐输出(3 个,顺序同 all)")
        #expect(results.first { $0.node == "STUB-NODE" }?.delayMs == 120,
                "09 latency:逐节点延迟解析(STUB-NODE=120ms)")
        let slow = results.first { $0.node == "SLOW-NODE" }
        #expect(slow?.delayMs == nil && slow?.timedOut == true,
                "09 latency:超时节点如实标注(SLOW-NODE delayMs=nil, timeout=true)")
        #expect(httpL.requests.contains { $0.url.contains("/group/PROXY/delay?url=") && $0.url.contains("timeout=5000") },
                "09 latency:GET /group/PROXY/delay?url=&timeout=5000 URL 构建正确")
    }

    @Test("09 能力暴露:proxy.groups.list=safe cliAlias[proxy,groups] 无入参 / 09 能力暴露:proxy.latency.test=safe cliAlias[proxy,ping]")
    func controlPlaneExposureReadSide() {
        let caps = Self.controlPlaneCapabilities()
        func desc(_ id: String) -> CapabilityDescriptor? { caps.first { $0.descriptor.id == id }?.descriptor }

        let gl = desc("proxy.groups.list")
        #expect(gl?.risk == .safe && gl?.cliAlias == ["proxy", "groups"] && gl?.parameters.isEmpty == true,
                "09 能力暴露:proxy.groups.list=safe cliAlias[proxy,groups] 无入参")
        let lt = desc("proxy.latency.test")
        #expect(lt?.risk == .safe && lt?.cliAlias == ["proxy", "ping"], "09 能力暴露:proxy.latency.test=safe cliAlias[proxy,ping]")
        #expect(lt?.parameters.first { $0.name == "timeout" }?.type == "number",
                "09 能力暴露:proxy.latency.test 的 timeout 声明为 number(强转基石)")
        #expect(lt?.parameters.first { $0.name == "group" }?.required == true,
                "09 能力暴露:proxy.latency.test 的 group 必填")
    }

    @Test("09 能力暴露:proxy.mode.set=normal cliAlias[proxy,mode] / 09 能力暴露:proxy.mode.set 的 mode 声明 allowedValues[rule,global,direct] / 09 能力暴露:proxy.node.select=normal cliAlias[proxy,node]")
    func controlPlaneExposureWriteSide() {
        let caps = Self.controlPlaneCapabilities()
        func desc(_ id: String) -> CapabilityDescriptor? { caps.first { $0.descriptor.id == id }?.descriptor }

        let ms = desc("proxy.mode.set")
        #expect(ms?.risk == .normal && ms?.cliAlias == ["proxy", "mode"], "09 能力暴露:proxy.mode.set=normal cliAlias[proxy,mode]")
        #expect(ms?.parameters.first { $0.name == "mode" }?.allowedValues == ["rule", "global", "direct"],
                "09 能力暴露:proxy.mode.set 的 mode 声明 allowedValues[rule,global,direct]")
        let ns = desc("proxy.node.select")
        #expect(ns?.risk == .normal && ns?.cliAlias == ["proxy", "node"], "09 能力暴露:proxy.node.select=normal cliAlias[proxy,node]")
        #expect(ns?.parameters.map { $0.name } == ["group", "node"] && ns?.parameters.allSatisfy { $0.required } == true,
                "09 能力暴露:proxy.node.select 参数 group+node 均必填")
    }

    @Test("09 防呆:超大有限 timeout(1e300)→ invalid_params(不 Int(Double) 越界崩宿主)")
    func controlPlaneHugeTimeoutIsRejected() {
        // 守卫在 handler 早于任何 REST 调用触发,故 FakeHTTPPort 无预置也不会打到网络。
        let caps = Self.controlPlaneCapabilities()
        if let latencyHandler = caps.first(where: { $0.descriptor.id == "proxy.latency.test" })?.handler {
            switch latencyHandler(.object(["group": .string("PROXY"), "timeout": .number(1e300)])) {
            case .failure(let err):
                #expect(err.code == WireErrorCode.invalidParams,
                        "09 防呆:超大有限 timeout(1e300)→ invalid_params(不 Int(Double) 越界崩宿主)")
            case .success:
                Issue.record("09 防呆:超大 timeout(1e300)应被拒为 invalid_params,而非放行")
            }
        } else {
            Issue.record("09 防呆:应能取到 proxy.latency.test 的 handler")
        }
    }

    // ============ 助手 ============

    private static func stubbedREST() -> MihomoRESTClient {
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/version", json: StubJSON.version)
        http.setResponse(pathSuffix: "/configs", json: StubJSON.configs)
        http.setResponse(pathSuffix: "/proxies", json: StubJSON.proxies)
        return MihomoRESTClient(http: http, port: 9090)
    }

    private static func controlPlaneCapabilities() -> [PluginCapability] {
        let plugin = ProxyPlugin(processPort: FakeProcessPort(), httpPort: FakeHTTPPort(),
                                 networkConfigPort: FakeNetworkConfigPort(initial: []),
                                 kernelPath: nil, controlPort: 9090)
        return plugin.capabilities()
    }
}
