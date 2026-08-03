// registry-tests —— 宿主与 agent 两套测试基建的统一入口(门禁内部工具,非对外产品)。
//
// 11 票之前:这段代码是 `Scripts/check/build.sh` 用 heredoc **动态生成**到 .build/ 下再 swiftc 直编的。
//   换成 `swift build` 之后 SPM 只认真源文件,故固化成本 target。**内容与那段 heredoc 逐字一致**:
//   下游 `Scripts/check/unit-and-domain.sh` 在 grep 这些 print 的字面文本,改一个字都会红。
//
// 这个文件**可以**叫 main.swift:它是顶层代码,没有构造 `@MainActor` 对象的需求
//   (与 `Sources/aahost/AAHostMain.swift` 相反 —— 那边必须避开 main.swift)。
//
// 断言逻辑本身在 `Sources/AAHostTestKit/` 与 `Sources/AAAgentTestKit/` 的手写 `TestReport` 框架里;
//   把它们改写成 swift-testing 的 `#expect` 归 17 票,本文件届时才会退役。
import AAHostTestKit
import AAAgentTestKit
import Foundation
if let probeMode = ProcessInfo.processInfo.environment["AA_ORPHAN_PROBE"] {
    SystemAgentPortOrphanProbe.run(mode: probeMode)
}
let r1 = RegistryConformanceTests.run()
for line in r1.lines { print(line) }
let r2 = ProxyConformanceTests.run()
for line in r2.lines { print(line) }
let r3 = AAAgentCoreConformanceTests.run()
for line in r3.lines { print(line) }
let r4 = ClaudeAdapterTests.run()
for line in r4.lines { print(line) }
let r5 = CodexAdapterTests.run()
for line in r5.lines { print(line) }
let r6 = AgentTaskTests.run()
for line in r6.lines { print(line) }
let r7 = AgentWatchdogTests.run()
for line in r7.lines { print(line) }
let r8 = SystemAgentPortTests.run()
for line in r8.lines { print(line) }
let r9 = AgentLaunchAssemblerTests.run()
for line in r9.lines { print(line) }
print("REGISTRY_TESTS passed=\(r1.passed) failed=\(r1.failed)")
print("PROXY_TESTS passed=\(r2.passed) failed=\(r2.failed)")
print("AGENTCORE_TESTS passed=\(r3.passed) failed=\(r3.failed)")
print("CLAUDEADAPTER_TESTS passed=\(r4.passed) failed=\(r4.failed)")
print("CODEXADAPTER_TESTS passed=\(r5.passed) failed=\(r5.failed)")
print("AGENTTASK_TESTS passed=\(r6.passed) failed=\(r6.failed)")
print("WATCHDOG_TESTS passed=\(r7.passed) failed=\(r7.failed)")
print("SYSTEMPORT_TESTS passed=\(r8.passed) failed=\(r8.failed)")
print("LAUNCHASM_TESTS passed=\(r9.passed) failed=\(r9.failed)")
let passed = r1.passed + r2.passed + r3.passed + r4.passed + r5.passed + r6.passed + r7.passed + r8.passed + r9.passed
let failed = r1.failed + r2.failed + r3.failed + r4.failed + r5.failed + r6.failed + r7.failed + r8.failed + r9.failed
print("ALL_UNIT passed=\(passed) failed=\(failed)")
fflush(stdout)
exit(failed == 0 ? 0 : 1)
