// a2-panel-probe —— 壳的**无头替身**(门禁内部工具,Package.swift 里刻意不给 product)。
//
// ============================================================================
// 它是什么、不是什么
// ============================================================================
// 它把 `a2-panel` 里**除 AppKit 之外的全部东西**(会话 → 投影 → 菜单模型)接到一个真内核上,
// 把结果打成机读行,供 `Scripts/a2-flagship-e2e.sh` 断言。旗舰 e2e 因此验的是**壳真的那条代码路径**,
// 不是一个为测试另写的简化版。
//
// **它不是 a2-panel 的一部分**,这一点必须说死:
//   * `--decision approve|deny` 是**人的替身**,而人的替身只能住在测试工具里。
//     内核里没有任何测试专用的确认旁路(08 票的裁定),壳里也不该有 —— 旧仓的
//     `AA_CONFIRM_AUTO` 是宿主里一个 `#if AA_TESTING` 的编译期开关,那条路本票不重走。
//   * 它是**另一个客户端进程**,走的是与任何第三方客户端完全相同的公开协议
//     (与 `kernel/test/support/fake-client.ts` 同一种安排)。
//   * 它不进 `products`,不进 `.app`,分发物里没有它。
//
// ============================================================================
// 机读输出(e2e 逐行断言;格式改了要同步改脚本)
// ============================================================================
//   PANEL_READY: connection=<n> uid=<n|unknown> caps=<n> confirmerPresent=<0|1>
//   PANEL_MANIFEST: ok=<0|1> checked=<n> drift=<...>
//   PANEL_COVERAGE: ok=<0|1> actions=<n>/6 boundItems=<n> actionableCaps=<n> missing=<...> exempt=<...>
//   PANEL_MENU: mode=<..> node=<..> active=<..> systemProxy=<on|off> running=<0|1> groups=<n> subs=<n>
//   PANEL_EVENT: kind=<...>
//   PANEL_CONFIRM: id=<..> capability=<..> input=<k=v;k=v>
//   PANEL_DECIDED: id=<..> decision=<approve|deny>
//   PANEL_IDLE: before=<n> after=<n> seconds=<n>
//   PANEL_EXECUTE_LOCATE: bundleID=<..> found=<0|1>          (--executor 才有)
//   PANEL_EXECUTE_SET: app=<..> scheme=<http|https> reply=<ok>       (同上)
//   PANEL_SUMMARY: confirmations=<n> decided=<n> requests=<n> ok=<0|1>

import Foundation
import A2Contract
import A2Panel
import A2PanelFixtures

// ============================================================================
// 参数
// ============================================================================

struct Options {
    var socketPath = ""
    var role: A2ClientRole = .confirmAgent
    var decision: A2ConfirmationDecision?
    var duration: TimeInterval = 20
    var idleSeconds: TimeInterval = 0
    var expectConfirmations = 0
    var quitAfterDecisions = 0
    /// 给会话装上机械执行器(04 票)。**缺省不装** —— 那时这个壳连 `url-router-executor`
    /// 角色都不注册,内核那侧于是如实报"没有执行器在场",旗舰 e2e 的「执行器不在场」那一幕靠它。
    var executor = false
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        guard !arguments.isEmpty else { die("\(flag) 缺少取值") }
        return arguments.removeFirst()
    }
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        switch flag {
        case "--socket": options.socketPath = next(flag)
        case "--role":
            guard let role = A2ClientRole(rawValue: next(flag)) else { die("--role 只能是 confirm-agent | subscriber") }
            options.role = role
        case "--decision":
            let raw = next(flag)
            if raw == "none" { options.decision = nil }
            else if let decision = A2ConfirmationDecision(rawValue: raw) { options.decision = decision }
            else { die("--decision 只能是 approve | deny | none") }
        case "--duration": options.duration = Double(next(flag)) ?? 20
        case "--idle-probe": options.idleSeconds = Double(next(flag)) ?? 0
        case "--expect-confirmations": options.expectConfirmations = Int(next(flag)) ?? 0
        case "--quit-after-decisions": options.quitAfterDecisions = Int(next(flag)) ?? 0
        case "--executor": options.executor = true
        default: die("未知参数:\(flag)")
        }
    }
    if options.socketPath.isEmpty { die("--socket 必填") }
    return options
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("a2-panel-probe: \(message)\n".utf8))
    exit(2)
}

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

