// A2KernelClient —— a2 内核 UDS 客户端基座(09 票)。
//
// 它做四件事,一件不多:
//   ① 连上 `<A2_HOME>/run/kernel.sock`,按 NDJSON 收发帧(字节级拆行,见 `A2LineBuffer`);
//   ② 请求-响应**按 id 相关**(长连接上响应与推送交错到达,不能"读到第一行就当答案");
//   ③ 推送**分流入队**(帧判别是结构性的:有 `ok` 是响应,有 `push` 是推送);
//   ④ 角色注册 / 快照接收 / `confirmations.resolve` 往返 —— 壳(10 票)要的全套动作。
//
// **注册往返是原子的**:`roles.register` 的响应里就带着全量快照。所以本类型的 `registerRole`
// 返回的就是 `A2RoleRegisterResult`(内含 snapshot)—— 不存在"注册成功了再去查一次状态"的写法,
// 那种写法会制造一个内核根本不提供的中间态。快照即基线,之后全靠推送跟进。
//
// **线程模型:单线程阻塞**。一条连接上一次只等一件事(CLI 与确认器都是这个用法)。
// 壳要一边收推送一边响应点击,应当把这个客户端放在自己的后台线程上跑循环,而不是让它变成多线程 ——
// 协议本身就是"一条连接一条时间线",把并发塞进这一层只会让"确认到底是谁回的"变得不可复盘。
//
// **超时之后这条连接就废了 —— 用完必须重连**(10 票的壳靠这条语义写重连逻辑):
//   `awaitResponse` 抛 `.timeout` 只代表"我不等了",**内核那侧并不知道**,它照样可能过一会儿把那条
//   响应写过来。而本客户端一次只认一条请求的 id,于是那条迟到的响应会在**下一次** `request` 里
//   撞成 `.protocolViolation`(id 对不上)。这是有意的:静默吞掉一条对不上号的响应,等于让
//   "我收到的这个答案到底是谁的"变成薛定谔的问题 —— 在仲裁面上那是不可接受的。
//   所以调用方的规矩是:**收到 `.timeout` 就 `close()` 并重连**(重连后要重新 `roles.register`,
//   拿一份新的全量快照当基线)。想在同一条连接上继续用,得先有"废弃 id 名单"这类机制,V1 不做。

import Foundation
import A2Contract

public final class A2KernelClient {

    public struct Configuration: Sendable {
        /// 默认等响应的时长。
        public var requestTimeout: TimeInterval
        /// 内核推来 `confirmation-pending`(「我转给人了,最多等 N 毫秒」)之后,在它承诺的窗口之外
        /// 再多给的余量 —— 网络与调度的毛边。与 TS 客户端的 `PENDING_GRACE_MS` 同义。
        public var pendingGrace: TimeInterval

        public init(requestTimeout: TimeInterval = 5, pendingGrace: TimeInterval = 3) {
            self.requestTimeout = requestTimeout
            self.pendingGrace = pendingGrace
        }
    }

    /// 已登记的 op(对照 `wire.ts` 的 `Op`)。
    public enum Op {
        public static let statusGet = "status.get"
        public static let capabilitiesList = "capabilities.list"
        public static let capabilitiesDescribe = "capabilities.describe"
        public static let capabilitiesCall = "capabilities.call"
        public static let rolesRegister = "roles.register"
        public static let confirmationsResolve = "confirmations.resolve"
    }

    private let transport: A2Transport
    private let configuration: Configuration
    private var buffer = A2LineBuffer()
    private var pushes: [A2PushEnvelope] = []
    private let correlationPrefix = UUID().uuidString
    private var sequence = 0

    public init(transport: A2Transport, configuration: Configuration = Configuration()) {
        self.transport = transport
        self.configuration = configuration
    }

    /// 连上一个真内核。
    public static func connect(
        socketPath: String, configuration: Configuration = Configuration()
    ) throws -> A2KernelClient {
        A2KernelClient(
            transport: try A2UnixSocketTransport.connect(socketPath: socketPath),
            configuration: configuration)
    }

