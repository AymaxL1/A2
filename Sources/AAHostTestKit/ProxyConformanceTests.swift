// AAHostTestKit —— 06 票插件域逻辑纯逻辑测试(注入假 ProcessPort/HTTPPort,不起真进程 / 不碰真网络)。
// 依赖边:AAHostTestKit → AAPluginSDK、PluginProxy、AAContracts。
//
// 覆盖阶段 B 的三条纯逻辑断言:
//   ① ProcessPort 假件:拉起→探活为真;终止→探活为假;回收调用被记录(反孤儿可核验)。
//   ② REST 客户端:注入假 HTTPPort 预置 JSON,正确解析 version / mode / 端口 / 节点。
//   ③ proxy.status 域逻辑:内核存活→反映真实;内核死亡→如实「未运行」(running:false)且不报错。

import Foundation
import AAContracts
import AAPluginSDK
import PluginProxy

/// mihomo REST 预置 JSON(测试替身数据,与 Scripts/fake-mihomo.py 的输出保持一致)。
private enum StubJSON {
    static let version = #"{"version":"fake-mihomo-0.1 (TEST DOUBLE, NOT real mihomo)","meta":true}"#
    static let configs = #"{"mode":"rule","mixed-port":7890,"port":0,"socks-port":0}"#
    static let proxies = #"{"proxies":{"GLOBAL":{"type":"Selector","now":"","all":["PROXY","DIRECT"]},"PROXY":{"type":"Selector","now":"STUB-NODE","all":["STUB-NODE","DIRECT"]}}}"#
}

/// 06 票纯逻辑一致性测试。
public enum ProxyConformanceTests {
    public static func run() -> TestReport {
        var report = TestReport()
        testProcessPortFake(&report)
        testRESTClientParsing(&report)
        testStatusDomainLogic(&report)
        testPluginCapabilityExposure(&report)
        // 09 票:控制面能力包(模式/节点/组/测速)REST 写读 + 能力暴露纯逻辑。
        testControlPlaneCapabilities(&report)
        // 07 票:系统代理接管/还原纯逻辑(SystemProxyConformanceTests.swift 内的扩展方法)。
        testSystemProxyTakeoverRestore(&report)
        // 08 票:崩溃自愈判定纯逻辑 + 执行编排(CrashRecoveryConformanceTests.swift 内的扩展方法)。
        testCrashSelfHeal(&report)
        // 10 票:订阅管理状态机(list/activate/update+回滚/add)+ 四能力暴露(SubscriptionConformanceTests.swift 内的扩展方法)。
        testSubscriptionManagement(&report)
        return report
    }

    // ① ProcessPort 假件纯逻辑
    private static func testProcessPortFake(_ report: inout TestReport) {
        let pp = FakeProcessPort()
        guard let h = try? pp.launch(executablePath: "/fake/mihomo", arguments: ["--port", "9090"]) else {
            report.check(false, "假 ProcessPort:launch 应成功返回句柄"); return
        }
        report.check(pp.isAlive(h), "假 ProcessPort:拉起后探活为真")
        report.check(pp.launchCalls.first?.path == "/fake/mihomo", "假 ProcessPort:拉起路径被记录")
        report.check(pp.launchCalls.first?.args == ["--port", "9090"], "假 ProcessPort:拉起参数被记录")

        pp.terminate(h)
        report.check(!pp.isAlive(h), "假 ProcessPort:终止后探活为假")
        report.check(pp.terminateCalls.count == 1 && pp.terminateCalls.first == h,
                     "假 ProcessPort:回收调用被记录(反孤儿可核验)")

        // 健康检查:模拟外部被杀 → 探活为假(内核死亡可检测)。
        if let h2 = try? pp.launch(executablePath: "/fake/mihomo", arguments: []) {
            report.check(pp.isAlive(h2), "假 ProcessPort:第二次拉起后存活")
            pp.simulateDeath(h2)
            report.check(!pp.isAlive(h2), "假 ProcessPort:外部死亡后探活为假(健康检查基石)")
        } else {
            report.check(false, "假 ProcessPort:第二次 launch 应成功")
        }
    }