// ============================================================================
// 机械执行器的**系统那一侧**(04 票的 `A2DefaultHandlerSetting`)
// ============================================================================
// 真壳装的是 `A2WorkspaceDefaultHandlerSetter` —— 它一调就**真改这台机器的默认浏览器**,
// 并且真弹两个系统框。门禁里绝不能发生那件事,所以这里放一个剧本假件。
//
// 它与 `--decision approve|deny` 同源:那是**人**的替身,这是**操作系统**的替身,
// 两者都只能住在测试工具里(内核与壳里都没有任何测试专用旁路 —— 08 票的裁定)。
//
// **被测的那条链一个字都没换**:装配用的就是壳生产路径上那一句
// (`A2PanelSession(…, executor: A2URLRouterExecutorRunner(setter:log:))`,见 A2PanelAppDelegate),
// 举手的开关也是生产代码里那一个(`executor != nil` 才注册 `url-router-executor` 角色)。
// 于是旗舰 e2e 验到的是真壳的「收帧 → 逐 scheme 调 → 记账 → 回执」,只有最末那次系统调用是替身。
//
// 剧本只有一格:**解析得到目标、两个 scheme 的 completion 都无错**(= 用户在两个系统框上都点了
// 「使用」)。别的格(目标 app 不在 / NSError / 只成一半 / 一个字不回)在函数缝上已经验全 ——
// `Tests/A2PanelTests/A2URLRouterExecutorTests.swift`(壳侧)与 `kernel/test/cli-url-router.test.ts`
// (内核侧,假执行器),这里不重复它们,只补一条别处替不了的:**真进程 × 真 UDS 的整趟往返**。
final class ScriptedHandlerSetter: A2DefaultHandlerSetting {
    /// 解析出来的假位置。**不碰文件系统**:执行器只把它当不透明句柄递给系统 API,自己不看它一眼。
    private let applicationURL = URL(fileURLWithPath: "/nonexistent/a2-panel-probe/Target.app")

    func locateApplication(bundleID: String) -> URL? {
        say("PANEL_EXECUTE_LOCATE: bundleID=\(bundleID) found=1")
        return applicationURL
    }

    func setDefaultApplication(
        at applicationURL: URL, toOpenURLsWithScheme scheme: String,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        // 契约要求 completion **恰好一次**(真实现里它在用户点完系统框之后才回来)。
        say("PANEL_EXECUTE_SET: app=\(applicationURL.lastPathComponent) scheme=\(scheme) reply=ok")
        completion(nil)
    }
}

// ============================================================================
// 探针
// ============================================================================

final class Probe: A2PanelSessionDelegate {
    let options: Options
    private let lock = NSLock()
    private var confirmations = 0
    private var decided = 0
    private var manifestOK: Bool?
    private var coverageOK: Bool?
    private var lastMenuLine = ""
    var session: A2PanelSession?

    init(options: Options) { self.options = options }

    var counts: (confirmations: Int, decided: Int) {
        lock.lock(); defer { lock.unlock() }
        return (confirmations, decided)
    }

    var verdicts: (manifest: Bool?, coverage: Bool?) {
        lock.lock(); defer { lock.unlock() }
        return (manifestOK, coverageOK)
    }