    public func close() {
        transport.close()
    }

    // MARK: - 请求 / 响应

    /// 发一条请求并等它自己的那一条响应。期间到达的推送**入队**(不丢),供 `nextPush` 取用。
    @discardableResult
    public func request(
        op: String, params: [String: A2JSON]? = nil, timeout: TimeInterval? = nil
    ) throws -> A2ResponseEnvelope {
        sequence += 1
        let id = "\(correlationPrefix)-\(sequence)"
        let envelope = A2RequestEnvelope(id: id, op: op, params: params)
        var line = try JSONEncoder().encode(envelope)
        line.append(0x0A)
        try transport.send(Array(line))
        return try awaitResponse(id: id, timeout: timeout ?? configuration.requestTimeout)
    }

    /// 同 `request`,但失败包封当场抛 `kernelRefused`(理由原样带着) —— 调用方只处理成功路径。
    public func requestResult(
        op: String, params: [String: A2JSON]? = nil, timeout: TimeInterval? = nil
    ) throws -> A2JSON {
        let response = try request(op: op, params: params, timeout: timeout)
        switch response {
        case let .success(success): return success.result
        case let .failure(failure): throw A2ClientError.kernelRefused(failure.error)
        }
    }

    /// 等某条请求的响应。
    ///
    /// 两条容易写错的地方,这里都写对了:
    ///   * **不认第一行**:长连接上先到的可能是推送,也可能是**别的**请求的响应(本客户端一次只等一条,
    ///     但内核那侧不欠这个保证)—— 只有 id 对上的才算数,其余响应按协议违例处理(不静默吞)。
    ///   * **超时会被内核延长**:收到指向本请求的 `confirmation-pending` 就把截止时间顺延到内核承诺的窗口
    ///     + 余量。确认窗口是内核的配置,客户端**不共享环境变量去猜**,一致性由协议给。
    public func awaitResponse(id: String, timeout: TimeInterval) throws -> A2ResponseEnvelope {
        var deadline = Date().addingTimeInterval(timeout)
        while true {
            let frame = try nextFrame(deadline: deadline, waitingFor: id)
            switch frame {
            case let .response(response):
                guard response.id == id else {
                    throw A2ClientError.protocolViolation(
                        "收到不属于本请求的响应(期待 \(id),实际 \(response.id))")
                }
                return response
            case let .push(push):
                pushes.append(push)
                if case let .confirmationPending(_, requestId, timeoutMs, _) = push.event,
                   requestId == id {
                    let extended = Date().addingTimeInterval(
                        Double(timeoutMs) / 1000 + configuration.pendingGrace)
                    if extended > deadline { deadline = extended }
                }
            }
        }
    }

    // MARK: - 推送

    /// 已经收进队列、还没被取走的推送(**不消费**)。
    public var bufferedPushes: [A2PushEnvelope] { pushes }

    /// 取下一条满足条件的推送:先翻已入队的,再继续读连接。到点没等到就抛 `timeout`。
    ///
    /// `matching` 缺省 = 任意推送。等待期间到达的**响应**是协议违例(没人在等响应却来了一条),
    /// 如实抛出而不是丢掉 —— 丢帧是最难查的那种 bug。
    @discardableResult
    public func nextPush(
        timeout: TimeInterval? = nil, matching predicate: (A2PushEnvelope) -> Bool = { _ in true }
    ) throws -> A2PushEnvelope {
        if let index = pushes.firstIndex(where: predicate) {
            return pushes.remove(at: index)
        }
        let deadline = Date().addingTimeInterval(timeout ?? configuration.requestTimeout)
        while true {
            let frame = try nextFrame(deadline: deadline, waitingFor: nil)
            switch frame {
            case let .push(push):
                if predicate(push) { return push }
                pushes.append(push)
            case let .response(response):
                throw A2ClientError.protocolViolation(
                    "等推送时收到一条没人在等的响应(id=\(response.id))")
            }
        }
    }

