// 09 票 CR —— **镜像的松紧必须与 TS 逐一对应**,两个方向都验。
//
// CR 抓到的硬违反:7 处纯 `z.string().optional()`(**没有 min(1)**)被 Swift 收严成"非空可选",
// 于是一条 `detail: ""` 的**合法**帧会被壳当场拒掉、整帧丢弃 —— 那不是更安全,那是自造一次不兼容。
// 镜像的职责是照抄:**收严与放松同样是漂移**。
//
// 金标样本挡不住这一格:样本都是"典型形状",没人会专门造一份 `detail: ""` 的合法样本。
// 所以这一组用**手写的边界报文**来钉:
//   * 契约**没写** min(1) 的地方 → 空串必须**收得下**(松的方向);
//   * 契约**写了** min(1) 的地方 → 空串必须**被拒**(紧的方向)。
// 期望值逐条来自 `kernel/src/contract/wire.ts` 的原文(注释里标了行号语义,不是照抄代码行为)。

import Foundation
import Testing
@testable import A2Contract

@Suite("09 可选字段松紧与契约逐一对应")
struct OptionalStrictnessTests {

    // MARK: - 契约没写 min(1) 的:空串是合法值,必须收得下

    @Test("WireError.detail 是纯 optional:空串收得下")
    func wireErrorDetailAcceptsEmptyString() throws {
        let bytes = Data(#"{"code":"bad_request","message":"你敲错了","detail":""}"#.utf8)
        let error = try JSONDecoder().decode(A2WireError.self, from: bytes)
        #expect(error.detail == "")
    }

    @Test("ConfirmationError.detail 同源同松(它是 WireError 的 extend)")
    func confirmationErrorDetailAcceptsEmptyString() throws {
        let bytes = Data("""
        {"code":"confirmation_denied","message":"被拒了","detail":"",
         "guidance":{"summary":"下一步","steps":[{"description":"再来一次"}]}}
        """.utf8)
        let error = try JSONDecoder().decode(A2ConfirmationError.self, from: bytes)
        #expect(error.detail == "")
    }

    @Test("AuditEvent 的 capability / confirmation / detail 三个纯 optional:空串收得下")
    func auditEventOptionalsAcceptEmptyStrings() throws {
        let bytes = Data("""
        {"at":"2026-08-05T04:10:07.000Z","action":"approved",
         "capability":"","confirmation":"","detail":""}
        """.utf8)
        let event = try JSONDecoder().decode(A2AuditEvent.self, from: bytes)
        #expect(event.capability == "")
        #expect(event.confirmation == "")
        #expect(event.detail == "")
    }

    @Test("ProxyEndpoint.configPath 与监督事件 detail:空串收得下")
    func supervisionOptionalsAcceptEmptyStrings() throws {
        let endpoint = try JSONDecoder().decode(
            A2ProxyEndpoint.self,
            from: Data(#"{"owner":"a2","controller":"127.0.0.1:9097","managed":true,"configPath":""}"#.utf8))
        #expect(endpoint.configPath == "")

        let event = try JSONDecoder().decode(
            A2ProxySupervisionEvent.self,
            from: Data("""
            {"at":"2026-08-05T04:03:15.000Z","kind":"instance_down",
             "controller":"127.0.0.1:9090","owner":"foreign","detail":""}
            """.utf8))
        #expect(event.detail == "")
    }

    @Test("监督结果的 lastCheckAt / lastTransitionAt:空串收得下")
    func supervisionTimestampsAcceptEmptyStrings() throws {
        let result = try JSONDecoder().decode(
            A2ProxySupervisionResult.self,
            from: Data("""
            {"watching":true,"intervalMs":5000,"checks":0,"lastCheckAt":"","lastTransitionAt":"",
             "logPath":"/tmp/x.log","events":[]}
            """.utf8))
        #expect(result.lastCheckAt == "")
        #expect(result.lastTransitionAt == "")
    }

    // MARK: - 契约写了 min(1) 的:空串必须被拒

    @Test("GuidanceStep.command 写了 min(1):空串被拒")
    func guidanceStepCommandRejectsEmptyString() {
        let bytes = Data(#"{"description":"照这条做","command":""}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(A2GuidanceStep.self, from: bytes)
        }
    }

    @Test("ClientIdentity 的三个加固字段写了 min(1):空串被拒")
    func clientIdentityOptionalsRejectEmptyStrings() {
        for key in ["version", "codeDirectoryHash", "teamIdentifier"] {
            let bytes = Data(#"{"name":"a2-panel","\#(key)":""}"#.utf8)
            #expect(throws: (any Error).self, "identity.\(key) 空串该被拒") {
                _ = try JSONDecoder().decode(A2ClientIdentity.self, from: bytes)
            }
        }
    }

    @Test("ConfirmationResolveParams.reason 写了 min(1):空串被拒")
    func resolveReasonRejectsEmptyString() {
        let bytes = Data(#"{"confirmation":"c-1","decision":"deny","reason":""}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(A2ConfirmationResolveParams.self, from: bytes)
        }
    }

    @Test("AuditClient.name 写了 min(1):空串被拒(与同结构体里那三个纯 optional 正好对照)")
    func auditClientNameRejectsEmptyString() {
        let bytes = Data(#"{"role":"confirm-agent","name":"","uid":501}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(A2AuditClient.self, from: bytes)
        }
    }

    // MARK: - 数组的两级约束

    @Test("cliAlias 是 array(string.min(1)).min(1):空数组与空元素都被拒,正常值收得下")
    func cliAliasEnforcesBothLevels() throws {
        let base = #"{"id":"proxy.on","risk":"normal","summary":"开","parameters":[]"#

        let good = try JSONDecoder().decode(
            A2CapabilityDescriptor.self, from: Data((base + #","cliAlias":["proxy","on"]}"#).utf8))
        #expect(good.cliAlias == ["proxy", "on"])

        #expect(throws: (any Error).self, "空数组该被拒(min(1))") {
            _ = try JSONDecoder().decode(
                A2CapabilityDescriptor.self, from: Data((base + #","cliAlias":[]}"#).utf8))
        }
        // 元素级 min(1):混进空串意味着 `a2 proxy "" on` —— 那条命令拼出来就是坏的。
        #expect(throws: (any Error).self, "空元素该被拒(元素级 min(1))") {
            _ = try JSONDecoder().decode(
                A2CapabilityDescriptor.self, from: Data((base + #","cliAlias":["proxy",""]}"#).utf8))
        }
    }

    @Test("allowedValues 只有数组级 min(1)、元素级没有:空数组被拒,空元素收得下")
    func allowedValuesEnforcesOnlyArrayLevel() throws {
        let base = #"{"name":"scope","type":"string","required":false,"description":"作用域""#

        // 元素级契约里**没有** min(1) —— 收严就是漂移,哪怕"空字符串取值域"看起来没道理。
        let spec = try JSONDecoder().decode(
            A2ParameterSpec.self, from: Data((base + #","allowedValues":[""]}"#).utf8))
        #expect(spec.allowedValues == [""])

        #expect(throws: (any Error).self, "空数组该被拒(min(1))") {
            _ = try JSONDecoder().decode(
                A2ParameterSpec.self, from: Data((base + #","allowedValues":[]}"#).utf8))
        }
    }
}
