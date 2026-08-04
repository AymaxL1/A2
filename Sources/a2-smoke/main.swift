// a2-smoke —— Swift 客户端对**真 a2 内核**的活体烟测驱动(09 票;门禁内部工具,不是交付物)。
//
// 它证明的一句话:**Swift 侧的手写镜像 + UDS 客户端,对着真内核跑得通一条完整的确认链**。
//   连接 → 注册 confirm-agent(同一次往返拿全量快照)→ 触发一条真 dangerous 调用 →
//   收 `confirmation` 推送(带 input)→ 回 `confirmations.resolve{approve}` → 发起方拿到成功。
//
// 为什么不进 `swift test`:那会让 `check.sh` 跑门禁时起一个真 a2 daemon。09 票是 expand 半步,
//   门禁行为一行不改。驱动脚本 `Scripts/a2-smoke-09.sh` 在 `Scripts/check/` **之外**,门禁不引用它。
//
// 红线:一切在临时 A2_HOME 里发生(由驱动脚本建、由驱动脚本清);本程序**不起 daemon、不杀 daemon、
//   不碰 launchctl、不碰用户的 mihomo** —— 进程生命周期全归脚本,它有 trap 兜底。

import Foundation
import A2Contract
import A2KernelClient

// MARK: - 参数

struct Options {
    var socketPath: String = ""
    var capability: String = "demo.wipe"
    var decision: A2ConfirmationDecision = .approve
    var timeout: TimeInterval = 20
    /// a2 CLI 的调用前缀(`--` 之后的全部 argv):`dist/a2` 或 `bun run src/cli/main.ts`。
    var cliCommand: [String] = []
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("SMOKE_FAIL: \(message)\n".utf8))
    exit(1)
}

func report(_ message: String) {
    print("SMOKE: \(message)")
    fflush(stdout)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--socket":
            guard let value = arguments.first else { fail("--socket 缺值") }
            arguments.removeFirst()
            options.socketPath = value
        case "--capability":
            guard let value = arguments.first else { fail("--capability 缺值") }
            arguments.removeFirst()
            options.capability = value
        case "--decision":
            guard let value = arguments.first,
                  let decision = A2ConfirmationDecision(rawValue: value) else {
                fail("--decision 只能是 approve / deny")
            }
            arguments.removeFirst()
            options.decision = decision
        case "--timeout":
            guard let value = arguments.first, let seconds = Double(value) else { fail("--timeout 缺值") }
            arguments.removeFirst()
            options.timeout = seconds
        case "--":
            options.cliCommand = arguments
            arguments.removeAll()
        default:
            fail("未知参数:\(argument)")
        }
    }
    if options.socketPath.isEmpty { fail("必须给 --socket <path>") }
    if options.cliCommand.isEmpty { fail("必须在 `--` 之后给出 a2 CLI 的调用前缀") }
    return options
}

// MARK: - 主流程

let options = parseOptions()

let client: A2KernelClient
do {
    client = try A2KernelClient.connect(
        socketPath: options.socketPath,
        configuration: A2KernelClient.Configuration(requestTimeout: options.timeout))
} catch {
    fail("连不上内核:\(error)")
}

// ① 注册即快照(同一次往返)。
let registration: A2RoleRegisterResult
do {
    registration = try client.registerRole(
        .confirmAgent,
        identity: A2ClientIdentity(name: "a2-smoke", version: "09"))
} catch {
    fail("注册 confirm-agent 失败:\(error)")
}

report("registered role=\(registration.role.rawValue) connection=\(registration.connection) "
    + "uid=\(registration.uid.map(String.init) ?? "(取不到凭据)")")
report("snapshot status=\(registration.snapshot.status.state) version=\(registration.snapshot.status.version) "
    + "capabilities=\(registration.snapshot.capabilities.count) "
    + "confirmerPresent=\(registration.snapshot.arbitration.confirmerPresent) "
    + "watching=\(registration.snapshot.supervision.watching) "
    + "auditEvents=\(registration.snapshot.audit.count)")

guard registration.snapshot.arbitration.confirmerPresent else {
    fail("注册成功了,快照里却说没有确认器在场 —— 「在场 = 长连接」这条语义破了")
}
guard registration.snapshot.capabilities.contains(where: { $0.id == options.capability }) else {
    fail("快照里没有能力 \(options.capability),烟测无从触发")
}

