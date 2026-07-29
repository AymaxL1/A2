// AAAgentCore —— 一次 agent 进程执行的抽象 `AgentPort`(把所有子进程副作用压到端口之后)。
// 依赖边:AAAgentCore → AAContracts(仅此;不 import Foundation、不 import 任何 Host*)。
//
// 为何自定义 AgentPort、不复用 AAPluginSDK.ProcessPort:AAAgentCore 的依赖边只到 Contracts
//   (spec:与 v1-core-proxy 的 16 票并行落地、互不踩施工面),够不着 SDK。故这里另立一个
//   贴合 agent 执行形态的最小端口:以「行式事件流」为核心(agent stdout 逐行),外加显式 stdin 处置
//   (两家 agent 对 stdin 生命周期的要求相反,见 AgentStdinDisposition)。
//
// 一切 agent 子进程副作用(拉起、探活、流式读、终止)压到本端口之后 → 任务状态机 / 归一化 / 生命周期 /
//   看门狗均可在 `FakeAgentPort` 上纯逻辑测试,零真实 agent 依赖(spec Testing Decisions 主 seam)。

import AAContracts

/// 一个被拉起的 agent 进程的不透明句柄。
///
/// 不暴露真实 pid / Process 对象(那是真实现细节):上层只拿这个值类型句柄,回传给端口做读流 / 探活 / 终止。
/// `Sendable & Hashable`:可安全跨线程传递、可作字典键(真实现内部据它映射到真进程)。样板 = `AAPluginSDK.ProcessHandle`。
public struct AgentProcessHandle: Sendable, Equatable, Hashable {
    /// 真实现分配的进程序号(与真实 pid 解耦,避免 pid 复用带来的歧义)。
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

/// 拉起 agent 进程时对其 stdin 的处置策略。**两家 agent 要求相反,故必须显式声明**(spike 实证):
/// - Claude stream-json:写一行 prompt 后**保持 stdin 打开**,由适配层后续显式关闭 / 收尾(进程不自退);
/// - Codex exec:stdin 立即 `/dev/null`,否则进程**静默挂起**(02 spike 实证)。
public enum AgentStdinDisposition: Sendable, Equatable {
    /// 写入给定字符串(一行 prompt)后保持 stdin 打开——由适配层显式管理其关闭时机(Claude stream-json)。
    case writeThenKeepOpen(String)
    /// stdin 立即接 `/dev/null`(Codex exec:否则静默挂起)。
    case devNull
}

/// 一次 agent 进程执行的启动规格(纯值类型,可被状态机构造并断言,不含任何副作用)。
public struct AgentLaunchSpec: Sendable, Equatable {
    /// 可执行绝对路径(如 `claude` / `codex` 的绝对路径)。
    public let executablePath: String
    /// 命令行参数(不含 argv[0])。
    public let arguments: [String]
    /// 进程环境变量(如每任务独立的 `$CODEX_HOME`)。
    public let environment: [String: String]
    /// 工作目录(任务工作区内的 `work/` 或委托指定目录)。
    public let workingDirectory: String
    /// stdin 处置策略(见 `AgentStdinDisposition`)。
    public let stdin: AgentStdinDisposition

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        stdin: AgentStdinDisposition
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stdin = stdin
    }
}

/// 一次 agent 进程执行的端口(最小接口)。真实现(`SystemAgentPort`,归 agent-delegation 06 票)基于 Foundation `Process`;
/// 假件(`AAAgentTestKit.FakeAgentPort`)可编程回放事件脚本 / 编程失败 / 模拟中途死亡。
///
/// 语义契约(真实现必须满足,假件用于验证域逻辑不依赖真进程):
/// - `launch`:按启动规格拉起 agent 进程,返回句柄;拉起失败抛错。真实现须按 `spec.stdin` 处置 stdin。
/// - `nextEvent`:读下一条**原始事件行**(agent stdout 的逐行,未归一化);无更多 / 到达 EOF / 进程已死 → 返回 nil。
///   这是「行式事件流」的读取面:归一化纯函数消费这些原始行、产出 6 型 `AgentMessage`。
/// - `isAlive`:句柄对应进程是否仍存活;未知 / 已回收句柄返回 false(看门狗与终态判定基石)。
/// - `terminate`:终止并回收句柄对应进程(**幂等**:已死 / 未知句柄为 no-op)。
///
/// **反孤儿铁律(真实现的责任,归 agent-delegation 06 票 `SystemAgentPort` 落地)**:
///   取消 / 宿主退出走进程组 SIGTERM → 宽限期 → SIGKILL,连带杀掉 agent 派生的子进程树、不留孤儿
///   (样板 = 现有 `SystemProcessPort` 的 atexit / SIGTERM / SIGINT / SIGHUP 钩子兜底 SIGKILL 模型)。
///   该保证由真实现挂宿主退出钩子达成,不在协议里强制,但为 06 票 E2E 明确断言的属性。本骨架票不实现它。
public protocol AgentPort: Sendable {
    /// 拉起 agent 进程。拉起失败(可执行不存在 / fork 失败等)抛错。
    func launch(_ spec: AgentLaunchSpec) throws -> AgentProcessHandle
    /// 读下一条原始事件行;无更多 / EOF / 进程已死 → nil。
    func nextEvent(_ handle: AgentProcessHandle) -> String?
    /// 句柄对应进程是否存活。未知 / 已回收句柄返回 false。
    func isAlive(_ handle: AgentProcessHandle) -> Bool
    /// 终止并回收句柄对应进程(幂等;进程组终止,反孤儿由真实现兜底)。
    func terminate(_ handle: AgentProcessHandle)
}
