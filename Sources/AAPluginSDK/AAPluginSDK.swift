// AAPluginSDK —— 插件开发方(如 PluginProxy)面向平台契约的 SDK 层。
// 依赖边:AAPluginSDK → AAContracts(+ 系统 Foundation)。
//
// 06 票:这里新增两个「宿主 Port」协议(ProcessPort / HTTPPort)。
//   铁律落点:插件(PluginProxy)只依赖 SDK,绝不依赖任何 Host*。特权面(子进程生命周期、真 HTTP I/O)
//   的**协议**定义在 SDK,**真实现**在 AAHostMacOS,**假件**在 AAHostTestKit。插件只面向这些协议编程,
//   由宿主在装配期注入具体实现——从而 PluginProxy 既能跑真副作用(经宿主),又能在注入假件下纯逻辑单测。
//   两个协议都 `: Sendable`(延续 Registry「不可变存储 → 天然 Sendable」的并发约定):其存在化类型
//   `any ProcessPort` / `any HTTPPort` 因而是 Sendable,可被 Sendable 的插件/客户端安全持有并跨线程调用。

import Foundation
import AAContracts

/// V1 骨架占位。此处 `import AAContracts` 并触达 `RiskLevel`,用于在编译期证明依赖边真的连通。
public enum PluginSDK {
    /// 插件能力默认档位示例(占位):证明可以引用 AAContracts.RiskLevel。
    public static let defaultRisk: RiskLevel = .safe
}

// ============ ProcessPort —— 子进程生命周期(特权面归宿主)============

