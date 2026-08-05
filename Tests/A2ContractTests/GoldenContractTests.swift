// 09 票 —— 双端金标门禁的 Swift 半边。
//
// 分层断言,各挡一类漂移:
//   ① **对账**:**已登记契约**(每份 JSON Schema 的 title = `CONTRACT_SCHEMAS` 一条)里的每一个名字,
//      必须落在「已镜像」或「有意不镜像」两张表之一 —— 有人加了新报文族而 Swift 没跟,这一条当场红。
//      **全集刻意不取金标清单**:清单只列有样本的,新契约"配了 schema 还没配样本"会整个溜过去
//      (09 票 CR 抓到的盲区)。已登记但无样本的,另有一张带理由的记账表管着(空表最好)。
//   ② **合法样本**:凡在镜像范围内的,必须解得动,且**往返后语义等价**(逐字段相等,不比键序)。
//      少认一个字段、把 int 收成 double、把可选字段编成 null —— 都会在这一条上吵起来。
//   ③ **非法样本**:必须解不动。invalid 金标是 TS 侧一条条为契约约束造的(空 steps、未知 kind、
//      缺 guidance……),Swift 侧解得动就说明镜像比契约松,那种松是会伤到人的。

import Foundation
import Testing
@testable import A2Contract

@Suite("09 金标契约对照(Swift 侧)")
struct GoldenContractTests {

    /// 消费下限:防"清单被砍了一半而断言照样全绿"。
    /// **只判下限**(与门禁里 swift test 用例数棘轮同一口径);加样本只管加,要调低必须是有意为之。
    static let minimumValidSamples = 36
    static let minimumInvalidSamples = 11

    // MARK: - ① 对账

    @Test("金标清单读得到,样本非空")
    func indexIsReadable() throws {
        let index = try GoldenSampleLoader.loadIndex()
        #expect(index.samples.count > 0, "金标清单是空的 —— 这批断言等于没跑")
    }

    @Test("已登记契约全集 ≡ 已镜像 ∪ 有意不镜像(新增契约没跟即红)")
    func coverageTablePartitionsTheRegistry() throws {
        // **全集取「已登记契约」(每份 JSON Schema 的 title),不是金标清单** ——
        // 后者只列有样本的,拿它当全集,"配了 schema 还没配样本"的新契约会整个溜过去(CR 抓到的盲区)。
        let registered = try GoldenSampleLoader.registeredContracts()
        let mirrored = A2ContractCoverage.mirrored
        let unmirrored = A2ContractCoverage.unmirrored

        // 两张表不许重叠:同一个契约不能既说镜像了又说不镜像。
        #expect(mirrored.isDisjoint(with: unmirrored),
                "镜像表与豁免表有交集:\(mirrored.intersection(unmirrored).sorted())")

        let unclassified = registered.subtracting(mirrored).subtracting(unmirrored)
        let unclassifiedMessage = "已登记契约里出现了两张表都没登记的 \(unclassified.sorted()) —— "
            + "要么在 A2Contract 里建镜像,要么写进 A2UnmirroredContract 并给出理由"
        #expect(unclassified.isEmpty, Comment(rawValue: unclassifiedMessage))

