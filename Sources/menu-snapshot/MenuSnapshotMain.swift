// menu-snapshot —— 14 票的快照工具(门禁内部工具,**不是**对外交付物,故 Package.swift 里刻意不给 product)。
//
// 干三件事,一次跑完:
//   ① 把 `AAMenuFixtures.fixtures` 的每种状态造成 `AAMenuModel`,经**渲染器 B** 画成定尺寸 PNG,
//      落到 `$AA_SNAPSHOT_OUT_DIR/<name>.png`(gitignored 的 .build/ 下),并把绝对路径打出来供人眼抽查;
//   ② 同时落一份 `<name>.txt`(模型的确定性文本快照)—— 图片 diff 说不出「哪一行变了」,文本能;
//   ③ 与入库的 golden 逐像素比对(以及文本逐字节比对),把差异像素数/占比/超容差数打成机读结论行。
//
// `AA_SNAPSHOT_RECORD=1` → **重新录制** golden(不做比对)。这是有意留的 seam:菜单文案一改,golden 必然全红,
//   得有一条正当的更新路径;但它必须**显式**,绝不能让门禁自己在发现不一致时顺手把 golden 覆盖掉
//   (那等于断言永远为真)。录制模式**刻意以非零退出码结束**,免得有人拿「录一遍就绿了」糊弄过去。
//
// ⚠️ 本文件**不叫 main.swift**,与 `Sources/aahost/AAHostMain.swift` 同一个理由:
//    main.swift 的顶层代码是 nonisolated 上下文,构造/调用 `@MainActor` 的东西(这里是渲染器 B,
//    它要碰 NSView)会直接编译报错。用 `@main @MainActor struct` 才拿得到主 actor 隔离。
//
// ⚠️ 证明力边界见 `Sources/AAHostMacOS/MenuSnapshotRenderer.swift` 文件头:
//    这些图证明的是**模型**与「模型 → 两个渲染器」的共享路径,**不证明** AppKit 把真 NSMenu 画成什么样。

import AppKit
import Foundation
import AAContracts
import AAUISystem
import AAHostMacOS
import AAHostTestKit

@main
@MainActor
struct MenuSnapshotMain {

    /// 像素差判据(**阈值给理由,不拍脑袋**):
    ///
    /// 单通道容差 2/255 —— 只用来吸收「同一台机器、同一份字体下的量化舍入」这一类**看不见**的抖动。
    ///   为什么不是 0:0 会把任何一次 CoreGraphics 内部舍入变化都判成回归,而那不是本断言要抓的东西;
    ///   为什么不能更大:菜单渲染是**纯文字 + 直线**,任何真实回归(文案变了、勾选没了、少了一项、置灰了)
    ///   都表现为整块像素在背景色(255)与前景色(≈33)之间跳,单通道差值上百 —— 与 2 差两个数量级。
    ///   也就是说,2 这个数吸收不了任何真回归,也不给「调大阈值蒙混过去」留空间。
    static let channelTolerance = 2
    /// 超容差像素的**允许数量 = 0**:同机确定性渲染下,正确答案就是一个都不该有。
    /// (若哪天证明它会抖,正确做法是降级成文本 golden 并在票面写明,而不是把这个数字调大。)
    static let allowedOverTolerancePixels = 0