    func panelSession(_ session: A2PanelSession, didUpdate state: A2PanelState) {
        lock.lock()
        let firstTime = (manifestOK == nil)
        lock.unlock()
        guard case .connected = state.connection else { return }
        if firstTime, !state.capabilities.isEmpty {
            let manifest = checkManifest(state.capabilities)
            let coverage = checkCoverage(state)
            lock.lock(); manifestOK = manifest; coverageOK = coverage; lock.unlock()
        }
        let line = menuLine(state)
        lock.lock()
        let changed = (line != lastMenuLine)
        lastMenuLine = line
        lock.unlock()
        if changed { say(line) }
    }

    func panelSession(_ session: A2PanelSession, present request: A2ConfirmationRequest) {
        lock.lock(); confirmations += 1; lock.unlock()
        // **原样呈现**:这里打的就是 `A2ConfirmationPresentation` 造出来的那几行 ——
        //   与真弹窗吃的是同一份呈现模型,e2e 因此验得到「入参真的到了人眼前」。
        let presentation = A2ConfirmationPresentation(request: request)
        say("PANEL_CONFIRM: id=\(request.id) capability=\(request.capability) "
            + "input=\(presentation.inputLines.joined(separator: ";"))")
        guard let decision = options.decision else {
            say("PANEL_CONFIRM_HELD: id=\(request.id)(--decision none:不替人做决定,等它超时)")
            return
        }
        session.resolve(confirmation: request.id, decision: decision, reason: "a2-panel-probe 自动决定")
        lock.lock(); decided += 1; lock.unlock()
        say("PANEL_DECIDED: id=\(request.id) decision=\(decision.rawValue)")
    }

    func panelSession(_ session: A2PanelSession, dismissConfirmations ids: [String]) {
        say("PANEL_DISMISS: ids=\(ids.joined(separator: ","))")
    }

    func panelSession(_ session: A2PanelSession, log line: String) {
        say("PANEL_LOG: \(line)")
    }

    // ---- 判据 ----

    /// 装置里那份手写能力清单 ↔ **真内核**的快照,逐条对照。
    ///
    /// 这是 `A2PanelFixtures` 头注承诺的那道防漂门:纯逻辑测试喂的是手写清单,
    /// 而手写清单会漂 —— 漂了就在这里当场红。
    ///
    /// 对照的是 `liveCapabilities`(手写全集减去当前停用的九条),不是 `capabilities` 全集 ——
    /// 全集是**渲染器的覆盖面**,里面有意保留着停用能力的描述符,好让那部分渲染逻辑继续被验。
    /// 两个方向都要判:装置里有而内核没有 = 该摘没摘;内核有而装置没有 = 该加没加(下面第二段)。
    private func checkManifest(_ live: [A2CapabilityDescriptor]) -> Bool {
        var byID: [String: A2CapabilityDescriptor] = [:]
        for capability in live { byID[capability.id] = capability }
        var drift: [String] = []
        for fixture in A2PanelFixtures.liveCapabilities {
            guard let real = byID[fixture.id] else {
                drift.append("\(fixture.id):真内核里没有这条")
                continue
            }
            if real.risk != fixture.risk {
                drift.append("\(fixture.id):risk 装置=\(fixture.risk.rawValue) 真=\(real.risk.rawValue)")
            }
            if real.cliAlias != fixture.cliAlias {
                drift.append("\(fixture.id):cliAlias 装置=\(fixture.cliAlias ?? []) 真=\(real.cliAlias ?? [])")
            }
            let fixtureRequired = Set(fixture.parameters.filter(\.required).map(\.name))
            let realRequired = Set(real.parameters.filter(\.required).map(\.name))
            if fixtureRequired != realRequired {
                drift.append("\(fixture.id):必填参数 装置=\(fixtureRequired.sorted()) 真=\(realRequired.sorted())")
            }
            let fixtureAllowed = fixture.parameters.compactMap { spec in
                spec.allowedValues.map { "\(spec.name)=\($0.joined(separator: "|"))" }
            }.sorted()
            let realAllowed = real.parameters.compactMap { spec in
                spec.allowedValues.map { "\(spec.name)=\($0.joined(separator: "|"))" }
            }.sorted()
            if fixtureAllowed != realAllowed {
                drift.append("\(fixture.id):allowedValues 装置=\(fixtureAllowed) 真=\(realAllowed)")
            }
        }
        // 反向:真内核注册了、而装置的 live 清单里没有 —— 要么是新能力没登记,要么是某条被"恢复"了
        // 却忘了从 `disabledCapabilityIDs` 里删掉。两种都必须当场红,否则停用名单会悄悄失真。
        let liveIDs = Set(live.map(\.id))
        let fixtureLiveIDs = Set(A2PanelFixtures.liveCapabilities.map(\.id))
        let unlisted = liveIDs.subtracting(fixtureLiveIDs)
            .filter { $0.hasPrefix("proxy.") || $0.hasPrefix("arbitration.") }
        if !unlisted.isEmpty { drift.append("真内核有而装置 live 清单没有:\(unlisted.sorted())") }
        // 停用名单里的 id 必须真的不在内核注册表里(名单与实现同步的活体判据)。
        let stillLive = A2PanelFixtures.disabledCapabilityIDs.filter { liveIDs.contains($0) }
        if !stillLive.isEmpty { drift.append("列入停用却仍在内核注册表里:\(stillLive.sorted())") }

        say("PANEL_MANIFEST: ok=\(drift.isEmpty ? 1 : 0) checked=\(A2PanelFixtures.liveCapabilities.count) "
            + "drift=\(drift.isEmpty ? "-" : drift.joined(separator: " | "))")
        return drift.isEmpty
    }

