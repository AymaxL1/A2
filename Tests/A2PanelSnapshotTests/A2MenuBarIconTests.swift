// 19 票:菜单栏那一格 —— **有资源用图标、没资源回落文字**,两条都要有断言。
//
// ============================================================================
// 为什么这套用例住在 A2PanelSnapshotTests
// ============================================================================
// 它要真的建 `NSImage` / `NSBitmapImageRep`(AppKit),而 `A2PanelTests` 是**零 AppKit** 的纯逻辑套件
// —— 与 `A2BootstrapAlertTests` 同一条理由,本套件本来就是 AppKit 那一侧。
// **不建 `NSStatusItem`**:那要窗口服务器、还会往真菜单栏塞一格;控制器里除了接线没有别的逻辑,
// 而接线的两端(取图 / 呈现决策)在这里各自被验过。
//
// 资源路径由 `#filePath` 推仓库根(与快照 golden、契约金标同一条口径,不经环境变量注入)。
// **测试直接吃入库的那两张 template PNG** —— 于是"产物被删/改名"这件事在门禁里当场红,
// 而不是等到出包那一步、或者等到用户看见一个空白的菜单栏格子。

import AppKit
import Foundation
import Testing
import A2PanelMacOS

@Suite("19 菜单栏图标(template 取得到就用图,取不到就回落文字)")
@MainActor
struct A2MenuBarIconTests {

    /// `Tests/A2PanelSnapshotTests/<本文件>` → 仓库根 → `assets/branding`。
    static let brandDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // A2PanelSnapshotTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("assets/branding")
    }()

    // ========================================================================
    // 取图
    // ========================================================================

    @Test("19 入库的 template 取得出来:两档 rep、18×18pt、isTemplate=true")
    func loadsTemplateFromBrandDirectory() throws {
        let image = try #require(A2MenuBarIcon.load(resourceURL: Self.brandDirectory),
                                 "assets/branding 里那两张 template 没了 —— 壳会退回文字标题")
        #expect(image.isTemplate, "不是 template 的话,深色菜单栏上会是一块黑糊糊的方")
        #expect(image.size == NSSize(width: 18, height: 18))
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(reps.count == 2, "@1x 与 @2x 两档都要在:少一档就等于把另一档拉伸着用")
        #expect(Set(reps.map(\.pixelsWide)) == [18, 36])
        // 每个 rep 的点尺寸都是 18 → 36px 那张自然是 2 倍图(不设的话它会被当成 36 点的大图)。
        for rep in reps { #expect(rep.size == NSSize(width: 18, height: 18)) }
    }

    @Test("19 资源目录为 nil(dev / swift build 的裸可执行)→ nil → 壳回落文字")
    func missingResourceURLYieldsNil() {
        #expect(A2MenuBarIcon.load(resourceURL: nil) == nil)
    }

    @Test("19 目录在但没有那两张图 → nil(fail-closed,不显示空白格子)")
    func emptyResourceDirectoryYieldsNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("a2-menubar-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(A2MenuBarIcon.load(resourceURL: dir) == nil)
    }

    @Test("19 只有 @1x、缺 @2x → 也是 nil(宁可回落文字,也不在 Retina 上挂一张拉花的图)")
    func halfTheAssetIsNotGoodEnough() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("a2-menubar-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(
            at: Self.brandDirectory.appendingPathComponent("a2-menubar-template.png"),
            to: dir.appendingPathComponent("a2-menubar-template.png"))
        #expect(A2MenuBarIcon.load(resourceURL: dir) == nil)
    }

    @Test("19 名字是单一来源:`build-app.sh` 按它拷,壳按它取")
    func resourceNameIsTheOneWrittenIntoTheBundle() {
        #expect(A2MenuBarIcon.resourceName == "a2-menubar-template")
        #expect(A2MenuBarIcon.pointSize == 18)
    }

    // ========================================================================
    // 呈现决策:两个输入,四种组合,没有第五种
    // ========================================================================

    @Test("19 有图标 · 没接管 → 只有图标,标题空")
    func iconIdle() {
        let p = A2MenuBarPresentation.resolve(hasIcon: true, proxyTakenOver: false)
        #expect(p.usesIcon)
        #expect(p.title.isEmpty)
        #expect(p.imagePosition == .imageOnly)
    }

    @Test("19 有图标 · 接管中 → 图标与「●」**并存**(图标是身份,「●」是状态)")
    func iconTakenOver() {
        let p = A2MenuBarPresentation.resolve(hasIcon: true, proxyTakenOver: true)
        #expect(p.usesIcon)
        #expect(p.title == "●")
        #expect(p.imagePosition == .imageLeading)
    }

    @Test("19 没图标 · 没接管 → 回落成 10 票以来的「A2」")
    func fallbackIdle() {
        let p = A2MenuBarPresentation.resolve(hasIcon: false, proxyTakenOver: false)
        #expect(p.usesIcon == false)
        #expect(p.title == "A2")
        #expect(p.imagePosition == .noImage)
    }

    @Test("19 没图标 · 接管中 → 回落成「A2 ●」,接管语义一个字没丢")
    func fallbackTakenOver() {
        let p = A2MenuBarPresentation.resolve(hasIcon: false, proxyTakenOver: true)
        #expect(p.usesIcon == false)
        #expect(p.title == "A2 ●")
        #expect(p.imagePosition == .noImage)
    }

    @Test("19 「接管中」这件事只由一个指示符表达 —— 两条路径用的是同一个字符")
    func indicatorIsShared() {
        let withIcon = A2MenuBarPresentation.resolve(hasIcon: true, proxyTakenOver: true)
        let withoutIcon = A2MenuBarPresentation.resolve(hasIcon: false, proxyTakenOver: true)
        #expect(withIcon.title == A2MenuBarPresentation.indicator)
        #expect(withoutIcon.title.hasSuffix(A2MenuBarPresentation.indicator))
        #expect(withoutIcon.title.hasPrefix(A2MenuBarPresentation.fallbackTitle))
    }
}