        // 反向:表里登记了、契约登记表里却查无此名(改名/删除)。
        let ghostsInMirror = mirrored.subtracting(registered)
        #expect(ghostsInMirror.isEmpty,
                "镜像表登记了已登记契约里不存在的名字 \(ghostsInMirror.sorted()) —— 契约改名了?")
        let ghostsInExemptions = unmirrored.subtracting(registered)
        #expect(ghostsInExemptions.isEmpty,
                "豁免表登记了已登记契约里不存在的名字 \(ghostsInExemptions.sorted())")
    }

    @Test("金标清单里的每个 schema 名都是已登记契约(样本不许指向查无此名的契约)")
    func everyIndexedSchemaIsRegistered() throws {
        let registered = try GoldenSampleLoader.registeredContracts()
        let listed = Set(try GoldenSampleLoader.loadIndex().samples.map(\.schema))
        #expect(listed.subtracting(registered).isEmpty,
                "金标清单指向了没有 JSON Schema 的契约 \(listed.subtracting(registered).sorted())")
    }

    @Test("已登记但一份样本都没有的契约,必须显式记账(空表最好)")
    func registeredContractsWithoutSamplesAreAccountedFor() throws {
        let registered = try GoldenSampleLoader.registeredContracts()
        let listed = Set(try GoldenSampleLoader.loadIndex().samples.map(\.schema))
        let withoutSamples = registered.subtracting(listed)
        let accounted = Set(A2ContractCoverage.registeredWithoutGoldenSample.keys)
        let message = "「已登记但无金标样本」的清单变了:实际 \(withoutSamples.sorted()),"
            + "记账 \(accounted.sorted())。"
            + "补了样本 → 把那条账删掉(白捡一份静态覆盖);新契约还没配样本 → 补样本,或把理由写进记账表。"
        #expect(withoutSamples == accounted, Comment(rawValue: message))
        for (name, reason) in A2ContractCoverage.registeredWithoutGoldenSample {
            #expect(!reason.isEmpty, "\(name) 记了账却没写理由")
        }
    }

    @Test("每个已镜像契约都有合法金标样本(没有的必须在记账表里)")
    func everyMirroredContractHasAValidSample() throws {
        let index = try GoldenSampleLoader.loadIndex()
        let schemasWithValidSample = Set(index.samples.filter(\.isValid).map(\.schema))
        let uncovered = A2ContractCoverage.mirrored.subtracting(schemasWithValidSample)
        let accounted = Set(A2ContractCoverage.registeredWithoutGoldenSample.keys)
        let message = "这些已镜像契约没有合法样本、也没记账:\(uncovered.subtracting(accounted).sorted())"
        #expect(uncovered.subtracting(accounted).isEmpty, Comment(rawValue: message))
    }

    @Test("金标目录与清单双向对齐:没有没登记的孤儿样本")
    func noOrphanSampleFiles() throws {
        let index = try GoldenSampleLoader.loadIndex()
        let listed = Set(index.samples.map(\.file))
        let onDisk = Set(try GoldenSampleLoader.filesOnDisk())
        #expect(onDisk.subtracting(listed).isEmpty,
                "金标目录里有没登记进清单的样本 \(onDisk.subtracting(listed).sorted()) —— 它们永远不会被任何一侧跑到")
        #expect(listed.subtracting(onDisk).isEmpty,
                "清单里有指向不存在文件的条目 \(listed.subtracting(onDisk).sorted())")
    }

    // MARK: - ② 合法样本:解得动 + 往返语义等价

    @Test("合法金标:镜像范围内的样本全部解得动,且往返后逐字段不变")
    func validSamplesRoundTrip() throws {
        let index = try GoldenSampleLoader.loadIndex()
        var consumed = 0
        for sample in index.samples where sample.isValid {
            guard let contract = A2MirroredContract(rawValue: sample.schema) else { continue }
            consumed += 1
            let original = try GoldenSampleLoader.loadSample(sample)
            do {
                let reencoded = try contract.decodeThenReencode(original)
                let before = try JSONDecoder().decode(A2JSON.self, from: original)
                let after = try JSONDecoder().decode(A2JSON.self, from: reencoded)
                let drift = "\(sample.file)(\(sample.schema))往返后变了形:\(sample.why)\n"
                    + "原样本: \(String(decoding: original, as: UTF8.self))\n"
                    + "往返后: \(String(decoding: reencoded, as: UTF8.self))"
                #expect(before == after, Comment(rawValue: drift))
            } catch {
                Issue.record("\(sample.file)(\(sample.schema))解不动:\(error)\n理由栏写着:\(sample.why)")
            }
        }
        #expect(consumed >= Self.minimumValidSamples,
                "镜像范围内的合法样本只跑到 \(consumed) 份,低于下限 \(Self.minimumValidSamples)")
    }

    // MARK: - ③ 非法样本:必须被拒

    @Test("非法金标:镜像范围内的样本必须解不动(镜像不许比契约松)")
    func invalidSamplesAreRejected() throws {
        let index = try GoldenSampleLoader.loadIndex()
        var consumed = 0
        for sample in index.samples where !sample.isValid {
            guard let contract = A2MirroredContract(rawValue: sample.schema) else { continue }
            consumed += 1
            let data = try GoldenSampleLoader.loadSample(sample)
            #expect(throws: (any Error).self,
                    "\(sample.file)(\(sample.schema))本该被拒却解开了 —— \(sample.why)") {
                _ = try contract.decodeThenReencode(data)
            }
        }
        #expect(consumed >= Self.minimumInvalidSamples,
                "镜像范围内的非法样本只跑到 \(consumed) 份,低于下限 \(Self.minimumInvalidSamples)")
    }

    // MARK: - 豁免表的理由不许是空话

    @Test("每条豁免都写了理由")
    func everyExemptionHasAReason() {
        for contract in A2UnmirroredContract.allCases {
            #expect(!contract.reason.isEmpty, "\(contract.rawValue) 没写不镜像的理由")
        }
    }
}
