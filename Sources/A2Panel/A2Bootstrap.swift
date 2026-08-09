// A2Panel —— **引导执行器**(16 票 / [ADR 0012](../../docs/adr/0012-panel-self-sufficient-bootstrap.md))。
//
// ============================================================================
// 这一层是什么(以及它**不是**什么)
// ============================================================================
// 是:面板经 `.app` 里那份内嵌内核 bin 发起**四条白名单命令**、解析机读 JSON、把结果交出去。
// 不是:第二条通往内核的路。壳与内核说话的正路仍是 UDS 长连接(`A2PanelSession`);
//       本层只在**内核还没装/没跑**或**要换版本**的那几个时刻用得上,一共四条命令,一条不多。
//
// **白名单是硬的**(ADR 0012 第 3 条):`A2BootstrapCommand` 是全仓唯一构造 argv 的地方,
//   没有 `run(arbitrary:)` 之类的口子。想多发一条命令就得改这个枚举 —— 那会当场撞上
//   `A2BootstrapTests` 里那条逐字对照的断言,以及 ADR 0012 本身。
//
// **薄壳铁律不破**(ADR 0008 第 5 条):这里没有任何业务逻辑 ——
//   装什么、怎么装、幂等不幂等、要不要重启,全在内核的 `service install` 里;
//   壳只负责「发起 → 解析 → 呈现」,连"装完该不该起"这种判断都不做。
//
// ============================================================================
// 为什么 result 不建 typed 镜像(15 票豁免的延续,本票复核后**维持**)
// ============================================================================
// `ServiceStatusResult` / `ServiceChangeResult` 有意豁免于 Swift 契约镜像
// (理由原文见 `A2ContractMirror.swift` 的豁免表)。面板只读其中**四个字段**:
//   `state`、`binPath`、`status.state`、`actions`。
// 包封本身(`A2ResponseEnvelope` / `A2WireError`)是**已镜像**的契约,双端金标钉着;
// 剩下那四个字段经 `A2JSON` 取值,并由本目录的解析用例**直接喂 `kernel/contract/golden/` 的真样本**
// —— 契约漂了,解析用例当场红。这比多两个会独立漂移的 typed 类型更省、也更硬。
//
// 依赖边:A2Panel → A2Contract + Foundation。**零 AppKit**(定位嵌入 bin 用的是 Foundation 的 Bundle)。

import Foundation
import A2Contract

// ============================================================================
// ① 白名单:四条,一条不多
// ============================================================================

/// 面板经内嵌 bin 可以执行的**全部**命令(ADR 0012 第 3 条)。
///
/// 每一条都带 `--json`:壳只看机读面,人类面的散文一个字都不解析
/// (散文会为了好读而改,机读包封改一次就要动契约与金标)。
public enum A2BootstrapCommand: String, Sendable, Equatable, CaseIterable {
    /// 装 / 收敛常驻服务,并把本 bin 拷进 `$A2_HOME/bin/a2`(unit 指向拷贝,不指进 `.app`)。
    /// **幂等**:已经是目标状态时它什么都不改,所以"安装"与"启动"用的是同一条命令。
    case serviceInstall
    /// 停服并拆 unit。**只拆 unit** —— `~/.a2` 与那份拷贝留下(ADR 0012 第 6 条)。
    case serviceUninstall
    /// 问服务态(不经 daemon —— daemon 没跑时恰恰最需要它答话)。
    case serviceStatus
    /// 问内嵌 bin 自己的版本(启动时问一次并缓存,不轮询 —— ADR 0012 第 5 条)。
    case version

    /// 传给内嵌 bin 的 argv。**全仓唯一构造引导 argv 的地方**。
    public var arguments: [String] {
        switch self {
        case .serviceInstall:   return ["service", "install", "--copy-to-home", "--json"]
        case .serviceUninstall: return ["service", "uninstall", "--json"]
        case .serviceStatus:    return ["service", "status", "--json"]
        case .version:          return ["version", "--json"]
        }
    }