    // ② REST 客户端纯逻辑(注入假 HTTPPort 预置 JSON)
    private static func testRESTClientParsing(_ report: inout TestReport) {
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/version", json: StubJSON.version)
        http.setResponse(pathSuffix: "/configs", json: StubJSON.configs)
        http.setResponse(pathSuffix: "/proxies", json: StubJSON.proxies)
        let rest = MihomoRESTClient(http: http, port: 9090)

        report.check((try? rest.version())?.hasPrefix("fake-mihomo-0.1") == true,
                     "REST 客户端:解析 /version → version")
        let cfg = try? rest.configs()
        report.check(cfg?.mode == "rule", "REST 客户端:解析 /configs → mode=rule")
        report.check(cfg?.mixedPort == 7890, "REST 客户端:解析 /configs → mixed-port=7890")
        let node = try? rest.currentNode()   // Swift 5 try? 摊平 String? 返回,直接得 String?
        report.check(node == "STUB-NODE",
                     "REST 客户端:解析 /proxies → 当前节点 STUB-NODE(跳过空 now 的分组)")

        // URL 构建正确性:确实按 baseURL 打了三条路径。
        report.check(http.requests.contains { $0.url.hasSuffix("/version") }, "REST 客户端:对 /version 发了请求")
        report.check(http.requests.allSatisfy { $0.url.hasPrefix("http://127.0.0.1:9090") },
                     "REST 客户端:URL 构建含正确 host:port 前缀")
    }

    // ③ proxy.status 域逻辑纯逻辑
    private static func testStatusDomainLogic(_ report: inout TestReport) {
        let pp = FakeProcessPort()
        let http = FakeHTTPPort()
        http.setResponse(pathSuffix: "/version", json: StubJSON.version)
        http.setResponse(pathSuffix: "/configs", json: StubJSON.configs)
        http.setResponse(pathSuffix: "/proxies", json: StubJSON.proxies)
        let rest = MihomoRESTClient(http: http, port: 9090)

        guard let h = try? pp.launch(executablePath: "/fake/mihomo", arguments: []) else {
            report.check(false, "status 域逻辑:前置 launch 应成功"); return
        }

        // 内核存活 → status 反映真实(running:true + mode/端口/节点/apiReachable)。
        let alive = ProxyStatus.statusJSON(processPort: pp, handle: h, rest: rest)
        report.check(alive.objectValue?["running"] == .bool(true), "status 域逻辑:内核存活 → running=true")
        report.check(alive.objectValue?["apiReachable"] == .bool(true), "status 域逻辑:存活且 REST 可达 → apiReachable=true")
        report.check(alive.objectValue?["mode"]?.stringValue == "rule", "status 域逻辑:存活时反映真实 mode=rule")
        report.check(alive.objectValue?["mixedPort"] == .number(7890), "status 域逻辑:存活时反映真实监听端口 7890")
        report.check(alive.objectValue?["node"]?.stringValue == "STUB-NODE", "status 域逻辑:存活时反映当前节点 STUB-NODE")

        // 内核死亡 → 如实「未运行」且不报错(running:false,无 mode/端口)。
        pp.simulateDeath(h)
        let dead = ProxyStatus.statusJSON(processPort: pp, handle: h, rest: rest)
        report.check(dead.objectValue?["running"] == .bool(false),
                     "status 域逻辑:内核死亡 → running=false(如实未运行,不报错)")
        report.check(dead.objectValue?["mode"] == nil, "status 域逻辑:未运行时不臆造 mode")

        // 无内核句柄(从未拉起)→ 同样如实未运行。
        let never = ProxyStatus.statusJSON(processPort: pp, handle: nil, rest: rest)
        report.check(never.objectValue?["running"] == .bool(false), "status 域逻辑:无内核句柄 → running=false")

        // 存活但 REST 不可达(未预置任何响应)→ running 仍为 true,apiReachable=false(内核活着控制面未就绪)。
        let ppB = FakeProcessPort()
        let emptyHTTP = FakeHTTPPort()   // 无任何预置 → send 抛错
        let restB = MihomoRESTClient(http: emptyHTTP, port: 9090)
        if let hb = try? ppB.launch(executablePath: "/fake", arguments: []) {
            let s = ProxyStatus.statusJSON(processPort: ppB, handle: hb, rest: restB)
            report.check(s.objectValue?["running"] == .bool(true), "status 域逻辑:进程活但 REST 不可达 → running 仍 true")
            report.check(s.objectValue?["apiReachable"] == .bool(false), "status 域逻辑:REST 不可达 → apiReachable=false")
        } else {
            report.check(false, "status 域逻辑:REST-不可达用例 launch 应成功")
        }
    }

