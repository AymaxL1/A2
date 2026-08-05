// 09 票 —— 客户端基座的协议逻辑(假内核驱动,不起任何进程)。
//
// 验的是长连接上那几件**只有真到了线上才会露出来**的事:
//   * 注册与首帧快照是**同一次往返**;
//   * 响应按 **id** 认领(推送与响应在同一条连接上交错);
//   * 推送**入队不丢**(等响应期间到达的推送,之后还取得到);
//   * `confirmation-pending` 把等待窗口**顺延**到内核承诺的时长(客户端不猜、不共享环境变量);
//   * 帧在**多字节字符中间**被切开也照样解得开。
//
// **并行安全(09 票 CR 修的第 2 项)**:这套用例带真实等待,曾经在**默认并行**的 `swift test` 下必红 ——
// 假内核跑在 `DispatchQueue.global()` 上,而并行的用例里有好几处 `Thread.sleep` 把线程池占住,
// 假内核那段迟迟排不上、客户端在 0.4 秒的小窗口里先超时了。两处一起修:
//   ① 假内核改用**专用 `Thread`**(`start()` 立刻就有一条真线程,不跟线程池抢);
//   ② 时序断言按"**判据差**"给足余量 —— 断的是"有没有顺延",不是"快不快",
//      所以正例余量拉到 5 秒以上、反例也留 1 秒,几百毫秒级的调度抖动影响不到判定。
// 验证方式:默认并行(不带 `--no-parallel`)连跑 3 遍全绿,再按门禁口径 `--no-parallel` 跑一遍。

import Foundation
import Testing
@testable import A2Contract
@testable import A2KernelClient

@Suite("09 UDS 客户端协议逻辑")
struct A2KernelClientProtocolTests {

    /// 起一条**专用线程**扮演内核,主线程跑被测客户端;两边都结束后把内核那侧的失败抛出来。
    private func withFakeKernel(
        configuration: A2KernelClient.Configuration = A2KernelClient.Configuration(requestTimeout: 5),
        kernel kernelScript: @escaping (FakeKernel) throws -> Void,
        client clientScript: (A2KernelClient) throws -> Void
    ) throws {
        let fake = try FakeKernel()
        let client = A2KernelClient(
            transport: A2UnixSocketTransport.adopting(fd: fake.clientFD), configuration: configuration)
        let finished = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        let thread = Thread {
            do { try kernelScript(fake) } catch { box.store(error) }
            finished.signal()
        }
        thread.name = "fake-a2-kernel"
        thread.start()
        defer {
            client.close()
            fake.close()
        }
        try clientScript(client)
        // 只等**一次**(信号量只会被 signal 一次;在 defer 里再等一遍 = 每条用例白白多花几秒)。
        #expect(finished.wait(timeout: .now() + 15) == .success, "假内核那侧没在 15 秒内收场")
        if let error = box.take() {
            Issue.record("假内核那侧失败:\(error)")
        }
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func store(_ value: Error) { lock.lock(); error = value; lock.unlock() }
        func take() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
    }

    /// 一份真快照的注册回执(读金标,不手捏;**用 Foundation 的对象,不经被测类型**)。
    private func registerResult(connection: String = "conn-1") throws -> [String: Any] {
        [
            "role": "confirm-agent",
            "connection": connection,
            "uid": 501,
            "roles": ["confirm-agent"],
            "snapshot": try GoldenFixtures.object("kernel-snapshot.json"),
        ]
    }

    // MARK: - 注册即快照

