// 09 票 —— 镜像自身的不变量(金标遍历之外的手写断言)。
//
// 金标那组能保证"同一批字节两侧读法一致";但有几条**语义**不体现在任何单个样本里:
//   * 帧判别是**结构性**的(有 ok 是响应,有 push 是推送,永不同现);
//   * 可选字段缺省时必须**整个键不出现** —— zod 的 `.optional()` **不收 null**,
//     编成 `"version": null` 会被内核当场拒;
//   * `ConfirmationError` 与 `WireError` 是**同一批字节的两种读法**,收窄版必须真的更窄;
//   * 「要写出去」的那两类报文(注册、决定)编出来必须**逐字段等于金标**,否则内核那侧解不动。
//
// 这些断言的期望值都来自契约原文与金标,不是把镜像代码再算一遍。

import Foundation
import Testing
@testable import A2Contract

@Suite("09 契约镜像不变量")
struct MirrorInvariantTests {

    private func golden(_ name: String) throws -> Data {
        try Data(contentsOf: GoldenSampleLoader.goldenDirectory.appendingPathComponent(name))
    }

    private func json(_ data: Data) throws -> A2JSON {
        try JSONDecoder().decode(A2JSON.self, from: data)
    }

    // MARK: - 帧判别

    @Test("帧判别是结构性的:有 ok 是响应,有 push 是推送")
    func serverFrameDiscrimination() throws {
        let response = try JSONDecoder().decode(A2ServerFrame.self, from: golden("response-status-ok.json"))
        guard case .response = response else {
            Issue.record("带 ok 的帧没被认成响应"); return
        }
        let push = try JSONDecoder().decode(A2ServerFrame.self, from: golden("push-arbitration.json"))
        guard case .push = push else {
            Issue.record("带 push 的帧没被认成推送"); return
        }
    }

    @Test("ok 与 push 同现的帧必须被拒(它们永不同现)")
    func frameWithBothDiscriminatorsIsRejected() throws {
        let bytes = Data(#"{"v":1,"id":"x","ok":true,"push":true,"result":null}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(A2ServerFrame.self, from: bytes)
        }
    }

    @Test("两个判别字段都没有的帧必须被拒(不是本协议的帧)")
    func frameWithNeitherDiscriminatorIsRejected() throws {
        let bytes = Data(#"{"v":1,"id":"x","event":{"kind":"audit"}}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(A2ServerFrame.self, from: bytes)
        }
    }