    // ④ 插件能力暴露:ProxyPlugin.capabilities() 产出 proxy.status(safe)+ proxy.system.enable/disable(normal,带 cliAlias),供宿主注册。
    private static func testPluginCapabilityExposure(_ report: inout TestReport) {
        let pp = FakeProcessPort()
        let http = FakeHTTPPort()
        let net = FakeNetworkConfigPort(initial: [])
        let plugin = ProxyPlugin(processPort: pp, httpPort: http, networkConfigPort: net, kernelPath: nil, controlPort: 9090)
        let caps = plugin.capabilities()
        report.check(caps.count == 12, "插件能力:ProxyPlugin 暴露 12 条能力(status + 15 license + system.enable/disable + 09 groups/latency/mode/node + 10 subscription.list/activate/update/add)")

        let status = caps.first { $0.descriptor.id == "proxy.status" }?.descriptor
        report.check(status?.risk == .safe, "插件能力:proxy.status 风险档为 safe")
        report.check(status?.parameters.isEmpty == true, "插件能力:proxy.status 无入参")

        // 07 票:enable/disable 为 normal(→ 零 GUI 确认),各带 cliAlias(aa proxy on|off)。
        let enable = caps.first { $0.descriptor.id == "proxy.system.enable" }?.descriptor
        report.check(enable?.risk == .normal, "插件能力:proxy.system.enable 风险档为 normal(零 GUI 确认)")
        report.check(enable?.cliAlias == ["proxy", "on"], "插件能力:proxy.system.enable 声明 cliAlias=[proxy,on]")
        let disable = caps.first { $0.descriptor.id == "proxy.system.disable" }?.descriptor
        report.check(disable?.risk == .normal, "插件能力:proxy.system.disable 风险档为 normal(零 GUI 确认)")
        report.check(disable?.cliAlias == ["proxy", "off"], "插件能力:proxy.system.disable 声明 cliAlias=[proxy,off]")

        // 未配置内核路径 → launchKernel 返回 false(不视为错误);proxy.status handler 产 running:false 且不报错。
        report.check(plugin.launchKernel() == false, "插件能力:未配置内核路径时 launchKernel()=false(不拉起、不报错)")
        if let handler = caps.first(where: { $0.descriptor.id == "proxy.status" })?.handler {
            switch handler(nil) {
            case .success(let out):
                report.check(out.objectValue?["running"] == .bool(false),
                             "插件能力:未运行时 handler 返回 .success(running:false),映射退出码 0")
            case .failure:
                report.check(false, "插件能力:未运行时 handler 不应返回 .failure")
            }
        } else {
            report.check(false, "插件能力:应能取到 proxy.status 的 handler")
        }
    }