    static func main() {
        let env = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath
        let outDir = env["AA_SNAPSHOT_OUT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(cwd)/.build/check/snapshots"
        let goldenDir = env["AA_SNAPSHOT_GOLDEN_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(cwd)/Snapshots/menubar"
        let recording = (env["AA_SNAPSHOT_RECORD"] == "1")

        // AppKit 的字体/绘制栈需要一个 NSApplication 实例才完整初始化;`.prohibited` 保证它不进 Dock、
        //   不抢焦点 —— 这是个跑在门禁里的一次性工具,绝不能变成一个「窗口」。
        NSApplication.shared.setActivationPolicy(.prohibited)

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            if recording { try fm.createDirectory(atPath: goldenDir, withIntermediateDirectories: true) }
        } catch {
            fail("目录创建失败: \(error.localizedDescription)")
        }

        let capabilities = AAMenuFixtures.realCapabilities()
        print("menu-snapshot —— 14 票菜单快照(渲染器 B:AAMenuModel → PNG)")
        print("  能力清单 : 真注册表(demo 能力 + ProxyPlugin.capabilities(),Port 为假件),共 \(capabilities.count) 条")
        print("  产物目录 : \(outDir)")
        print("  golden   : \(goldenDir)")
        print("  模式     : \(recording ? "录制(AA_SNAPSHOT_RECORD=1,不做比对,退出码非 0)" : "比对")")
        print("  容差     : 单通道 ≤ \(channelTolerance)/255 视为无差异;超容差像素允许 \(allowedOverTolerancePixels) 个")

        var rendered = 0, goldenMissing = 0, overToleranceTotal = 0, textMismatch = 0, decodeFailure = 0

        for fixture in AAMenuFixtures.fixtures {
            let model = AAMenuModelBuilder.build(capabilities: capabilities, state: fixture.state)
            let size = AAMenuSnapshotRenderer.pixelSize(for: model)
            let png: Data
            do { png = try AAMenuSnapshotRenderer.renderPNG(model) }
            catch { fail("渲染失败 [\(fixture.name)]: \(error)") }
            let text = model.textSnapshot

            let pngPath = "\(outDir)/\(fixture.name).png"
            let txtPath = "\(outDir)/\(fixture.name).txt"
            do {
                try png.write(to: URL(fileURLWithPath: pngPath))
                try Data(text.utf8).write(to: URL(fileURLWithPath: txtPath))
            } catch {
                fail("产物写入失败 [\(fixture.name)]: \(error.localizedDescription)")
            }
            rendered += 1
            print("SNAPSHOT_EXPECT: name=\(fixture.name) w=\(size.width) h=\(size.height)")
            print("SNAPSHOT_RENDER: name=\(fixture.name) title=\(fixture.title) png=\(pngPath) txt=\(txtPath) bytes=\(png.count)")

            let goldenPNG = "\(goldenDir)/\(fixture.name).png"
            let goldenTXT = "\(goldenDir)/\(fixture.name).txt"

            if recording {
                do {
                    try png.write(to: URL(fileURLWithPath: goldenPNG))
                    try Data(text.utf8).write(to: URL(fileURLWithPath: goldenTXT))
                } catch {
                    fail("golden 写入失败 [\(fixture.name)]: \(error.localizedDescription)")
                }
                print("SNAPSHOT_RECORD: name=\(fixture.name) golden=\(goldenPNG)")
                continue
            }

            guard let gPNG = fm.contents(atPath: goldenPNG), let gTXTData = fm.contents(atPath: goldenTXT) else {
                goldenMissing += 1
                print("SNAPSHOT_DIFF: name=\(fixture.name) golden=\(goldenPNG) 状态=golden缺失(用 AA_SNAPSHOT_RECORD=1 录制)")
                continue
            }
            let textEqual = (String(data: gTXTData, encoding: .utf8) == text)
            if !textEqual {
                textMismatch += 1
                printTextDiff(golden: String(data: gTXTData, encoding: .utf8) ?? "", current: text)
            }

            guard let cmp = comparePNG(png, gPNG) else {
                decodeFailure += 1
                print("SNAPSHOT_DIFF: name=\(fixture.name) golden=\(goldenPNG) 状态=无法比对(解码失败或尺寸不同;"
                      + "当前 \(size.width)×\(size.height)) textEqual=\(textEqual ? "yes" : "no")")
                continue
            }
            overToleranceTotal += cmp.over
            let ratio = cmp.total == 0 ? 0 : Double(cmp.diff) * 100.0 / Double(cmp.total)
            print(String(format: "SNAPSHOT_DIFF: name=%@ golden=%@ diffPixels=%d total=%d ratio=%.4f%% overTolerance=%d textEqual=%@",
                         fixture.name, goldenPNG, cmp.diff, cmp.total, ratio, cmp.over, textEqual ? "yes" : "no"))
        }

        let ok = !recording
            && rendered == AAMenuFixtures.fixtures.count
            && goldenMissing == 0
            && decodeFailure == 0
            && overToleranceTotal <= allowedOverTolerancePixels
            && textMismatch == 0

        print("SNAPSHOT_SUMMARY: rendered=\(rendered) fixtures=\(AAMenuFixtures.fixtures.count)"
              + " goldenMissing=\(goldenMissing) decodeFailure=\(decodeFailure)"
              + " overToleranceTotal=\(overToleranceTotal) textMismatch=\(textMismatch)"
              + " recording=\(recording ? 1 : 0) ok=\(ok ? 1 : 0)")
        fflush(stdout)
        // 录制模式给 rc=3(与「比对失败」的 rc=1 区分开),门禁只接受 rc=0 —— 录制永远不算绿。
        exit(recording ? 3 : (ok ? 0 : 1))
    }

    // ============ 助手 ============

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("menu-snapshot 致命错误: \(msg)\n".utf8))
        exit(2)
    }

    /// 逐像素比较两张 PNG。返回 (总像素, 有差异的像素数, 超单通道容差的像素数);解码失败或尺寸不同 → nil。
    static func comparePNG(_ a: Data, _ b: Data) -> (total: Int, diff: Int, over: Int)? {
        guard let ra = NSBitmapImageRep(data: a), let rb = NSBitmapImageRep(data: b),
              ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh,
              ra.samplesPerPixel == rb.samplesPerPixel,
              let pa = ra.bitmapData, let pb = rb.bitmapData else { return nil }
        let w = ra.pixelsWide, h = ra.pixelsHigh, spp = ra.samplesPerPixel
        let rowA = ra.bytesPerRow, rowB = rb.bytesPerRow
        var diff = 0, over = 0
        for y in 0..<h {
            for x in 0..<w {
                let ia = y * rowA + x * spp
                let ib = y * rowB + x * spp
                var maxDelta = 0
                for c in 0..<spp {
                    let d = abs(Int(pa[ia + c]) - Int(pb[ib + c]))
                    if d > maxDelta { maxDelta = d }
                }
                if maxDelta > 0 { diff += 1 }
                if maxDelta > channelTolerance { over += 1 }
            }
        }
        return (w * h, diff, over)
    }

    /// 文本 golden 对不上时把差异行直接打出来 —— 这正是留一份文本快照的理由:图片 diff 说不出「哪一行变了」。
    static func printTextDiff(golden: String, current: String) {
        let g = golden.components(separatedBy: "\n")
        let n = current.components(separatedBy: "\n")
        print("  文本 golden 差异(golden ←→ 当前):")
        for i in 0..<max(g.count, n.count) {
            let gl = i < g.count ? g[i] : "(无此行)"
            let nl = i < n.count ? n[i] : "(无此行)"
            if gl != nl { print("    第\(i + 1)行:\n      golden: \(gl)\n      当前  : \(nl)") }
        }
    }
}