    @Test("请求帧不是服务端帧:客户端自己发出去的东西不会被当成响应")
    func requestIsNotAServerFrame() throws {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(A2ServerFrame.self, from: self.golden("request-status-get.json"))
        }
    }

    // MARK: - 可选字段的编码口径

    @Test("可选字段缺省时整个键不出现(zod 的 optional 不收 null)")
    func absentOptionalsAreOmittedNotNulled() throws {
        let identity = A2ClientIdentity(name: "a2-panel")
        let encoded = try json(try JSONEncoder().encode(identity))
        #expect(encoded == .object(["name": .string("a2-panel")]),
                "身份只填了 name,编码结果却不是单键对象:\(encoded)")

        let guidance = A2Guidance(summary: "s", steps: [A2GuidanceStep(description: "d")])
        let guidanceJSON = try json(try JSONEncoder().encode(guidance))
        guard let members = guidanceJSON.objectValue else {
            Issue.record("指引编出来不是对象"); return
        }
        #expect(members["context"] == nil, "缺省的 context 被编成了 null / 空对象:\(guidanceJSON)")
        #expect(members["steps"]?.objectValue == nil)
    }

    // MARK: - 要写出去的两类报文

    @Test("roles.register 的 params 编出来逐字段等于金标")
    func roleRegisterParamsMatchGolden() throws {
        let params = A2RoleRegisterParams(
            role: .confirmAgent,
            identity: A2ClientIdentity(
                name: "a2-panel",
                version: "1.0.0",
                codeDirectoryHash: "预留字段:V1 内核收下但不校验",
                teamIdentifier: "预留字段:V1 内核收下但不校验"))
        let encoded = try json(try JSONEncoder().encode(params))
        let expected = try json(try golden("role-register-params.json"))
        #expect(encoded == expected, "注册报文与金标不一致:\(encoded)")
    }

    @Test("confirmations.resolve 的 params 编出来逐字段等于金标")
    func confirmationResolveParamsMatchGolden() throws {
        let params = A2ConfirmationResolveParams(
            confirmation: "018f3b1c-1111-7c3e-9f2b-1d4e5f6a7b8d",
            decision: .deny,
            reason: "这个源我不认识")
        let encoded = try json(try JSONEncoder().encode(params))
        let expected = try json(try golden("confirmation-resolve-params.json"))
        #expect(encoded == expected, "决定报文与金标不一致:\(encoded)")
    }

    // MARK: - ConfirmationError 是 WireError 的收窄版

    @Test("仲裁三码:同一批字节既是 WireError 也是 ConfirmationError")
    func confirmationErrorIsANarrowingOfWireError() throws {
        let bytes = try golden("confirmation-error-unavailable.json")
        let wide = try JSONDecoder().decode(A2WireError.self, from: bytes)
        let narrow = try JSONDecoder().decode(A2ConfirmationError.self, from: bytes)
        #expect(wide.code == narrow.code)
        #expect(wide.guidance == narrow.guidance)
        #expect(A2ErrorCode.confirmationCodes.contains(narrow.code))
    }

    @Test("缺 guidance 的仲裁码:WireError 收得下,ConfirmationError 必须拒")
    func confirmationErrorRequiresGuidance() throws {
        let bytes = try golden("invalid-confirmation-error-missing-guidance.json")
        // 包封层是宽的(`unknown_op` 这类本来就没有指引可言)——这条解得动是**对的**。
        let wide = try JSONDecoder().decode(A2WireError.self, from: bytes)
        #expect(wide.guidance == nil)
        // 收窄版必须拒:「拒绝即指引」在这一层是强制的。
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(A2ConfirmationError.self, from: bytes)
        }
    }

    // MARK: - 六族事件

    /// 这条断言的期望值是**手写的字面量**,所以每加一族都得有人来改它 —— 那正是它存在的意义:
    /// 事件族是壳的状态机依据,多一族少一族都该是一次**可审阅的动作**,而不是随手加个 case 就过去了。
    /// (11 票加了第七族 `capability-set`:能力全集变了。)
    @Test("增量事件恰好七族,判别值逐字对齐契约")
    func kernelEventFamiliesAreExactlySeven() {
        let kinds = Set(A2KernelEventKind.allCases.map(\.rawValue))
        #expect(kinds == [
            "arbitration", "confirmation", "confirmation-pending", "audit", "supervision", "capability",
            "capability-set",
        ], "事件族变了:\(kinds.sorted())")
    }

    @Test("七份推送金标各自落到正确的事件族")
    func pushGoldensMapToTheirFamily() throws {
        let expectations: [(file: String, kind: A2KernelEventKind)] = [
            ("push-arbitration.json", .arbitration),
            ("push-confirmation.json", .confirmation),
            ("push-confirmation-pending.json", .confirmationPending),
            ("push-audit-denied.json", .audit),
            ("push-supervision-down.json", .supervision),
            ("push-capability.json", .capability),
            ("push-capability-set.json", .capabilitySet),
        ]
        for expectation in expectations {
            let push = try JSONDecoder().decode(A2PushEnvelope.self, from: golden(expectation.file))
            #expect(push.event.kind == expectation.kind,
                    "\(expectation.file) 落到了 \(push.event.kind.rawValue)")
            #expect(!push.event.at.isEmpty)
        }
    }

    @Test("确认请求带真实入参,待确认项则没有 input(input 只给确认器)")
    func onlyConfirmationRequestCarriesInput() throws {
        let request = try JSONDecoder().decode(A2ConfirmationRequest.self, from: golden("confirmation-request.json"))
        #expect(request.input.isEmpty == false, "确认请求必须带真实入参,人类要亲眼核对")
        #expect(request.descriptor.risk == .dangerous)

        // `PendingConfirmation` 是发给全体订阅者的坐标,**结构上就没有 input 这个成员** ——
        // 这条断言靠"金标里的待确认项能原样往返"来守:若哪天契约给它加了 input,往返会先红。
        let pendingBytes = try golden("pending-confirmation.json")
        let pending = try JSONDecoder().decode(A2PendingConfirmation.self, from: pendingBytes)
        let reencoded = try JSONEncoder().encode(pending)
        #expect(try json(reencoded) == (try json(pendingBytes)))
        #expect(pending.risk == .dangerous)
    }

    // MARK: - 协议版本

    @Test("编出去的包封恒带 v=1")
    func encodedEnvelopesCarryProtocolVersion() throws {
        let request = A2RequestEnvelope(id: "req-1", op: "status.get")
        let encoded = try json(try JSONEncoder().encode(request))
        #expect(encoded.objectValue?["v"] == .int(A2Protocol.version))
        #expect(A2Protocol.version == 1, "线协议版本是 1;真要 +1 是一次不兼容变更,得两侧一起改")
    }
}