    @Test("roles.register:一次往返拿回全量快照(没有「注册成功但还没拿到状态」的中间态)")
    func registrationReturnsSnapshotInSameRoundTrip() throws {
        try withFakeKernel { kernel in
            let request = try kernel.readRequest()
            #expect(request.string("op") == "roles.register")
            #expect(request.child("params")?.string("role") == "confirm-agent")
            #expect(request.child("params")?.child("identity")?.string("name") == "a2-panel")
            try kernel.writeSuccess(id: request.string("id") ?? "", result: try self.registerResult())
        } client: { client in
            let result = try client.registerRole(
                .confirmAgent, identity: A2ClientIdentity(name: "a2-panel", version: "1.0.0"))
            #expect(result.role == .confirmAgent)
            #expect(result.connection == "conn-1")
            #expect(result.uid == 501)
            #expect(result.snapshot.status.version == "0.1.0")
            #expect(result.snapshot.capabilities.count == 2)
            #expect(result.snapshot.arbitration.confirmerPresent)
            #expect(result.snapshot.supervision.watching)
            #expect(result.snapshot.audit.first?.action == .confirmerJoined)
            #expect(client.bufferedPushes.isEmpty, "注册往返里不该混进推送")
        }
    }

    // MARK: - 相关性与推送分流

    @Test("响应按 id 认领:先到的推送不会被当成答案,而且不丢")
    func pushesBeforeResponseAreQueuedNotMistakenForIt() throws {
        try withFakeKernel { kernel in
            let request = try kernel.readRequest()
            try kernel.writePush(event: try GoldenFixtures.event(of: "push-arbitration.json"))
            try kernel.writePush(event: try GoldenFixtures.event(of: "push-audit-denied.json"))
            try kernel.writeSuccess(id: request.string("id") ?? "", result: try self.registerResult())
        } client: { client in
            let result = try client.registerRole(.subscriber, identity: A2ClientIdentity(name: "a2-panel"))
            #expect(result.connection == "conn-1")
            #expect(client.bufferedPushes.count == 2, "等响应期间到达的推送被丢了")

            let audit = try client.nextPush(timeout: 5) { $0.event.kind == .audit }
            guard case let .audit(_, event) = audit.event else { Issue.record("取错了事件族"); return }
            #expect(event.action == .denied)
            // 按条件挑走一条,其余仍在队里(顺序不因挑选而乱)。
            #expect(client.bufferedPushes.count == 1)
            #expect(client.bufferedPushes.first?.event.kind == .arbitration)
        }
    }