/// 一个被拉起的子进程的不透明句柄。
///
/// 不暴露真实 pid / Process 对象(那是宿主实现细节):插件只拿这个值类型句柄,回传给 Port 做探活/回收。
/// `Sendable & Hashable`:可安全跨线程传递、可作字典键(宿主实现内部据它映射到真 Process)。
public struct ProcessHandle: Sendable, Equatable, Hashable {
    /// 宿主实现分配的进程序号(与真实 pid 解耦,避免 pid 复用带来的歧义)。
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

/// 子进程生命周期 Port(最小接口)。真实现(AAHostMacOS)基于 Foundation `Process`;假件(AAHostTestKit)可编程存活/记录调用。
///
/// 语义契约(真实现必须满足,假件用于验证插件逻辑不依赖真进程):
/// - `launch`:按可执行路径 + 参数拉起子进程,返回句柄;拉起失败抛错。
/// - `isAlive`:句柄对应进程是否仍存活(健康检查基石:内核死亡必须可检测)。
/// - `terminate`:终止并回收句柄对应进程(幂等:已死/未知句柄为 no-op)。
/// - **反孤儿铁律(真实现的责任)**:宿主进程无论以何种方式退出(正常 exit / SIGTERM / SIGINT),
///   都必须回收所有经本 Port 拉起且尚存活的子进程——零孤儿。该保证由真实现挂宿主退出钩子达成,不在协议里强制,
///   但是 06 票 E2E 明确断言的属性。
public protocol ProcessPort: Sendable {
    /// 拉起子进程。`executablePath` 为可执行(或带 shebang 的脚本)绝对路径;`arguments` 不含 argv[0]。
    func launch(executablePath: String, arguments: [String]) throws -> ProcessHandle
    /// 句柄对应进程是否存活。未知/已回收句柄返回 false。
    func isAlive(_ handle: ProcessHandle) -> Bool
    /// 终止并回收句柄对应进程(幂等)。
    func terminate(_ handle: ProcessHandle)
    /// 取句柄对应进程的**原始 pid**(未知/已回收句柄返回 nil)。
    ///
    /// 08 票用途:接管系统代理时要把内核 pid **持久化**进接管态清单,以便下次启动跨世代识别/回收上一世代残留内核。
    /// `ProcessHandle` 是进程内不透明句柄(跨世代无效),故这里显式暴露原始 pid 供持久化——**仅供持久化/跨世代回收**,
    /// 同世代内的探活/回收仍应走不透明句柄(维持 pid 解耦)。
    func processID(_ handle: ProcessHandle) -> Int32?
}

// ============ ProcessReaper —— 跨世代孤儿回收(按原始 pid 探活 / 强杀)============

/// 跨世代孤儿回收 Port:按**原始 pid**探活并强杀上一世代残留的子进程(内核)。
///
/// 08 票用途(还 06 记债):宿主被 `kill -9`(SIGKILL)强杀时,ProcessPort 真实现的 atexit/信号退出钩子**都不触发**,
///   经它拉起的内核会被 launchd 收养成孤儿并继续持有端口。下次启动时,自愈据持久化的旧 pid 探活;若仍存活即 SIGKILL
///   兜底回收,释放端口以便干净重启。此处刻意与 ProcessPort 分离:ProcessPort 管「本世代我拉起的句柄」,
///   ProcessReaper 管「跨世代的原始 pid」——两个关注点,两个 Port。
///
/// **pid 复用安全(修盲杀 bug)**:pid 跨重启/重开机存活于持久化文件,其号极可能已被无关进程复用。故 reap 前**必须身份核验**——
///   用 `executablePath(pid:)` 读回该 pid 当前可执行路径,与持久化的内核路径逐字节比对,**相等才 SIGKILL**;
///   无法确认(路径不符 / 读不到 / 非本用户进程)一律**不杀**(网络仍可经 restore/repoint 自愈,不冒杀错风险)。
///   身份**比对逻辑**是域纯逻辑(见 `CrashRecovery.isOurKernel`,注入假件可测);`executablePath` 的真实读取才在本 Port 之后。
public protocol ProcessReaper: Sendable {
    /// 某原始 pid 的**可执行映像绝对路径**;pid 不存活 / 无权读取(EPERM,非本用户进程)/ 无法确定 → nil。
    /// 08:跨世代 reap 前据此核验身份(与持久化的内核路径比对),杜绝 pid 复用后误杀无辜进程。
    func executablePath(pid: Int32) -> String?
    /// 某原始 pid 是否存活(kill(pid,0) == 0)。pid <= 0 视为不存活;EPERM(非本用户进程)亦视为**不存活**(不是我方内核,不该当作可回收对象)。
    func isProcessAlive(pid: Int32) -> Bool
    /// 强杀某原始 pid(SIGKILL)。**调用方必须已核验身份**(本方法不做核验)。幂等,进程不存在即 no-op;pid <= 0 为 no-op。
    func reap(pid: Int32)
}

/// 无操作 ProcessReaper(缺省注入):路径永远 nil、永远报「不存活」、reap 为 no-op。
/// 用于「无跨世代回收通道」的场景(如纯逻辑单测不关心 reap 时);生产由宿主注入真实现。
public struct NoopProcessReaper: ProcessReaper {
    public init() {}
    public func executablePath(pid: Int32) -> String? { nil }
    public func isProcessAlive(pid: Int32) -> Bool { false }
    public func reap(pid: Int32) {}
}

// ============ HTTPPort —— 单发 HTTP 请求(REST 客户端压其后,便于注入假件)============

/// 一次 HTTP 响应:状态码 + 原始响应体(交由上层按需解 JSON)。
public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// HTTP 方法是封闭、可传输的领域值；调用方不能传任意字符串。
public enum HTTPMethod: String, Sendable, Equatable, Codable {
    case get = "GET"
    case put = "PUT"
    case patch = "PATCH"
    case post = "POST"
}

/// 单发 HTTP 请求 Port。真实现(AAHostMacOS)对 `127.0.0.1:<port>` 发同步 HTTP;假件(AAHostTestKit)按 URL 返回预置 JSON。
///
/// V1 仅需 localhost(mihomo REST external-controller);把「真 I/O」压到这个 Port 之后,
/// 让插件里的 URL 构建 / JSON 解析(域逻辑)可在注入假件下纯逻辑单测。
public protocol HTTPPort: Sendable {
    /// 发一个请求:`method`(见 `HTTPMethod`)、完整 `url`(如 `http://127.0.0.1:9090/version`)、可选 `body`。
    /// 返回状态码 + 响应体;传输失败(连不上 / 超时 / 响应不可解析)抛错。
    func send(method: HTTPMethod, url: String, body: Data?) throws -> HTTPResponse
}

// ============ PluginCapability —— 插件把能力交给宿主注册的载体 ============

/// 插件能力处理器(纯闭包)。形状与 AAHostRuntime.CapabilityHandler **完全一致**
/// (`@Sendable (JSONValue?) -> Result<JSONValue, WireError>`,二者皆为该函数类型的透明别名)——
/// 故宿主可零成本把 PluginCapability 适配成 Registry 的 Capability,而插件无需 import 任何 Host*。
public typealias PluginCapabilityHandler = @Sendable (JSONValue?) -> Result<JSONValue, WireError>

/// 插件对外暴露的一条能力 = 描述符 + 处理器。
///
/// 插件(PluginProxy)只依赖 SDK/Contracts,产出 `[PluginCapability]`;宿主(AAHostMacOS,同时 import SDK 与 Runtime)
/// 把每条映射为 `AAHostRuntime.Capability(descriptor:handler:)` 注册进 Registry。这条适配边让「插件产能力」与
/// 「宿主的注册表类型」解耦,维持 PluginProxy 不依赖 Host* 的铁律。
public struct PluginCapability: Sendable {
    public let descriptor: CapabilityDescriptor
    public let handler: PluginCapabilityHandler
    public init(descriptor: CapabilityDescriptor, handler: @escaping PluginCapabilityHandler) {
        self.descriptor = descriptor
        self.handler = handler
    }
}