    /// 给人看的命令行(菜单角标与快照用)。去掉 `--json` —— 那是机读面的事,不是"这一项会干什么"的一部分。
    public var displayCommand: String {
        "a2 " + arguments.filter { $0 != "--json" }.joined(separator: " ")
    }
}

// ============================================================================
// ② 可注入的执行缝(单测不起任何子进程的唯一前提)
// ============================================================================

/// 一次执行的原始结果。**不解释、不判断**,只是把子进程说的话原样带回来。
public struct A2BootstrapRun: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// 「跑一条白名单命令 → 拿到 stdout / stderr / 退出码」。
///
/// 存在的**唯一理由**是可测性:真实现要起子进程,而门禁里**绝不许**真装服务、真碰 launchctl。
/// 单元测试注入一个吐夹具 JSON 的假 runner,于是"解析对不对""在途守卫灵不灵""失败怎么呈现"
/// 三件事都成了纯逻辑断言。真起进程那一关归 `.app` 出包的 APP11 冒烟(只读的 `service status`)。
public protocol A2BootstrapRunner: AnyObject {
    func run(_ command: A2BootstrapCommand) -> A2BootstrapRun
}

/// 真实现:起子进程跑内嵌 bin。
///
/// **不设超时**,理由如实写在这里:白名单四条命令都是 a2 的 CLI 面,而 a2 **永不交互阻塞**
/// (ADR 0005)—— 它不会挂在那里等谁。真挂住了那是内核缺陷,而半路 kill 掉一次在途的
/// `service install` 会留下一个装了一半的服务,比让菜单显示「安装中…」更糟。
public final class A2BootstrapProcessRunner: A2BootstrapRunner {

    /// 内嵌 bin 的绝对路径(`Bundle.main.resourceURL/a2`,见 `A2EmbeddedKernel`)。
    public let binary: URL

    public init(binary: URL) { self.binary = binary }

    public func run(_ command: A2BootstrapCommand) -> A2BootstrapRun {
        let process = Process()
        process.executableURL = binary
        process.arguments = command.arguments
        // 环境**原样继承**:`A2_HOME` 之类的覆写归用户的环境说了算,壳不替他改一个字。
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            // 连起都起不来(文件被删了、执行位没了、被 Gatekeeper 拦了)——如实报,不假装跑过。
            return A2BootstrapRun(exitCode: -1, standardOutput: "",
                                  standardError: "内嵌内核 bin 起不来:\(error)")
        }
        // 先读干净再等退出:反过来在输出超过管道缓冲时会死锁(这里只有一行 JSON,但顺序不该赌)。
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return A2BootstrapRun(
            exitCode: process.terminationStatus,
            standardOutput: String(data: outData, encoding: .utf8) ?? "",
            standardError: String(data: errData, encoding: .utf8) ?? "")
    }
}

// ============================================================================
// ③ 面板从机读面里**只取的那几个字段**
// ============================================================================

/// `service status --json` 里面板要的两个字段。
///
/// ⚠️ 这**不是** `ServiceStatusResult` 的镜像 —— 那条契约有意豁免(见文件头)。
///   这里只承载"面板真的会用"的部分:装没装(决定菜单出哪一项)、unit 指着谁(决定托管的是不是我这份)。
public struct A2BootstrapServiceFacts: Sendable, Equatable {

    /// 服务的三态(与 `ServiceStatusResult.state` 的封闭词表逐字一致)。
    /// 未知取值**不猜**,一律当解析失败 —— 内核加了第四态而壳没跟,那是要红的事。
    public enum State: String, Sendable, Equatable, CaseIterable {
        case notInstalled = "not_installed"
        case installedNotRunning = "installed_not_running"
        case running
    }

    public let state: State
    /// unit 实际指向的可执行(15 票:读盘上那份 unit 的事实值)。
    public let binPath: String

    public init(state: State, binPath: String) {
        self.state = state
        self.binPath = binPath
    }
}

/// `service install|uninstall --json` 里面板要的部分。
public struct A2BootstrapChangeFacts: Sendable, Equatable {
    /// 这次动作之后的服务态。
    public let status: A2BootstrapServiceFacts
    /// 本次真的做了哪些事(`bin_copied` / `unit_written` / `kernel_restarted` …)。
    /// **空数组是合法且常见的**:幂等复跑什么都不改。壳原样呈现,不替它编一句"已完成"。
    public let actions: [String]

