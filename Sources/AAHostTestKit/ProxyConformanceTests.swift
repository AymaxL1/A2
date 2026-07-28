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

    // ④ 插件能力暴露:ProxyPlugin.capabilities() 产出 proxy.status(safe,无入参),供宿主注册。
    private static func testPluginCapabilityExposure(_ report: inout TestReport) {
        let pp = FakeProcessPort()
        let http = FakeHTTPPort()
        let plugin = ProxyPlugin(processPort: pp, httpPort: http, kernelPath: nil, controlPort: 9090)
        let caps = plugin.capabilities()
        report.check(caps.count == 1, "插件能力:ProxyPlugin 暴露 1 条能力")
        let d = caps.first?.descriptor
        report.check(d?.id == "proxy.status", "插件能力:id 为 proxy.status")
        report.check(d?.risk == .safe, "插件能力:proxy.status 风险档为 safe")
        report.check(d?.parameters.isEmpty == true, "插件能力:proxy.status 无入参")

        // 未配置内核路径 → launchKernel 返回 false(不视为错误);handler 产 running:false 且不报错。
        report.check(plugin.launchKernel() == false, "插件能力:未配置内核路径时 launchKernel()=false(不拉起、不报错)")
        if let handler = caps.first?.handler {
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
}
