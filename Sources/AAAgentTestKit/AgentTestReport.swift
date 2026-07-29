// AAAgentTestKit —— AAAgentCore 的独立测试基建(假件 + 纯逻辑一致性测试)。
// 依赖边:AAAgentTestKit → AAAgentCore、AAContracts(+ 系统 Foundation)。
//
// 为守 agent-delegation 与 v1-core-proxy 的**并行红线**,本模块**不复用** `AAHostTestKit.TestReport`:
//   AAHostTestKit 正被 v1-core-proxy(16 票)持续施工,把 AAAgentCore 的测试塞进去会在同一文件 / 同一 target
//   制造合并冲突。故这里另起一个形状与之同构、职责等价的极简断言累加器 `AgentTestReport`。
//   两者接口一致(passed/failed/lines + check),便于将来 11 票 swift-testing 迁移时统一收敛,不牵动对方施工面。

/// 极简断言累加器(不依赖 XCTest / swift-testing —— 本机工具链坏,swift test 不可用;由 check.sh 的 runner 执行)。
/// 形状照抄 `AAHostTestKit.TestReport`(passed / failed / lines + check),但**刻意独立**以避免与 v1 施工撞车。
public struct AgentTestReport: Sendable {
    public private(set) var passed = 0
    public private(set) var failed = 0
    public private(set) var lines: [String] = []

    public init() {}

    /// 记一条断言:成立记 PASS、不成立记 FAIL,并把可读行追加进 lines(供 runner 打印、check.sh 定长子串断言)。
    public mutating func check(_ condition: Bool, _ description: String) {
        if condition {
            passed += 1
            lines.append("PASS: \(description)")
        } else {
            failed += 1
            lines.append("FAIL: \(description)")
        }
    }
}