    public init(status: A2BootstrapServiceFacts, actions: [String]) {
        self.status = status
        self.actions = actions
    }
}

/// 一次引导操作的失败。**如实**:内核说什么就带什么,壳只补一句退出码的粗分类。
public struct A2BootstrapFailure: Sendable, Equatable, Error {
    /// 结构化错误码(有包封时);包封本身都解不出来时为 nil。
    public let code: String?
    /// 人读原因。
    public let message: String
    /// 子进程退出码。
    public let exitCode: Int32

    public init(code: String?, message: String, exitCode: Int32) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
    }

    /// 退出码的粗分类(与 `kernel/src/contract/exit-codes.ts` 同一张表)。
    /// 壳**只解释、不定义**:这里多一个数就是壳在自说自话。
    public static func exitCodeMeaning(_ exitCode: Int32) -> String {
        switch exitCode {
        case 0:  return "成功"
        case 1:  return "用法错"
        case 2:  return "被拒"
        case 3:  return "超时"
        case 4:  return "daemon 不可达"
        case 5:  return "路走通了、事没办成"
        case 6:  return "协议·校验错"
        default: return "未预期的退出码"
        }
    }

    /// 对面板特别有意义的那几个 `error.code` 的一句白话。
    /// 表里没有的**不编**:回落到退出码的粗分类(内核给的 message 本来就写给人看)。
    static func codeMeaning(_ code: String?) -> String? {
        switch code {
        case "service_self_copy_unsupported":
            return "这个 bin 不能自装:开发态产物没有可分发的「自身」可拷"
        case "service_unsupported_platform":
            return "这台机器上没有已支持的 supervisor"
        case "service_operation_failed":
            return "supervisor 报错,或装完没跑起来"
        default:
            return nil
        }
    }

    /// 菜单里那一行(如实:内核的原话 + 机读坐标 + 退出码 + 一句人话)。
    public var displayLine: String {
        var coordinates: [String] = []
        if let code { coordinates.append(code) }
        coordinates.append("退出码 \(exitCode)")
        let note = Self.codeMeaning(code) ?? Self.exitCodeMeaning(exitCode)
        return "\(message)(\(coordinates.joined(separator: " · ")) —— \(note))"
    }
}

// ============================================================================
// ④ 解析:stdout 上只有一条 JSON 包封
// ============================================================================

/// 把白名单命令的输出解析成面板要的事实。**纯函数**,喂什么字符串给什么结果。
public enum A2BootstrapReading {