    // MARK: - 角色注册与确认往返

    /// 在**当前这条长连接**上注册一个角色,并拿回全量快照(同一次往返)。
    ///
    /// 在场 = 长连接:这条连接断开的那一刻角色即消失,在途的 dangerous 请求会被内核**立即**按默拒收尾
    /// (不等超时)。所以调用方要做的不是"定期续约",而是"别让这条连接断"。
    public func registerRole(
        _ role: A2ClientRole, identity: A2ClientIdentity, timeout: TimeInterval? = nil
    ) throws -> A2RoleRegisterResult {
        let params = try A2JSON.encoding(A2RoleRegisterParams(role: role, identity: identity))
        guard let object = params.objectValue else {
            throw A2ClientError.protocolViolation("roles.register 的 params 编码结果不是 JSON 对象")
        }
        let result = try requestResult(op: Op.rolesRegister, params: object, timeout: timeout)
        do {
            return try result.decode(A2RoleRegisterResult.self)
        } catch {
            throw A2ClientError.protocolViolation("roles.register 的 result 解不动:\(error)")
        }
    }

    /// 替人类回一条决定。**只有注册过 confirm-agent 的连接能发**(否则内核回 `role_not_registered`)。
    @discardableResult
    public func resolveConfirmation(
        _ confirmation: String, decision: A2ConfirmationDecision, reason: String? = nil,
        timeout: TimeInterval? = nil
    ) throws -> A2ConfirmationResolveResult {
        let params = try A2JSON.encoding(
            A2ConfirmationResolveParams(confirmation: confirmation, decision: decision, reason: reason))
        guard let object = params.objectValue else {
            throw A2ClientError.protocolViolation("confirmations.resolve 的 params 编码结果不是 JSON 对象")
        }
        let result = try requestResult(op: Op.confirmationsResolve, params: object, timeout: timeout)
        do {
            return try result.decode(A2ConfirmationResolveResult.self)
        } catch {
            throw A2ClientError.protocolViolation("confirmations.resolve 的 result 解不动:\(error)")
        }
    }

    /// 调一条能力(壳的每个可点菜单项最终都落到这里 —— 薄壳铁律:动作只经这一个出口)。
    @discardableResult
    public func callCapability(
        _ capability: String, input: [String: A2JSON]? = nil, timeout: TimeInterval? = nil
    ) throws -> A2ResponseEnvelope {
        var params: [String: A2JSON] = ["capability": .string(capability)]
        if let input { params["input"] = .object(input) }
        return try request(op: Op.capabilitiesCall, params: params, timeout: timeout)
    }

    // MARK: - 帧

    /// 读下一帧(先看缓冲里有没有整行,没有就继续收字节)。
    private func nextFrame(deadline: Date, waitingFor id: String?) throws -> A2ServerFrame {
        while true {
            if let line = buffer.nextLine() {
                return try Self.decodeFrame(line)
            }
            if Date() >= deadline {
                let what = id.map { "请求 \($0) 的响应" } ?? "推送"
                throw A2ClientError.timeout(
                    "等\(what)超时(缓冲里还剩 \(buffer.pendingByteCount) 字节未成行)")
            }
            let chunk = try transport.receive(deadline: deadline)
            if chunk.isEmpty { continue }
            buffer.append(chunk)
        }
    }

    /// 一整行字节 → 服务端帧。**先切行再解码**:多字节字符被 chunk 边界劈开的坑归 `A2LineBuffer` 兜。
    static func decodeFrame(_ line: [UInt8]) throws -> A2ServerFrame {
        do {
            return try JSONDecoder().decode(A2ServerFrame.self, from: Data(line))
        } catch {
            let text = String(decoding: line, as: UTF8.self)
            throw A2ClientError.protocolViolation("解不动这一帧:\(error);原文:\(text)")
        }
    }
}