// 注册往返之后,这条连接上**不该**有任何积压的推送(它不会收到自己入场触发的事件)。
if !client.bufferedPushes.isEmpty {
    let kinds = client.bufferedPushes.map { $0.event.kind.rawValue }.joined(separator: ",")
    fail("注册往返里混进了推送帧(\(kinds))—— 「快照响应先行」这条语义破了")
}

// ② 起一条真 dangerous 调用(另一个进程,走 CLI 面 —— 与壳完全不同的一条连接)。
let cli = Process()
cli.executableURL = URL(fileURLWithPath: options.cliCommand[0])
cli.arguments = Array(options.cliCommand.dropFirst()) + ["capabilities", "call", options.capability, "--json"]
let stdoutPipe = Pipe()
let stderrPipe = Pipe()
cli.standardOutput = stdoutPipe
cli.standardError = stderrPipe
do {
    try cli.run()
} catch {
    fail("起不了 a2 CLI(\(options.cliCommand.joined(separator: " ")))\(error)")
}
report("triggered \(options.capability)(pid=\(cli.processIdentifier))")

// ③ 等确认请求推过来 —— 带 descriptor 与**真实入参**。
let push: A2PushEnvelope
do {
    push = try client.nextPush(timeout: options.timeout) { push in
        if case .confirmation = push.event { return true }
        return false
    }
} catch {
    cli.terminate()
    fail("没等到 confirmation 推送:\(error)")
}
guard case let .confirmation(_, confirmationRequest) = push.event else {
    fail("推送帧的事件族不是 confirmation")
}
guard confirmationRequest.capability == options.capability else {
    fail("确认请求指向的能力对不上:期待 \(options.capability),实际 \(confirmationRequest.capability)")
}
guard confirmationRequest.descriptor.risk == .dangerous else {
    fail("进仲裁的却不是 dangerous 档:\(confirmationRequest.descriptor.risk.rawValue)")
}
report("confirmation id=\(confirmationRequest.id) capability=\(confirmationRequest.capability) "
    + "risk=\(confirmationRequest.descriptor.risk.rawValue) inputKeys=[\(confirmationRequest.input.keys.sorted().joined(separator: ","))] "
    + "expiresAt=\(confirmationRequest.expiresAt)")

// ④ 替人类回一条决定。
let resolved: A2ConfirmationResolveResult
do {
    resolved = try client.resolveConfirmation(
        confirmationRequest.id, decision: options.decision, reason: "09 票活体烟测")
} catch {
    cli.terminate()
    fail("回决定失败:\(error)")
}
guard resolved.confirmation == confirmationRequest.id, resolved.settled else {
    fail("决定没被采纳:\(resolved)")
}
report("resolved decision=\(resolved.decision.rawValue) settled=\(resolved.settled)")

// ⑤ 发起方的收场。
let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
cli.waitUntilExit()
let cliStdout = String(decoding: stdoutData, as: UTF8.self)
let cliStderr = String(decoding: stderrData, as: UTF8.self)
report("cli exit=\(cli.terminationStatus)")

let expectedExit: Int32 = options.decision == .approve ? 0 : 2
guard cli.terminationStatus == expectedExit else {
    fail("发起方退出码对不上:期待 \(expectedExit),实际 \(cli.terminationStatus)\n"
        + "--- stdout ---\n\(cliStdout)\n--- stderr ---\n\(cliStderr)")
}

// **确认信息永不过 agent 之手**:发起方那条通路上不该出现确认器的名字,也不该出现那条确认请求的 id。
if cliStdout.contains(confirmationRequest.id) || cliStdout.contains("a2-smoke") {
    fail("发起方的 stdout 里出现了确认器名字或确认 id —— 确认信息泄漏到了 agent 通路上:\n\(cliStdout)")
}

guard let envelope = try? JSONDecoder().decode(A2ResponseEnvelope.self, from: stdoutData) else {
    fail("发起方的 stdout 不是一条本协议的响应包封:\n\(cliStdout)")
}
switch (options.decision, envelope) {
case (.approve, .success):
    report("initiator got ok=true(批准后放行)")
case let (.deny, .failure(failure)):
    guard failure.error.code == A2ErrorCode.confirmationDenied else {
        fail("拒绝档的错误码对不上:\(failure.error.code)")
    }
    guard failure.error.guidance != nil else { fail("仲裁三码必带 guidance,这条没有") }
    report("initiator got \(failure.error.code)(拒绝即指引)")
default:
    fail("决定与收场不匹配:decision=\(options.decision.rawValue) envelope=\(envelope)")
}

report("ALL_OK")
exit(0)