    /// stdout → 响应包封。
    ///
    /// `--json` 时 a2 的 stdout 上**只有一条 JSON 包封**(成功失败同形状,见 `docs/agents/a2-cli.md`),
    /// 所以这里不做多行扫描 —— 真出现第二行,那是机读面破了,该红。
    static func envelope(_ run: A2BootstrapRun) -> Result<A2ResponseEnvelope, A2BootstrapFailure> {
        let text = run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .failure(A2BootstrapFailure(
                code: nil,
                message: "内嵌内核 bin 没有机读输出" + (run.standardError.isEmpty ? "" : ":\(oneLine(run.standardError))"),
                exitCode: run.exitCode))
        }
        do {
            return .success(try JSONDecoder().decode(A2ResponseEnvelope.self, from: Data(text.utf8)))
        } catch {
            return .failure(A2BootstrapFailure(
                code: nil,
                message: "内嵌内核 bin 的机读输出解析失败(\(error))",
                exitCode: run.exitCode))
        }
    }

    /// 成功包封 → result 对象;失败包封 → 如实转成 `A2BootstrapFailure`。
    static func result(_ run: A2BootstrapRun) -> Result<[String: A2JSON], A2BootstrapFailure> {
        switch envelope(run) {
        case let .failure(failure):
            return .failure(failure)
        case let .success(envelope):
            if let error = envelope.error {
                return .failure(A2BootstrapFailure(code: error.code, message: error.message,
                                                   exitCode: run.exitCode))
            }
            guard let object = envelope.result?.objectValue else {
                return .failure(A2BootstrapFailure(code: nil, message: "机读结果不是对象",
                                                   exitCode: run.exitCode))
            }
            return .success(object)
        }
    }

    /// `service status --json` → 服务事实。
    public static func serviceStatus(_ run: A2BootstrapRun)
        -> Result<A2BootstrapServiceFacts, A2BootstrapFailure> {
        result(run).flatMap { facts(from: $0, exitCode: run.exitCode) }
    }

    /// `service install|uninstall --json` → 变更事实。
    public static func serviceChange(_ run: A2BootstrapRun)
        -> Result<A2BootstrapChangeFacts, A2BootstrapFailure> {
        result(run).flatMap { object in
            guard let statusObject = object["status"]?.objectValue else {
                return .failure(missing("status", run.exitCode))
            }
            guard case let .array(rawActions)? = object["actions"] else {
                return .failure(missing("actions", run.exitCode))
            }
            let actions = rawActions.compactMap { $0.stringValue }
            guard actions.count == rawActions.count else {
                return .failure(A2BootstrapFailure(code: nil, message: "actions 里有非字符串项",
                                                   exitCode: run.exitCode))
            }
            return facts(from: statusObject, exitCode: run.exitCode).map {
                A2BootstrapChangeFacts(status: $0, actions: actions)
            }
        }
    }

    /// `version --json` → 版本号。
    public static func version(_ run: A2BootstrapRun) -> Result<String, A2BootstrapFailure> {
        result(run).flatMap { object in
            guard let version = object["version"]?.stringValue, !version.isEmpty else {
                return .failure(missing("version", run.exitCode))
            }
            return .success(version)
        }
    }

    // ---- 私有 ----

    private static func facts(from object: [String: A2JSON], exitCode: Int32)
        -> Result<A2BootstrapServiceFacts, A2BootstrapFailure> {
        guard let raw = object["state"]?.stringValue else { return .failure(missing("state", exitCode)) }
        // 未知取值**不猜**(fail-closed):内核加了第四态而壳没跟,宁可报错也不当成"未安装"去装一遍。
        guard let state = A2BootstrapServiceFacts.State(rawValue: raw) else {
            return .failure(A2BootstrapFailure(code: nil, message: "未知的服务态:\(raw)", exitCode: exitCode))
        }
        guard let binPath = object["binPath"]?.stringValue, !binPath.isEmpty else {
            return .failure(missing("binPath", exitCode))
        }
        return .success(A2BootstrapServiceFacts(state: state, binPath: binPath))
    }

    private static func missing(_ field: String, _ exitCode: Int32) -> A2BootstrapFailure {
        A2BootstrapFailure(code: nil, message: "机读结果缺 \(field)", exitCode: exitCode)
    }

    private static func oneLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""
    }
}

// ============================================================================
// ⑤ 定位内嵌 bin
// ============================================================================

/// `.app` 里那份内核 bin 的落点。
public enum A2EmbeddedKernel {

    /// 资源名。**与 `Scripts/build-app.sh` 的 `KERNEL_EXE_NAME` 是同一个名字** ——
    /// 改一处就要改两处,所以两边各自只有这一处(打包脚本头注也这么写)。
    public static let resourceName = "a2"

    /// 找内嵌 bin。找不到 → `nil`,**引导功能整体隐藏**。
    ///
    /// 找不到是**常态而非异常**:`swift build` 出来的裸可执行、`swift test` 的测试宿主都没有 bundle 资源。
    /// 那时菜单保持 10 票的原样(「内核:未连接(…)— 代理不受影响」那一行不动),
    /// 不出现任何"点了会失败"的引导入口 —— 与「能力缺席即不出现」是同一条姿势。
    public static func locate(resourceURL: URL? = Bundle.main.resourceURL,
                              fileManager: FileManager = .default) -> URL? {
        guard let resourceURL else { return nil }
        let candidate = resourceURL.appendingPathComponent(resourceName)
        // 既要在、也要**可执行**:少了执行位的那份跑不起来,当场当"没有"处理更诚实。
        guard fileManager.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }
}