    @Test("id 对不上的响应是协议违例(绝不静默当成自己的答案)")
    func mismatchedResponseIdIsAProtocolViolation() throws {
        try withFakeKernel { kernel in
            _ = try kernel.readRequest()
            try kernel.writeSuccess(id: "别人的请求-id", result: [String: Any]())
        } client: { client in
            #expect(throws: A2ClientError.self) {
                _ = try client.request(op: A2KernelClient.Op.statusGet)
            }
        }
    }

    // MARK: - 确认窗口顺延

    @Test("confirmation-pending 把等待窗口顺延到内核承诺的时长")
    func confirmationPendingExtendsTheDeadline() throws {
        // 判据差给足:默认只等 0.5 秒,内核拖 1.5 秒才回 —— 没有那条 pending 推送必超时;
        // 有了它,截止时间被推到 6 + 1 = 7 秒之后,余量 5.5 秒,调度抖动影响不到判定。
        try withFakeKernel(
            configuration: A2KernelClient.Configuration(requestTimeout: 0.5, pendingGrace: 1.0)
        ) { kernel in
            let request = try kernel.readRequest()
            var event = try GoldenFixtures.event(of: "push-confirmation-pending.json")
            event["requestId"] = request.string("id") ?? ""
            event["timeoutMs"] = 6000
            try kernel.writePush(event: event)
            Thread.sleep(forTimeInterval: 1.5)
            try kernel.writeSuccess(
                id: request.string("id") ?? "",
                result: ["capability": "demo.wipe", "output": [String: Any]()])
        } client: { client in
            let response = try client.callCapability("demo.wipe")
            #expect(response.isOK, "内核承诺了 6 秒窗口,客户端却没等到底")
            #expect(client.bufferedPushes.first?.event.kind == .confirmationPending)
        }
    }

    @Test("反证:没有 confirmation-pending 时,同样的拖延就是超时")
    func withoutPendingPushTheSameDelayTimesOut() throws {
        try withFakeKernel(
            configuration: A2KernelClient.Configuration(requestTimeout: 0.5, pendingGrace: 1.0)
        ) { kernel in
            let request = try kernel.readRequest()
            Thread.sleep(forTimeInterval: 1.5)
            // 客户端此时已经放弃;写不写得进去都不影响断言(连接可能已关)。
            try? kernel.writeSuccess(id: request.string("id") ?? "", result: [String: Any]())
        } client: { client in
            #expect(throws: A2ClientError.self) {
                _ = try client.callCapability("demo.wipe")
            }
        }
    }

    // MARK: - 字节边界

    @Test("响应在多字节字符中间被切成两段:整帧照样解得开")
    func responseSplitInsideMultibyteCharacterStillDecodes() throws {
        try withFakeKernel { kernel in
            let request = try kernel.readRequest()
            let bytes = try FakeKernel.frameBytes([
                "v": 1, "id": request.string("id") ?? "", "ok": true,
                "result": try self.registerResult(),
            ])
            // 找一个三字节字符(快照里全是中文),在它的第 1 与第 2 字节之间切开。
            guard let lead = bytes.firstIndex(where: { $0 >= 0xE0 }) else {
                throw FakeKernel.FakeKernelError.setupFailed("样本里没有多字节字符,这条断言就白写了")
            }
            try kernel.writeRaw(Array(bytes[0...lead]))
            Thread.sleep(forTimeInterval: 0.05)
            try kernel.writeRaw(Array(bytes[(lead + 1)...]))
        } client: { client in
            let result = try client.registerRole(.confirmAgent, identity: A2ClientIdentity(name: "a2-panel"))
            #expect(result.snapshot.capabilities.contains { $0.id == "proxy.subscription.add" })
            #expect(result.snapshot.audit.first?.detail?.contains("同 UID 冒充") == true,
                    "中文被切碎了 —— 说明拆行是按字符做的,不是按字节")
        }
    }

    // MARK: - 确认往返与拒绝

    @Test("confirmations.resolve:决定发得出去,回执解得开")
    func resolveRoundTrip() throws {
        try withFakeKernel { kernel in
            let request = try kernel.readRequest()
            #expect(request.string("op") == "confirmations.resolve")
            #expect(request.child("params")?.string("decision") == "approve")
            #expect(request.child("params")?.string("reason") == "我认得这个源")
            try kernel.writeSuccess(
                id: request.string("id") ?? "",
                result: try GoldenFixtures.object("confirmation-resolve-result.json"))
        } client: { client in
            let result = try client.resolveConfirmation(
                "018f3b1c-1111-7c3e-9f2b-1d4e5f6a7b8d", decision: .approve, reason: "我认得这个源")
            #expect(result.decision == .approve)
            #expect(result.settled)
        }
    }

    @Test("内核回失败包封:抛 kernelRefused,理由与指引原样带着")
    func failureEnvelopeSurfacesGuidance() throws {
        try withFakeKernel { kernel in
            let request = try kernel.readRequest()
            try kernel.writeFailure(
                id: request.string("id") ?? "",
                error: try GoldenFixtures.object("confirmation-error-unavailable.json"))
        } client: { client in
            do {
                _ = try client.registerRole(.confirmAgent, identity: A2ClientIdentity(name: "a2-panel"))
                Issue.record("失败包封没有变成错误")
            } catch let A2ClientError.kernelRefused(error) {
                #expect(error.code == A2ErrorCode.confirmationUnavailable)
                #expect(error.guidance?.steps.isEmpty == false, "「拒绝即指引」丢了")
                #expect(error.guidance?.steps.first?.command == "open -a \"A2 Panel\"")
            }
        }
    }

    @Test("连接断了就是断了:不装作超时,也不假装还能用")
    func closedConnectionSurfaces() throws {
        let fake = try FakeKernel()
        let client = A2KernelClient(transport: A2UnixSocketTransport.adopting(fd: fake.clientFD))
        fake.close()
        #expect(throws: A2ClientError.self) {
            _ = try client.request(op: A2KernelClient.Op.statusGet)
        }
        client.close()
    }
}