    /// 覆盖面与反向交叉核对 —— 对象是**真内核的能力全集**(14 票那条断言的加强版:
    /// 那时对的是同进程的假注册表,现在对的是真的跑着的那个内核)。
    private func checkCoverage(_ state: A2PanelState) -> Bool {
        // 覆盖面用**全部固定装置 + 当前实况**的并集判:有些用户操作只在特定状态下才有项。
        var models = A2PanelFixtures.fixtures.map { fixture -> A2MenuModel in
            var fixtureState = fixture.state
            fixtureState.capabilities = state.capabilities   // 用真能力清单重造
            return A2MenuModelBuilder.build(state: fixtureState)
        }
        models.append(A2MenuModelBuilder.build(state: state))
        let allItems = models.flatMap { $0.flattened }
        let liveIDs = Set(state.capabilities.map(\.id))

        var problems: [String] = []

        // ① 每个绑定项都追溯得到**真内核登记过**的能力。
        let bound = allItems.filter { $0.capabilityID != nil }
        let unresolved = Set(bound.compactMap { $0.capabilityID }).subtracting(liveIDs)
        if bound.isEmpty { problems.append("菜单里没有任何绑定能力的项") }
        if !unresolved.isEmpty { problems.append("菜单绑了内核没有的能力:\(unresolved.sorted())") }

        // ② 认领了用户操作的项必须绑能力(否则「覆盖」是空话)。
        if allItems.contains(where: { $0.userAction != nil && $0.capabilityID == nil }) {
            problems.append("有项认领了用户操作却没绑能力(空头认领)")
        }

        // ③ 04 票 In 清单六项逐项有落到真实能力的菜单项 —— **但只对背后能力当前真在注册表里的那几项**。
        //    某项承诺被暂时收回(2026-08-12:写面九条停用)时,它「没露出来」不是回归而是设计;
        //    分母因此跟着活着的能力走,而不是恒等于 6。判据来自 `userActionCapabilities` 那张对账表。
        var covered = 0
        var expected = 0
        for action in A2MenuUserAction.allCases {
            let items = allItems.filter { $0.userAction == action && $0.capabilityID != nil }
            let backing = A2PanelFixtures.userActionCapabilities[action.rawValue] ?? []
            if backing.isEmpty { problems.append("用户操作「\(action.displayName)」没有登记它背后的能力") ; continue }
            guard backing.contains(where: { liveIDs.contains($0) }) else {
                // 背后一条能力都没注册 → 这一项**本就不该露出来**。反过来若它还露着,那才是缺陷:
                // 点了会打到一个内核根本不认的 id。
                if !items.isEmpty {
                    problems.append("用户操作「\(action.displayName)」背后的能力一条都没注册,菜单却仍有项")
                }
                continue
            }
            expected += 1
            let hit = !items.isEmpty && items.allSatisfy { liveIDs.contains($0.capabilityID!) }
            if hit { covered += 1 } else { problems.append("用户操作「\(action.displayName)」没有落到真实能力的菜单项") }
        }

        // ④ 反向:真内核里每条 normal/dangerous 的 proxy 能力都在菜单里露出,或在豁免表里记账。
        let actionable = state.capabilities.filter {
            $0.id.hasPrefix("proxy.") && ($0.risk == .normal || $0.risk == .dangerous)
        }.map(\.id)
        let exposed = Set(allItems.compactMap { $0.capabilityID })
        let missing = actionable.filter { !exposed.contains($0) && A2PanelFixtures.menuExemptCapabilities[$0] == nil }
        if actionable.isEmpty { problems.append("真内核里一条可发起的 proxy 能力都没有(沙盒没配好?)") }
        if !missing.isEmpty { problems.append("真内核有可发起的 proxy 能力没进菜单也没记账:\(missing.sorted())") }

        // ⑤ 豁免表里不许有幽灵名(能力删了而豁免记录还在 → 记账失真)。
        let ghosts = A2PanelFixtures.menuExemptCapabilities.keys.filter { !liveIDs.contains($0) }
        if !ghosts.isEmpty { problems.append("豁免表里有内核已经没有的能力:\(ghosts.sorted())") }

        say("PANEL_COVERAGE: ok=\(problems.isEmpty ? 1 : 0) actions=\(covered)/\(expected) "
            + "boundItems=\(bound.count) actionableCaps=\(actionable.count) "
            + "exempt=\(A2PanelFixtures.menuExemptCapabilities.keys.sorted().joined(separator: ",")) "
            + "problems=\(problems.isEmpty ? "-" : problems.joined(separator: " | "))")
        return problems.isEmpty
    }

