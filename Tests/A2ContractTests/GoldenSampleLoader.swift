// 09 票 —— 金标样本的读取与对账口径(双端门禁的 Swift 半边)。
//
// 事实源是**同一批文件**:`kernel/contract/golden/`。TS 侧 `bun test` 读它做 zod 解析 + 往返;
// Swift 侧读它做手写 Codable 解码 + 往返。谁改了契约而另一侧没跟,门禁当场红。
//
// **路径怎么来的**:`#filePath` 往上三级就是仓库根 —— 不经环境变量注入。
//   既有的 `AA_SPIKE_DIR` 那套是 `Scripts/check/swift-test.sh` 注入的,而 09 票是 expand 半步,
//   **check.sh 一行不改**是硬约束,所以这里不能要求门禁多喂一个变量。
//   代价是"测试文件不能随便挪位置",换来的是"这批断言**不依赖任何环境注入**,裸 `swift test` 也成立"。
//   (并发口径另说:本套件只读文件、无共享可变状态,默认并行与 `--no-parallel` 下都成立;
//    真正对调度敏感的是客户端那套,它自己解决,见 `A2KernelClientProtocolTests` 头注。)
//
// **fail-closed**:目录不在、清单读不出、样本文件缺失 —— 一律让用例红,绝不静默跳过。
// 这条与 ClaudeAdapterTests 的口径一致(那边缺变量就直接红,不装作没有样本可测)。

import Foundation

enum GoldenSampleLoader {

    struct Sample: Decodable, Sendable {
        let file: String
        let schema: String
        let kind: String
        let why: String

        var isValid: Bool { kind == "valid" }
    }

    struct Index: Decodable, Sendable {
        let samples: [Sample]
    }

    /// 仓库根:本文件位于 `<root>/Tests/A2ContractTests/GoldenSampleLoader.swift`。
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // A2ContractTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <root>
    }

    static var goldenDirectory: URL {
        repositoryRoot.appendingPathComponent("kernel/contract/golden", isDirectory: true)
    }

    enum LoadError: Error, CustomStringConvertible {
        case missingDirectory(String)
        case unreadableIndex(String)
        case missingSample(String)

        var description: String {
            switch self {
            case let .missingDirectory(path): return "金标目录不在:\(path)"
            case let .unreadableIndex(detail): return "金标清单读不出:\(detail)"
            case let .missingSample(path): return "清单里登记的样本文件不在:\(path)"
            }
        }
    }

    /// 读清单。目录/清单任一读不出即抛(fail-closed)。
    static func loadIndex() throws -> Index {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: goldenDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LoadError.missingDirectory(goldenDirectory.path)
        }
        let indexURL = goldenDirectory.appendingPathComponent("index.json")
        do {
            let data = try Data(contentsOf: indexURL)
            return try JSONDecoder().decode(Index.self, from: data)
        } catch {
            throw LoadError.unreadableIndex("\(indexURL.path):\(error)")
        }
    }

    /// 读一份样本的原始字节。
    static func loadSample(_ sample: Sample) throws -> Data {
        let url = goldenDirectory.appendingPathComponent(sample.file)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw LoadError.missingSample(url.path)
        }
        return data
    }

    /// 磁盘上的全部样本文件名(不含 `index.json`)。
    static func filesOnDisk() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: goldenDirectory.path)
        return names.filter { $0.hasSuffix(".json") && $0 != "index.json" }.sorted()
    }

    // MARK: - 已登记契约(CONTRACT_SCHEMAS 的导出物)

    static var schemaDirectory: URL {
        repositoryRoot.appendingPathComponent("kernel/contract/schema", isDirectory: true)
    }

    /// **已登记契约的全集** —— `kernel/contract/schema/` 里每份文件的 `title`。
    ///
    /// 为什么这才是全集,而不是金标清单:`emit.ts` 的 `CONTRACT_SCHEMAS` 一条对应一份 schema 文件
    /// (TS 侧有"导出物与源逐字同步"的断言守着),而金标清单只列**有样本的**那些 ——
    /// 拿它当全集,"新契约配了 schema 却还没配样本"就会从所有断言底下溜过去(09 票 CR 抓到的盲区)。
    static func registeredContracts() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: schemaDirectory.path)
            .filter { $0.hasSuffix(".schema.json") }
        guard !names.isEmpty else {
            throw LoadError.missingDirectory("\(schemaDirectory.path)(一份 schema 都没有)")
        }
        var titles: Set<String> = []
        for name in names {
            let url = schemaDirectory.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: url.path),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["title"] as? String, !title.isEmpty else {
                throw LoadError.unreadableIndex("\(url.path):取不到 title(schema 形状变了?)")
            }
            titles.insert(title)
        }
        return titles
    }
}
