// 10 票:**壳快照进 swift test**(新门禁四件套的第③件)。
//
// ============================================================================
// 14 票那条 shell 中间层为什么退役
// ============================================================================
// 14 票:`menu-snapshot` 可执行渲染 + 比对,`Scripts/check/menubar.sh` 起它、grep 结论行。
// 本票:门禁口径明写「壳快照(swift test)」,而且 `check.sh` 的整棵 `check/` 在本票退场 ——
//   把比对搬进测试进程,少一处会漂的判据(结论行的文案曾经就是一条隐形契约)。
// 重录 golden 那条路仍在 `a2-panel-snapshot` 可执行里(`AA_SNAPSHOT_RECORD=1`),
//   **门禁永远不传它** —— 否则断言永远为真。
//
// ============================================================================
// 离屏渲染:既有 harness 已踩平的坑,这里循例
// ============================================================================
//   * 像素尺寸显式定死(`rep.size = 像素尺寸` → backing scale 恒为 1),否则 Retina 上尺寸翻倍;
//   * 色彩空间 `.calibratedRGB`(设备无关),否则换机器/换显示描述文件就假红;
//   * 需要一个 `NSApplication` 实例才能完整初始化字体栈,`.prohibited` 保证它不进 Dock。
// 三条全在 `A2MenuSnapshotRenderer` 里,本文件只负责**在主 actor 上**调它。
//
// golden 路径由 `#filePath` 推仓库根(与 09 票 `GoldenSampleLoader` 同一条口径):
//   不经环境变量注入,于是这批断言在任何 `swift test` 下都成立,不必让门禁脚本喂路径。

import AppKit
import Foundation
import Testing
import A2Panel
import A2PanelMacOS
import A2PanelFixtures

@Suite("10 壳快照(渲染器 B:A2MenuModel → PNG,与入库 golden 逐像素 + 逐字节比对)")
@MainActor
struct A2PanelSnapshotTests {

    /// `Tests/A2PanelSnapshotTests/<本文件>` → 仓库根。
    static let goldenDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // A2PanelSnapshotTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Snapshots/a2-panel")
    }()

    @Test("10 快照:每种主要状态逐张与 golden 一致(像素 + 模型文本;17 票起含七条引导分支)",
          arguments: A2PanelFixtures.fixtures.map(\.name))
    func snapshotMatchesGolden(_ name: String) throws {
        let fixture = try #require(A2PanelFixtures.fixtures.first { $0.name == name })
        A2MenuSnapshotRenderer.prepareGraphicsStack()

        let model = A2MenuModelBuilder.build(state: fixture.state, bootstrap: fixture.bootstrap)
        let png = try A2MenuSnapshotRenderer.renderPNG(model)
        let text = model.textSnapshot

        let goldenPNGURL = Self.goldenDirectory.appendingPathComponent("\(name).png")
        let goldenTXTURL = Self.goldenDirectory.appendingPathComponent("\(name).txt")

        // golden 读不出来就是红(fail-closed):没有 golden 的"快照测试"什么都没验。
        let goldenPNG = try Data(contentsOf: goldenPNGURL)
        let goldenText = try String(contentsOf: goldenTXTURL, encoding: .utf8)

        // 文本先比:图片 diff 说不出「哪一行变了」,文本能 —— 失败信息里直接给出差异行。
        #expect(text == goldenText,
                Comment(rawValue: A2MenuSnapshotRenderer.textDiffReport(golden: goldenText, current: text)))

        let diff = try #require(
            A2MenuSnapshotRenderer.comparePNG(png, goldenPNG),
            Comment(rawValue: "PNG 无法比对(解码失败或尺寸不同)—— 当前尺寸 "
                    + "\(A2MenuSnapshotRenderer.pixelSize(for: model))"))
        #expect(diff.over <= A2MenuSnapshotRenderer.allowedOverTolerancePixels,
                Comment(rawValue:
                    "超容差像素 \(diff.over) 个(容差 \(A2MenuSnapshotRenderer.channelTolerance)/255,"
                    + "允许 \(A2MenuSnapshotRenderer.allowedOverTolerancePixels) 个);"
                    + "差异像素 \(diff.diff)/\(diff.total)。"
                    + "文案确实改了就用 `AA_SNAPSHOT_RECORD=1 swift run a2-panel-snapshot` 重录。"))
    }

    @Test("10 快照确定性:同一模型连渲两次逐字节相同(不可重现即为缺陷,不许靠调阈值掩盖)")
    func renderingIsDeterministic() throws {
        A2MenuSnapshotRenderer.prepareGraphicsStack()
        let model = A2MenuModelBuilder.build(state: A2PanelFixtures.mihomoRunning.state)
        let first = try A2MenuSnapshotRenderer.renderPNG(model)
        let second = try A2MenuSnapshotRenderer.renderPNG(model)
        #expect(first == second)
    }

    @Test("10 快照尺寸由模型算得出来(门禁可独立核验产物,不靠渲染器自说自话)")
    func pixelSizeIsDerivedFromModel() throws {
        A2MenuSnapshotRenderer.prepareGraphicsStack()
        let model = A2MenuModelBuilder.build(state: A2PanelFixtures.activeSubscription.state)
        let expected = A2MenuSnapshotRenderer.pixelSize(for: model)
        let png = try A2MenuSnapshotRenderer.renderPNG(model)
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == expected.width)
        #expect(rep.pixelsHigh == expected.height)
    }

    @Test("10 golden 目录里没有孤儿:入库的每一份都对应一个现存固定装置")
    func noOrphanGoldens() throws {
        let names = Set(A2PanelFixtures.fixtures.map(\.name))
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.goldenDirectory, includingPropertiesForKeys: nil)
        for file in files where ["png", "txt"].contains(file.pathExtension) {
            let stem = file.deletingPathExtension().lastPathComponent
            #expect(names.contains(stem),
                    "孤儿 golden:\(file.lastPathComponent) —— 固定装置删了,产物没跟着删")
        }
    }
}