    // ⑤ 09 票:控制面 REST 写/读扩展 + 四能力暴露(注入 FakeHTTPPort 预置响应,纯逻辑,不起真内核)。
    private static func testControlPlaneCapabilities(_ report: inout TestReport) {
        // 测试用 /proxies:两组(GLOBAL now="" / PROXY now=STUB-NODE),PROXY 三候选(含一个将超时的 SLOW-NODE)。
        let proxiesJSON = #"""
        {"proxies":{
          "DIRECT":{"type":"Direct"},
          "GLOBAL":{"type":"Selector","now":"","all":["PROXY","DIRECT"]},
          "PROXY":{"type":"Selector","now":"STUB-NODE","all":["STUB-NODE","NODE-B","SLOW-NODE"]}
        }}
        """#

        // —— (a) groups() 解析组/候选/now ——
        let httpG = FakeHTTPPort()
        httpG.setResponse(pathSuffix: "/proxies", method: .get, json: proxiesJSON)
        let restG = MihomoRESTClient(http: httpG, port: 9090)
        let groups = (try? restG.groups()) ?? []
        let proxyGroup = groups.first { $0.name == "PROXY" }
        report.check(proxyGroup != nil && proxyGroup?.all == ["STUB-NODE", "NODE-B", "SLOW-NODE"],
                     "09 groups.list:解析出分组 PROXY(含候选节点 STUB-NODE/NODE-B/SLOW-NODE)")
        report.check(proxyGroup?.now == "STUB-NODE", "09 groups.list:PROXY 当前选中 now=STUB-NODE")
        report.check(groups.first { $0.name == "GLOBAL" }?.now == nil,
                     "09 groups.list:空 now 归一为 nil(GLOBAL now=\"\"→nil)")

        // —— (b) setMode 构造对的 PATCH /configs(body mode=global)——(真核约定 PATCH,非 PUT)
        let httpM = FakeHTTPPort()
        httpM.setResponse(pathSuffix: "/configs", method: .patch, statusCode: 204)
        let restM = MihomoRESTClient(http: httpM, port: 9090)
        let modeOK = (try? restM.setMode("global")) != nil
        let patchConfigs = httpM.requests.first { $0.method == .patch && $0.url.hasSuffix("/configs") }
        var modeBodyOK = false
        if let b = patchConfigs?.body, let j = try? JSONDecoder().decode(JSONValue.self, from: b) {
            modeBodyOK = j.objectValue?["mode"]?.stringValue == "global"
        }
        report.check(modeOK && patchConfigs != nil && modeBodyOK,
                     "09 mode.set:构造对的 PATCH /configs(body mode=global)")

        // —— (c) selectNode 构造对的 PUT /proxies/<group>(body name=NODE-B)——
        let httpN = FakeHTTPPort()
        httpN.setResponse(pathSuffix: "/proxies/PROXY", method: .put, statusCode: 204)
        let restN = MihomoRESTClient(http: httpN, port: 9090)
        let selOK = (try? restN.selectNode(group: "PROXY", node: "NODE-B")) != nil
        let putProxies = httpN.requests.first { $0.method == .put && $0.url.hasSuffix("/proxies/PROXY") }
        var nodeBodyOK = false
        if let b = putProxies?.body, let j = try? JSONDecoder().decode(JSONValue.self, from: b) {
            nodeBodyOK = j.objectValue?["name"]?.stringValue == "NODE-B"
        }
        report.check(selOK && putProxies != nil && nodeBodyOK,
                     "09 node.select:构造对的 PUT /proxies/PROXY(body name=NODE-B)")

        // —— (d) testGroupLatency 逐节点延迟 + 超时如实标注(SLOW-NODE 从 delay map 缺席=超时)——
        let httpL = FakeHTTPPort()
        httpL.setResponse(pathSuffix: "/proxies", method: .get, json: proxiesJSON)
        httpL.setResponse(pathSuffix: "/delay", method: .get,
                          json: #"{"STUB-NODE":120,"NODE-B":340}"#)   // SLOW-NODE 缺席 → 超时
        let restL = MihomoRESTClient(http: httpL, port: 9090)
        let results = (try? restL.testGroupLatency(group: "PROXY", testURL: "http://example/generate_204", timeoutMs: 5000)) ?? []
        report.check(results.count == 3 && results.map { $0.node } == ["STUB-NODE", "NODE-B", "SLOW-NODE"],
                     "09 latency:逐候选节点对齐输出(3 个,顺序同 all)")
        report.check(results.first { $0.node == "STUB-NODE" }?.delayMs == 120,
                     "09 latency:逐节点延迟解析(STUB-NODE=120ms)")
        let slow = results.first { $0.node == "SLOW-NODE" }
        report.check(slow?.delayMs == nil && slow?.timedOut == true,
                     "09 latency:超时节点如实标注(SLOW-NODE delayMs=nil, timeout=true)")
        // 测速 URL 构建含 group 段与 query。
        report.check(httpL.requests.contains { $0.url.contains("/group/PROXY/delay?url=") && $0.url.contains("timeout=5000") },
                     "09 latency:GET /group/PROXY/delay?url=&timeout=5000 URL 构建正确")

        // —— (e) 四能力暴露:风险级 + cliAlias + 参数 schema(含 mode 的 allowedValues)——
        let pp = FakeProcessPort()
        let net = FakeNetworkConfigPort(initial: [])
        let plugin = ProxyPlugin(processPort: pp, httpPort: FakeHTTPPort(), networkConfigPort: net, kernelPath: nil, controlPort: 9090)
        let caps = plugin.capabilities()
        func desc(_ id: String) -> CapabilityDescriptor? { caps.first { $0.descriptor.id == id }?.descriptor }

        let gl = desc("proxy.groups.list")
        report.check(gl?.risk == .safe && gl?.cliAlias == ["proxy", "groups"] && gl?.parameters.isEmpty == true,
                     "09 能力暴露:proxy.groups.list=safe cliAlias[proxy,groups] 无入参")
        let lt = desc("proxy.latency.test")
        report.check(lt?.risk == .safe && lt?.cliAlias == ["proxy", "ping"], "09 能力暴露:proxy.latency.test=safe cliAlias[proxy,ping]")
        report.check(lt?.parameters.first { $0.name == "timeout" }?.type == "number",
                     "09 能力暴露:proxy.latency.test 的 timeout 声明为 number(强转基石)")
        report.check(lt?.parameters.first { $0.name == "group" }?.required == true,
                     "09 能力暴露:proxy.latency.test 的 group 必填")
        let ms = desc("proxy.mode.set")
        report.check(ms?.risk == .normal && ms?.cliAlias == ["proxy", "mode"], "09 能力暴露:proxy.mode.set=normal cliAlias[proxy,mode]")
        report.check(ms?.parameters.first { $0.name == "mode" }?.allowedValues == ["rule", "global", "direct"],
                     "09 能力暴露:proxy.mode.set 的 mode 声明 allowedValues[rule,global,direct]")
        let ns = desc("proxy.node.select")
        report.check(ns?.risk == .normal && ns?.cliAlias == ["proxy", "node"], "09 能力暴露:proxy.node.select=normal cliAlias[proxy,node]")
        report.check(ns?.parameters.map { $0.name } == ["group", "node"] && ns?.parameters.allSatisfy { $0.required } == true,
                     "09 能力暴露:proxy.node.select 参数 group+node 均必填")

        // —— (f) 宿主侧防呆:超大**有限** timeout(1e300)→ handler 返回 invalid_params,绝不 `Int(Double)` 越界 trap 崩宿主 ——
        //   守卫在 handler 早于任何 REST 调用触发,故 FakeHTTPPort 无预置也不会打到网络。
        if let latencyHandler = caps.first(where: { $0.descriptor.id == "proxy.latency.test" })?.handler {
            switch latencyHandler(.object(["group": .string("PROXY"), "timeout": .number(1e300)])) {
            case .failure(let err):
                report.check(err.code == WireErrorCode.invalidParams,
                             "09 防呆:超大有限 timeout(1e300)→ invalid_params(不 Int(Double) 越界崩宿主)")
            case .success:
                report.check(false, "09 防呆:超大 timeout(1e300)应被拒为 invalid_params,而非放行")
            }
        } else {
            report.check(false, "09 防呆:应能取到 proxy.latency.test 的 handler")
        }
    }
}
