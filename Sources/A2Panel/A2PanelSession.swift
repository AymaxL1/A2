// A2Panel —— **会话**:一条长连接、一条时间线(10 票)。
//
// ============================================================================
// 线程模型(09 票交接单第 ④ 条,照办)
// ============================================================================
// `A2KernelClient` 是**单线程阻塞**的(一条连接一条时间线)。所以会话自己开一条 `Thread`,
// 客户端**只**在那条线程上被碰。外面(菜单点击、确认器回决定)要发请求,一律**入队**,
// 由会话线程在两次读之间取出来发。把并发塞进客户端那一层,「这个确认到底是谁回的」会不可复盘。
//
// ============================================================================
// 「零轮询」的准确含义(别把它说大,也别说小)
// ============================================================================
// 会话在空闲时确实在**读** socket(带 `SO_RCVTIMEO` 的阻塞 recv,到点返回空)—— 那是**收**,
// 一个字节都不往内核发。`requestCount` 逐条记着这条连接发出去的**每一条请求**,
// 旗舰 e2e 据此断言:注册之后的空闲期里,请求数**一条都不涨**。
// 会发请求的只有三种时刻:①注册;②内核推来「有人改了状态」;③用户点了菜单/回了确认。
//
// ============================================================================
// 断线与重连(09 票交接单第 ⑤ 条)
// ============================================================================
// * 断线即离场,**没有**重连恢复会话:重连后重新 `roles.register` 拿新的全量快照当基线,
//   待办以内核推来的 `arbitration` 为准(在途请求可能在断线期间已被降级/取消)。
// * 收到 `.timeout` 的**响应**等待即视为连接报废 → `close()` + 重连(客户端头注写明了理由:
//   那条迟到的响应会在下一次请求里撞成协议违例)。**等推送超时不属此列** ——
//   那时没有任何在途请求,连接是干净的,继续读即可。
// * 内核对慢消费者会主动断连(推送积压 > 4 MiB,审计 `backpressure_dropped`)。所以事件处理
//   **绝不能长时间阻塞读循环**:本会话把界面动作交给 `delegate` 立即返回,渲染在别的线程上做。

import Foundation
import A2Contract
import A2KernelClient

/// 会话把「状态变了」「要弹确认」这类事告诉外面的口子。
///
/// **实现者必须立即返回**(见文件头慢消费者一段):要更新界面就往主线程投递,别在这里同步等 UI。
public protocol A2PanelSessionDelegate: AnyObject {
    func panelSession(_ session: A2PanelSession, didUpdate state: A2PanelState)
    /// 呈现一条确认请求。**必须原样展示 `input`**(用 `A2ConfirmationPresentation`)。
    func panelSession(_ session: A2PanelSession, present request: A2ConfirmationRequest)
    /// 这些确认已经收场(批准/拒绝/超时/降级/取消),把对应界面关掉。
    func panelSession(_ session: A2PanelSession, dismissConfirmations ids: [String])
    /// 人读日志(连接、重连、错误)。壳缺席时这些事**在内核那侧**照样入审计日志、CLI 可查;
    /// 这一条只是给用户看的即时反馈,不是日志的权威来源。
    func panelSession(_ session: A2PanelSession, log line: String)
}

public final class A2PanelSession {

    public struct Configuration: Sendable {
        /// `<A2_HOME>/run/kernel.sock`。
        public var socketPath: String
        /// 自报身份(**V1 不构成身份**,只进审计与展示)。
        public var identity: A2ClientIdentity
        /// 断线后重连的间隔。
        public var reconnectDelay: TimeInterval
        /// 空闲时一次读的最长阻塞时长(只影响「多久检查一次待发队列」,与内核无关)。
        public var idleReadWindow: TimeInterval

