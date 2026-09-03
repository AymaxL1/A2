// 03 票 —— 四条硬边界的**结构性反向断言**:某些东西必须在壳的 URL 分流代码里**一次都不出现**。
//
// 行为断言(`A2URLForwarderTests`)验的是"现在这版代码怎么走";这一组验的是"后来的人不能怎么写"。
// 两者缺一不可:一条 `if url.contains("claude.ai")` 完全可以在不弄红任何行为断言的情况下混进来 ——
// 它只会让某些 URL 走另一条路,而那正是 ADR 0008 红线明禁的「壳含业务逻辑」。
//
// 读源码的方式与 `Tests/A2ContractTests/GoldenSampleLoader`、`A2BootstrapTests` 同一条:
// `#filePath` 推仓库根,不经环境变量注入(门禁脚本不必喂路径)。
// 记号表是**保守**的:只列那些"要写域名匹配/URL 解析就绕不开"的写法。它挡不住存心绕路的人,
// 但挡得住"顺手加一个小判断"—— 而后者才是这条红线真正会破在的地方。

import Foundation
import Testing

@Suite("03 壳的 URL 分流:四条硬边界的反向断言(源码级)")
struct A2URLRouterBoundaryTests {

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // A2PanelTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <root>
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 「要做域名匹配或 URL 解析就绕不开」的写法。命中任意一条 = 边界①②破了。
    private static let parsingMarkers = [
        "URLComponents",     // 拆 URL 的标准工具
        ".host",             // 取主机名 = 准备按域名判断
        ".scheme",           // 取 scheme = 准备按协议判断
        ".pathComponents",
        "hasSuffix",         // 后缀匹配正是 routedDomains 的判据形状
        "hasPrefix",
        "lowercased()",      // 域名比较前的规范化
        "routedDomains",     // 内核那张表的名字:壳里出现即抄了一份
        "claude.ai",         // 缺省分流域名:壳里出现即写死了一条业务规则
        "Roxy",              // 分流目的地:壳压根不该知道有这么个东西
    ]

    /// 「壳去读内核的配置文件」就绕不开的写法。命中任意一条 = 边界④破了。
    private static let kernelFileMarkers = [
        "url-router.json",
        "A2_HOME",
        "FileManager",
        "contentsOfFile",
        "Data(contentsOf",
    ]

    @Test("03 边界①②:壳的转发/兜底逻辑里没有任何 URL 解析或域名匹配的写法")
    func policyLayerParsesNothing() throws {
        // 纯逻辑那一层(策略全在这里)+ 会话里那段转发(它只把字符串装进 input)。
        for file in ["Sources/A2Panel/A2URLForwarder.swift", "Sources/A2Panel/A2PanelSession.swift"] {
            let text = try Self.source(file)
            for marker in Self.parsingMarkers + ["URL(string"] {
                #expect(!text.contains(marker), "\(file) 里出现了 \(marker) —— 壳不解析 URL、不匹配域名")
            }
        }
    }

    @Test("03 边界①②:macOS 那层机械件也只是把字符串交出去(`URL(string:)` 是唯一豁免,且有理由)")
    func macOSLayerOnlyHandsOver() throws {
        let file = "Sources/A2PanelMacOS/A2URLRouterMacOS.swift"
        let text = try Self.source(file)
        for marker in Self.parsingMarkers {
            #expect(!text.contains(marker), "\(file) 里出现了 \(marker) —— 壳不解析 URL、不匹配域名")
        }
        // `URL(string:)` 在这一层是必需的(`NSWorkspace` 的入参类型),但它**只是装箱**:
        // 装进去的与用户点的逐字节相同,壳既不读它的字段也不据此分支。这条豁免在源码里有原文说明。
        #expect(text.contains("URL(string"))
        #expect(text.contains("不是解析 URL 做判断"), "这条豁免必须在源码里写清楚理由")
    }

    @Test("03 边界④:壳的 URL 分流代码里没有任何读内核文件的写法")
    func nothingReadsKernelFiles() throws {
        for file in ["Sources/A2Panel/A2URLForwarder.swift",
                     "Sources/A2PanelMacOS/A2URLRouterMacOS.swift"] {
            let text = try Self.source(file)
            for marker in Self.kernelFileMarkers {
                #expect(!text.contains(marker),
                        "\(file) 里出现了 \(marker) —— 配置知识只能来自内核推送的快照")
            }
        }
    }

    @Test("03 边界③:兜底只有一个触发口(`fallback(_:notify:)`),而它只被两种收场调到")
    func fallbackHasExactlyOneTrigger() throws {
        let text = try Self.source("Sources/A2Panel/A2URLForwarder.swift")
        // 一处定义 + 两处调用(refused / unreachable)。多出一处 = 有人给兜底加了新的触发条件,
        // 那条件必然不是"内核可达与否"(那两种收场已经把它说全了)。
        let occurrences = text.components(separatedBy: "fallback(url").count - 1
        #expect(occurrences == 2, "兜底的调用点应当恰好是 refused 与 unreachable 两处")
        #expect(text.components(separatedBy: "private func fallback(").count - 1 == 1)
    }
}