    /// 把当前菜单**摘要**成一行 —— e2e 断言「状态变化真的进了菜单」靠它。
    ///
    /// `nodes=` 给的是**每个组各自的选中项**(`组:节点`,按组名排序)。不取"第一个勾选的节点":
    /// 分组不止一个,那样取到的是哪一条取决于顺序,断言会变成薛定谔的。
    private func menuLine(_ state: A2PanelState) -> String {
        let model = A2MenuModelBuilder.build(state: state)
        let items = model.flattened
        let mode = items.first { $0.capabilityID == "proxy.mode.set" && $0.checked }?
            .params["mode"]?.stringValue ?? "-"
        let nodes = items.filter { $0.capabilityID == "proxy.node.select" && $0.checked }
            .compactMap { item -> String? in
                guard let group = item.params["group"]?.stringValue,
                      let node = item.params["node"]?.stringValue else { return nil }
                return "\(group):\(node)"
            }
            .sorted()
            .joined(separator: ",")
        let active = items.first { $0.capabilityID == "proxy.subscription.activate" && $0.checked }?
            .params["id"]?.stringValue ?? "-"
        // 2026-08-22 改判:「开启系统代理」从能力项降为**本地项**(复制指令给 agent,接管归它按
        // 本机网络环境执行),于是这里不能再按 capabilityID 找它 —— 判据换成那条本地动作。
        // 勾选态本身的含义一个字没变:它照旧直接来自 `proxy.status` 的 `systemProxy.takenOver`。
        let systemProxy = items.contains { $0.localAction == .copySystemProxyPrompt && $0.checked } ? "on" : "off"
        return "PANEL_MENU: mode=\(mode) nodes=\(nodes.isEmpty ? "-" : nodes) active=\(active) "
            + "systemProxy=\(systemProxy) running=\(state.proxy.kernelRunning ? 1 : 0) "
            + "groups=\(state.proxy.groups.count) subs=\(state.proxy.subscriptions.count) items=\(items.count)"
    }
}

