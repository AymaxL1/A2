// 09 票 —— **封闭词表**的双端对账(金标样本盖不到的那一格)。
//
// 金标样本能抓"字段形状变了",却抓不到"枚举**多**了一个取值":新取值不会让任何旧样本失效,
// 于是 Swift 侧的 enum 悄悄比契约窄了一格 —— 直到线上真收到那个值,解码当场失败(壳会把整帧丢掉)。
// 这不是假想:08 票 CR 就往 `AuditAction` 里加了三个取值(cancelled / peer_unverified /
// backpressure_dropped),提交信息里专门写了一句「09 票需同步」—— **靠人记得看提交信息不算门禁**。
//
// 判据取 `kernel/contract/schema/*.schema.json`:那是 TS 契约的机器可读导出物(`bun run schema` 生成、
// 入库、TS 侧有"导出物与源同步"的断言守着)。于是这一组盯的是同一条链的下游:
//   zod 源 →(TS 断言)→ JSON Schema 导出物 →(**本组断言**)→ Swift enum。
//
// **fail-closed**:词表在 schema 里找不到 → 报错,不是"那就跳过"。

import Foundation
import Testing
@testable import A2Contract

@Suite("09 封闭词表对账(JSON Schema ↔ Swift enum)")
struct SchemaVocabularyTests {

    static var schemaDirectory: URL {
        GoldenSampleLoader.repositoryRoot.appendingPathComponent("kernel/contract/schema", isDirectory: true)
    }

    private func schema(_ file: String) throws -> A2JSON {
        let url = Self.schemaDirectory.appendingPathComponent(file)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw GoldenSampleLoader.LoadError.missingSample(url.path)
        }
        return try JSONDecoder().decode(A2JSON.self, from: data)
    }

    /// 在一份 JSON Schema 里递归找名为 `property` 的属性,收集它声明的 `enum` 取值域。
    /// 同名属性可能出现在多处(嵌套类型);**每一处的取值域都要与 Swift 侧一致**,所以返回全部,由调用方逐个比。
    private func enums(of property: String, in node: A2JSON) -> [Set<String>] {
        var found: [Set<String>] = []
        switch node {
        case let .object(members):
            if case let .object(properties)? = members["properties"],
               case let .object(target)? = properties[property],
               case let .array(values)? = target["enum"] {
                found.append(Set(values.compactMap(\.stringValue)))
            }
            for value in members.values { found.append(contentsOf: enums(of: property, in: value)) }
        case let .array(items):
            for item in items { found.append(contentsOf: enums(of: property, in: item)) }
        default:
            break
        }
        return found
    }

    /// 同上,但收的是判别用的 `const`(`z.literal` 导出成 const,判别联合的每一支各一个)。
    private func consts(of property: String, in node: A2JSON) -> Set<String> {
        var found: Set<String> = []
        switch node {
        case let .object(members):
            if case let .object(properties)? = members["properties"],
               case let .object(target)? = properties[property],
               case let .string(value)? = target["const"] {
                found.insert(value)
            }
            for value in members.values { found.formUnion(consts(of: property, in: value)) }
        case let .array(items):
            for item in items { found.formUnion(consts(of: property, in: item)) }
        default:
            break
        }
        return found
    }

    /// 一个词表在 schema 里的每一处出现都必须与 Swift 侧逐字相等;一处都找不到也是红。
    private func expectVocabulary(
        _ expected: Set<String>, of property: String, in file: String,
        _ label: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let occurrences = enums(of: property, in: try schema(file))
        #expect(!occurrences.isEmpty,
                Comment(rawValue: "\(file) 里找不到属性 \(property) 的取值域 —— 契约改形状了?"),
                sourceLocation: sourceLocation)
        for occurrence in occurrences {
            #expect(occurrence == expected,
                    Comment(rawValue: "\(label) 词表漂了:契约 \(occurrence.sorted()),Swift \(expected.sorted())"),
                    sourceLocation: sourceLocation)
        }
    }

    @Test("审计动作词表(08 票 CR 加过三个取值,这条就是为它立的)")
    func auditActionVocabulary() throws {
        try expectVocabulary(
            Set(A2AuditAction.allCases.map(\.rawValue)), of: "action",
            in: "audit-event.schema.json", "AuditAction")
    }

    @Test("角色词表")
    func clientRoleVocabulary() throws {
        try expectVocabulary(
            Set(A2ClientRole.allCases.map(\.rawValue)), of: "role",
            in: "role-register-params.schema.json", "ClientRole")
    }

    @Test("确认决定词表(只有 approve / deny,没有第三种)")
    func confirmationDecisionVocabulary() throws {
        try expectVocabulary(
            Set(A2ConfirmationDecision.allCases.map(\.rawValue)), of: "decision",
            in: "confirmation-resolve-params.schema.json", "ConfirmationDecision")
    }

    @Test("风险三档与参数类型词表")
    func capabilityVocabularies() throws {
        try expectVocabulary(
            Set(A2RiskLevel.allCases.map(\.rawValue)), of: "risk",
            in: "capability-descriptor.schema.json", "RiskLevel")
        try expectVocabulary(
            Set(A2ParameterType.allCases.map(\.rawValue)), of: "type",
            in: "capability-descriptor.schema.json", "ParameterType")
    }

    @Test("存活观测事件与实例归属词表")
    func supervisionVocabularies() throws {
        try expectVocabulary(
            Set(A2SupervisionEventKind.allCases.map(\.rawValue)), of: "kind",
            in: "proxy-supervision-result.schema.json", "SupervisionEventKind")
        try expectVocabulary(
            Set(A2MihomoOwner.allCases.map(\.rawValue)), of: "owner",
            in: "proxy-supervision-result.schema.json", "MihomoOwner")
    }

    @Test("仲裁三码:收窄版错误码的取值域")
    func confirmationErrorCodes() throws {
        try expectVocabulary(
            Set(A2ErrorCode.confirmationCodes), of: "code",
            in: "confirmation-error.schema.json", "ConfirmationError.code")
    }

    @Test("增量事件六族:判别 const 与 Swift enum 逐字相等")
    func kernelEventDiscriminants() throws {
        let discriminants = consts(of: "kind", in: try schema("kernel-event.schema.json"))
        #expect(discriminants == Set(A2KernelEventKind.allCases.map(\.rawValue)),
                Comment(rawValue: "事件族漂了:契约 \(discriminants.sorted())"))
    }

    @Test("守卫自身可信:找不到的属性必须报告为空,不是静默通过")
    func walkerDoesNotSilentlySucceed() throws {
        let occurrences = enums(of: "根本不存在的属性名", in: try schema("audit-event.schema.json"))
        #expect(occurrences.isEmpty, "走查器把不存在的属性也找出来了 —— 那它说的话就不能信了")
    }
}
