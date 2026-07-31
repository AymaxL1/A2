// AAAgentCore —— 消息静默看门狗(agent-delegation 05 票第 1/2 条)。
// 依赖边:本文件**零 import**(只用同模块的 `AgentMessage` 与 stdlib)。模块级红线同 AgentPort.swift:
//   AAAgentCore 绝不 import 任何 Host* / AAPluginSDK / PluginProxy(check.sh 断言组 3d 用 grep 强制)。
//
// **时间全靠外部喂**:本类型不碰 `Date()`、不 sleep、不起线程 —— 每个方法都收一个 `epochSeconds`,
//   由调用方从 `AgentClockPort.now().epochSeconds` 取。故整条看门狗逻辑在 `FakeClock` 上跑,
//   门禁是毫秒级的纯值计算,零真实等待。任何在本文件里读系统时钟的写法都是 bug。
//
// **判据是「消息静默时长」,不是「进程还在不在」**:进程活着但一个字都不吐,才是这套机制要抓的卡死;
//   进程死了是 `AgentPort.isAlive` / 退出码那条路的事(见 `AgentTaskState.resolve` 的分工注释)。
//   两者互不替代:agent 卡在一个永远回不来的网络请求上时,进程是活的、退出码是没有的。
//
// **为什么「有工具在途」要放宽预算**:一次 tool-use 发出后到 tool-result 回来之间,agent 侧本来就可能
//   长时间不产任何事件(工具自己在跑:编译、跑测试、下载)。拿 idle 档去卡这段,就是把正常长跑工具误杀。
//   放宽必须是**动态**的 —— 工具闭合后立刻退回 idle 档,不是「一旦有过工具就永久放宽」
//   (那等于把看门狗关掉:任何任务只要开头调过一次工具,后面卡死多久都没人管)。

/// 看门狗阈值(可配)。两档:无工具在途的 `idle` 档与有工具在途的放宽档。
///
/// **默认值的实证依据(不是拍脑袋,来源见 `.scratch/agent-delegation/research/`)**:
/// - Codex 侧(02 spike `spike-codex-exec/findings.md`):失败路径天然慢 —— `exec3` 样本被本机 90s 硬超时兜底,
///   流里全是 `Reconnecting... 2/5 … 5/5` 的网络重连提示;`exec7` 进一步证实每个传输通道重试 5 次、
///   WebSocket 试完回退 HTTPS 再试 5 次,**全程可达 40+ 秒**。该 findings 的**建议 4**要求阈值覆盖网络重试链路的
///   最坏情况(40+ 秒),不能照抄「几秒没输出就判卡死」;**至少 60-90 秒**余量这个具体数字出自同一份 findings 的
///   **意外发现 2**(两处出处不同,别混引)。
/// - Claude 侧(01 spike `spike-claude-headless/findings.md`):8 次真调里 2 次出现 `system/api_retry`
///   指数退避,CLI 自带重试且透明上报到流里 —— 退避期间同样是长时间无实质输出。
/// → `idleTimeoutSeconds` 取 **120**(覆盖上面 90s 的观测窗口还留 30s 余量),
///   `toolInFlightTimeoutSeconds` 取 **900**(15 分钟:够一次真编译 / 跑一遍测试)。
///
/// 默认值只是**不误杀的起点**,不是宪法:票面要的是「阈值可配」,07 票 CLI 要能整体覆盖这两个值。
/// 非正数阈值意味着「任何静默都算卡死」——本类型如实照用不钳制(可配就要真可配),该拦在 CLI 的参数校验里。
public struct AgentWatchdogPolicy: Sendable, Equatable {
    /// 无未闭合工具调用时的静默上限(秒)。
    public let idleTimeoutSeconds: Int
    /// **有**未闭合工具调用时放宽到的上限(秒)。
    public let toolInFlightTimeoutSeconds: Int

    public init(idleTimeoutSeconds: Int, toolInFlightTimeoutSeconds: Int) {
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.toolInFlightTimeoutSeconds = toolInFlightTimeoutSeconds
    }

    /// 默认阈值:idle 120 秒 / 工具在途 900 秒(依据见类型注释)。
    public static let `default` = AgentWatchdogPolicy(
        idleTimeoutSeconds: 120,
        toolInFlightTimeoutSeconds: 900
    )
}

/// 看门狗判决。
///
/// `stalled` 带上「静默了多久」与「卡死时是否有工具在途」两项诊断信息:任务被判超时之后,
/// 用户要能从 meta / 报告里看出「是卡在等某个工具回来,还是干脆一条消息都没有」——
/// 只回一个 bool 等于把唯一的现场信息扔掉。
public enum AgentWatchdogVerdict: Sendable, Equatable {
    /// 仍在阈值内(含「刚有活动」与「还在正常重试」两种)。
    case healthy
    /// 判定卡死:静默秒数 + 卡死时是否有未闭合工具调用。
    case stalled(silentSeconds: Int, toolInFlight: Bool)
}