        public init(socketPath: String,
                    identity: A2ClientIdentity,
                    reconnectDelay: TimeInterval = 2,
                    idleReadWindow: TimeInterval = 0.25) {
            self.socketPath = socketPath
            self.identity = identity
            self.reconnectDelay = reconnectDelay
            self.idleReadWindow = idleReadWindow
        }
    }

    /// 排队等着发出去的一条动作(全部由会话线程执行)。
    enum Command {
        case call(capability: String, input: [String: A2JSON])
        case resolve(confirmation: String, decision: A2ConfirmationDecision, reason: String?)
        case refreshProxy
    }

    private let configuration: Configuration
    private weak var delegate: A2PanelSessionDelegate?

    private let queueLock = NSCondition()
    private var queued: [Command] = []
    private var stopping = false

    private var thread: Thread?
    private var client: A2KernelClient?
    private var state = A2PanelState()

    /// 本会话向内核发出去的请求总数(「零轮询」的可核查证据,见文件头)。
    private let counterLock = NSLock()
    private var _requestCount = 0
    public var requestCount: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return _requestCount
    }

    public init(configuration: Configuration, delegate: A2PanelSessionDelegate?) {
        self.configuration = configuration
        self.delegate = delegate
    }

    // MARK: - 生命周期

    public func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "a2-panel-session"
        // 用**专用线程**而不是 `DispatchQueue.global()`:客户端是阻塞式的,占住一个池线程会
        //   拖慢别人;而且 09 票 CR 记过一次真事 —— 并行环境下池线程被占满会让时序断言假红。
        thread.start()
        self.thread = thread
    }

    /// 停止会话。**壳退出走的就是这条路:只断连,什么都不还原**
    /// (ADR 0008:「退出即还原」废除;还原是 `a2 proxy off` 这条显式命令的事)。
    public func stop() {
        queueLock.lock()
        stopping = true
        queueLock.signal()
        queueLock.unlock()
    }

    // MARK: - 外面来的动作(线程安全,只入队)

    /// 发起一次能力调用(菜单每个可点项的唯一出口 —— 薄壳铁律)。
    public func call(capability: String, input: [String: A2JSON] = [:]) {
        enqueue(.call(capability: capability, input: input))
    }

    /// 替人类回一条决定。
    public func resolve(confirmation: String, decision: A2ConfirmationDecision, reason: String? = nil) {
        enqueue(.resolve(confirmation: confirmation, decision: decision, reason: reason))
    }

    private func enqueue(_ command: Command) {
        queueLock.lock()
        queued.append(command)
        queueLock.signal()
        queueLock.unlock()
    }

    private func drainQueue() -> [Command] {
        queueLock.lock(); defer { queueLock.unlock() }
        let out = queued
        queued.removeAll()
        return out
    }

    private var shouldStop: Bool {
        queueLock.lock(); defer { queueLock.unlock() }
        return stopping
    }

    // MARK: - 会话循环(只在会话线程上跑)

    private func run() {
        while !shouldStop {
            do {
                try connectAndServe()
            } catch {
                emit(log: "连接中断:\(error)")
            }
            client?.close()
            client = nil
            A2PanelProjection.disconnect(&state, reason: "与内核断开,正在重连")
            publish()
            if shouldStop { break }
            Thread.sleep(forTimeInterval: configuration.reconnectDelay)
        }
        client?.close()
        client = nil
        emit(log: "会话已停止(仅断连;代理与内核不受影响)")
    }

    private func connectAndServe() throws {
        let client = try A2KernelClient.connect(socketPath: configuration.socketPath)
        self.client = client
        // **注册即快照**:同一次往返拿回全量基线,不存在「注册成功了再查一次状态」的中间态。
        let registered = try countingRequest { try client.registerRole(.confirmAgent, identity: configuration.identity) }
        state = A2PanelProjection.base(from: registered.snapshot)
        emit(log: "已注册 confirm-agent(连接 \(registered.connection),uid=\(registered.uid.map(String.init) ?? "未知"))")
        publish()
        try refreshProxy(client)
        publish()

        while !shouldStop {
            for command in drainQueue() {
                try execute(command, on: client)
            }
            if shouldStop { break }
            do {
                let push = try client.nextPush(timeout: configuration.idleReadWindow)
                let effect = A2PanelProjection.apply(push.event, to: &state)
                switch effect {
                case .none:
                    break
                case .refreshProxy:
                    try refreshProxy(client)
                case let .presentConfirmation(request):
                    delegate?.panelSession(self, present: request)
                case let .dismissConfirmations(ids):
                    delegate?.panelSession(self, dismissConfirmations: ids)
                }
                publish()
            } catch A2ClientError.timeout {
                // 空闲:到点没读到帧。**连接是干净的**(没有在途请求),继续读。
                continue
            }
        }
    }

    private func execute(_ command: Command, on client: A2KernelClient) throws {
        switch command {
        case let .call(capability, input):
            let response = try countingRequest {
                try client.callCapability(capability, input: input.isEmpty ? nil : input)
            }
            if let error = response.error {
                // 失败**如实报出来**,尤其是 `confirmation_denied` / `confirmation_unavailable` ——
                //   那正是仲裁在起作用的证据,壳不许把它吞成「什么也没发生」。
                emit(log: "\(capability) 失败:\(error.code) \(error.message)")
            } else {
                emit(log: "\(capability) 完成")
            }
            // 调用完不主动重读:内核会为 normal/dangerous 广播 `capability` 事件,
            //   重读由那条事件触发(所有客户端同一时刻看到同一份事实)。
        case let .resolve(confirmation, decision, reason):
            do {
                _ = try countingRequest {
                    try client.resolveConfirmation(confirmation, decision: decision, reason: reason)
                }
                emit(log: "已回决定:\(decision.rawValue)(\(confirmation))")
            } catch let A2ClientError.kernelRefused(error) {
                // 最常见的一种:窗口已经关了(超时/降级/发起方走了)。如实报,不重试。
                emit(log: "决定未被采纳:\(error.code) \(error.message)")
            }
        case .refreshProxy:
            try refreshProxy(client)
            publish()
        }
    }

    /// 重读三条 **safe 只读能力**,重建代理域视图。
    ///
    /// 为什么是「重读」而不是「把事件载荷叠进本地清单」:见 `A2PanelState` 头注 —— 那样壳就得
    /// 复制订阅域的业务语义,是 ADR 0008 第 5 条明禁的事。
    private func refreshProxy(_ client: A2KernelClient) throws {
        func read(_ capability: String) -> (A2JSON?, String?) {
            guard state.capabilities.contains(where: { $0.id == capability }) else {
                return (nil, "内核未登记 \(capability)")
            }
            do {
                let response = try countingRequest { try client.callCapability(capability) }
                switch response {
                case let .success(success):
                    return (success.result.objectValue?["output"], nil)
                case let .failure(failure):
                    return (nil, "\(capability) 失败:\(failure.error.code) \(failure.error.message)")
                }
            } catch {
                return (nil, "\(capability) 读取异常:\(error)")
            }
        }
        let (status, statusNote) = read("proxy.status")
        let (groups, groupsNote) = read("proxy.groups.list")
        let (subscriptions, subsNote) = read("proxy.subscription.list")
        state.proxy = A2ProxyView.from(status: status, groups: groups, subscriptions: subscriptions,
                                       extraNotes: [statusNote, groupsNote, subsNote].compactMap { $0 })
    }

    // MARK: - 助手

    private func countingRequest<T>(_ body: () throws -> T) rethrows -> T {
        counterLock.lock()
        _requestCount += 1
        counterLock.unlock()
        return try body()
    }

    private func publish() {
        delegate?.panelSession(self, didUpdate: state)
    }

    private func emit(log line: String) {
        delegate?.panelSession(self, log: line)
    }
}