// ============================================================================
// 主流程
// ============================================================================

let options = parseOptions()
let probe = Probe(options: options)
let session = A2PanelSession(
    configuration: .init(
        socketPath: options.socketPath,
        identity: A2ClientIdentity(name: "a2-panel-probe", version: "0.1.0"),
        reconnectDelay: 0.5),
    delegate: probe,
    // **装配与壳逐字同形**(见 ScriptedHandlerSetter 头注):同一个 Runner、同一个注册开关,
    //   只有 setter 换成剧本假件。不装 = 不举手,内核那侧如实报"没有执行器在场"。
    executor: options.executor
        ? A2URLRouterExecutorRunner(
            setter: ScriptedHandlerSetter(),
            log: { line in say("PANEL_EXECUTE_LOG: \(line)") })
        : nil)
probe.session = session
session.start()

// 等注册完成(会话拿到快照就会 publish,`PANEL_MANIFEST` 是它的第一个副作用)。
let readyDeadline = Date().addingTimeInterval(15)
while Date() < readyDeadline, probe.verdicts.manifest == nil {
    Thread.sleep(forTimeInterval: 0.05)
}
guard probe.verdicts.manifest != nil else {
    say("PANEL_SUMMARY: confirmations=0 decided=0 requests=\(session.requestCount) ok=0(15 秒内没连上内核)")
    session.stop()
    exit(1)
}
say("PANEL_READY: role=\(options.role.rawValue) requests=\(session.requestCount)")

// 空闲探针:**零轮询的可核查证据**。这段时间里壳一个字节都不该往内核发。
//
// 先等**起步流量停下来**再开始计:注册那一次往返之后紧跟着三条 safe 只读(代理域第一次取数),
//   如果在它们还没发完时就取 `before`,量到的是起步流量而不是空闲流量 —— 那种红是假红。
//   判据是「请求数连续 0.5 秒没变」,不是一个拍脑袋的 sleep。
if options.idleSeconds > 0 {
    var settled = session.requestCount
    let settleDeadline = Date().addingTimeInterval(10)
    var stableSince = Date()
    while Date() < settleDeadline {
        Thread.sleep(forTimeInterval: 0.05)
        let now = session.requestCount
        if now != settled {
            settled = now
            stableSince = Date()
        } else if Date().timeIntervalSince(stableSince) >= 0.5 {
            break
        }
    }
    let before = session.requestCount
    Thread.sleep(forTimeInterval: options.idleSeconds)
    let after = session.requestCount
    say("PANEL_IDLE: before=\(before) after=\(after) seconds=\(Int(options.idleSeconds))")
}

let deadline = Date().addingTimeInterval(options.duration)
while Date() < deadline {
    if options.quitAfterDecisions > 0, probe.counts.decided >= options.quitAfterDecisions { break }
    Thread.sleep(forTimeInterval: 0.05)
}

let counts = probe.counts
let verdicts = probe.verdicts
session.stop()
// 给会话线程一点时间把 stop 走完(它最多阻塞一个 idleReadWindow)。
Thread.sleep(forTimeInterval: 0.4)

let ok = (verdicts.manifest == true)
    && (verdicts.coverage == true)
    && counts.confirmations >= options.expectConfirmations
say("PANEL_SUMMARY: confirmations=\(counts.confirmations) decided=\(counts.decided) "
    + "requests=\(session.requestCount) ok=\(ok ? 1 : 0)")
exit(ok ? 0 : 1)