/// 消息静默看门狗(纯值语义,时间全靠外部喂)。
///
/// 用法:每读到一条归一化消息就 `observe(_:at:)`,每轮循环 `verdict(at:)` 问一次;
/// 判 `stalled` 时由调用方走 `AgentCancellation.timeOut(...)`(先迁 `.timeout` 再发终止意图)。
public struct AgentWatchdog: Sendable {
    /// 本次运行采用的阈值(可配;默认 `.default`)。
    public let policy: AgentWatchdogPolicy
    /// 最后一次「有活动」的时刻(epoch 秒)。初值是 `startedAt` —— 拉起那一刻起就开始算静默,
    /// 否则「拉起后一条消息都没吐」这种最典型的卡死永远触发不了。
    public private(set) var lastActivityAt: Int
    /// 未闭合的工具调用 id 集合。用 `Set` 而非计数器:tool-result 可能乱序 / 重复到达,
    /// 按 id 收敛天然幂等(同一个 id 闭合两次不会把计数减到负数)。
    private var openCallIDs: Set<String> = []

    public init(policy: AgentWatchdogPolicy = .default, startedAt: Int) {
        self.policy = policy
        self.lastActivityAt = startedAt
    }

    /// 当前未闭合的工具调用数(测试与诊断用)。
    public var toolsInFlight: Int { openCallIDs.count }

    /// 当前是否有工具在途。
    public var isToolInFlight: Bool { !openCallIDs.isEmpty }

    /// 当前生效的静默上限 —— **动态**取档:有工具在途取放宽档,否则取 idle 档。
    /// 工具一闭合就退回 idle 档,故「一旦有过工具就永久放宽」这种漏网不存在。
    public var currentTimeoutSeconds: Int {
        isToolInFlight ? policy.toolInFlightTimeoutSeconds : policy.idleTimeoutSeconds
    }

    /// 观察一条统一消息:刷新「最后活动时刻」,并据 tool-use / tool-result 维护在途集合。
    ///
    /// **任何一型消息都算活动**(text / thinking / status / error 一视同仁):
    ///   Codex 的 `Reconnecting... 3/5` 归一化后是 `error` 型消息 —— 它恰恰是「还活着、还在重试」的心跳
    ///   (02 spike findings 建议 4 明确要求把这类事件当存活判据)。若只认 text 型,重试期间就会被误杀。
    ///
    /// 畸形消息的两条(**都不报错**:agent 的流本来就可能被截断 / 半行,把它当致命错会让一条脏数据打挂整个任务):
    /// - `callID` 为 nil / 空串的 tool-use **不进集合**。空 id 是个共享的键:所有畸形调用会互相顶掉
    ///   (第二个畸形 tool-use 的「入」和第一个畸形 tool-result 的「出」对上号),在途状态就此错乱。
    ///   代价是这次调用不享受放宽档 —— 那是 fail-safe 的一侧(宁可按 idle 档早点判卡死,也不放任状态错乱)。
    /// - 没配上的 tool-result(集合里没有该 id)→ 忽略。`Set.remove` 对不存在的元素是 no-op,
    ///   天然不会把计数减到负数(用计数器就得手写 `max(0,)`,那是多余的机会去写错)。
    public mutating func observe(_ message: AgentMessage, at epochSeconds: Int) {
        // 取 max 而不是直接赋值:墙钟回拨(NTP 校时)时不该把「最后活动」倒退回过去 ——
        // 倒退会凭空制造一段静默,把正常任务误杀。fail-safe 的一侧是「宁可晚判,不可误判」。
        lastActivityAt = max(lastActivityAt, epochSeconds)

        switch message.kind {
        case .toolUse:
            guard let id = message.callID, !id.isEmpty else { break }  // 畸形:不进集合(见方法注释)
            openCallIDs.insert(id)
        case .toolResult:
            guard let id = message.callID, !id.isEmpty else { break }
            openCallIDs.remove(id)                                     // 没配上 → no-op,不减到负数
        case .text, .thinking, .status, .error:
            break                                                      // 只刷新活动时刻(含重连心跳)
        }
    }

    /// 距上次活动的静默秒数。墙钟回拨导致的负数钳到 0(同 `observe` 的理由:不凭空制造静默)。
    public func silentSeconds(at epochSeconds: Int) -> Int {
        max(0, epochSeconds - lastActivityAt)
    }

    /// 在给定时刻出判决(**纯查询,不改状态**:同一时刻问几次答案都一样,便于调用方先问再决策)。
    ///
    /// 判据是**严格大于**阈值(票面原文「静默时长 > 阈值」):恰好等于阈值时仍判 healthy ——
    /// 边界上少杀一秒不会有人受伤,多杀一秒就是误杀。
    public func verdict(at epochSeconds: Int) -> AgentWatchdogVerdict {
        let silent = silentSeconds(at: epochSeconds)
        guard silent > currentTimeoutSeconds else { return .healthy }
        return .stalled(silentSeconds: silent, toolInFlight: isToolInFlight)
    }
}
