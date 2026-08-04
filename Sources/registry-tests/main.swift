// registry-tests —— 反孤儿信号探针的宿主可执行(门禁内部工具,非对外产品)。
//
// **17 票之后它只剩这一件事。** 此前它是 `AAHostTestKit` + `AAAgentTestKit` 里那 ~4500 行手写
//   `TestReport` 断言的统一入口;17 票把那些断言整体迁进 `Tests/`(swift-testing),由 `swift test` 跑。
//
// 为什么这个 target **必须留着**(不是留恋,是有唯一消费者):
//   `Scripts/check/agent-e2e.sh` 拿它当**反孤儿信号探针**——`AA_ORPHAN_PROBE=exit` 证明 atexit 钩子
//   回收整个进程组,`=signal` 证明 SIGTERM 钩子同样回收。那件事**在测试进程内根本验不了**:
//   它要求宿主真的死一次,而 `swift test` 的宿主进程不能中途 exit(一 exit 整轮测试就没了)。
//   SPM 的 executableTarget 又不能依赖 testTarget,故探针本体留在 `Sources/AAAgentTestKit/
//   SystemAgentPortOrphanProbe.swift`,由本文件拉起。
//
// 这个文件**可以**叫 main.swift:它是顶层代码,没有构造 `@MainActor` 对象的需求
//   (与 `Sources/aahost/AAHostMain.swift` 相反 —— 那边必须避开 main.swift)。
import AAAgentTestKit
import AAContracts
import Foundation

if let probeMode = ProcessInfo.processInfo.environment["AA_ORPHAN_PROBE"] {
    SystemAgentPortOrphanProbe.run(mode: probeMode)   // 不返回(各分支自己 exit)
}

// 没给探针模式就是**用错了**:17 票之后这个可执行不再跑任何断言。
//   刻意以非零退出 —— 若哪天有人把它当「跑单元测试」用,必须当场红,而不是静默地「全绿地什么都没跑」。
//
// 退出码取 `AAExitCode.usage`(=1),**不写裸 2**:
//   本仓库的退出码是**单一来源**(`AAContracts.AAExitCode`),散写魔数是明令禁止的;
//   而且 2 在那张锁定表里是 **denied**(dangerous 被拒),用它表达「用法错」是拿错了语义 ——
//   将来有人照着退出码判因,会被这条误导。「用法错」在表里就是 1,直接用它。
//   (双轴 CR 抓到:原先写的是裸 `exit(2)`,两条都犯了。)
FileHandle.standardError.write(Data("""
registry-tests:本可执行自 17 票起只作为反孤儿信号探针,不再运行任何断言。
  用法: AA_ORPHAN_PROBE=exit|signal registry-tests
  单元/域逻辑断言已全部迁至 swift-testing,跑法: bash Scripts/check.sh(或 swift test --disable-xctest --enable-swift-testing)

""".utf8))
exit(AAExitCode.usage)
