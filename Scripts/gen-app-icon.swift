#!/usr/bin/env swift
//
// PROJECT_AA —— **品牌图标生成器**(19 票:v3「A²」→ 母版 / iconset / .icns / 菜单栏 template)。
//
//   swift Scripts/gen-app-icon.swift            # 生成并覆盖 assets/branding/ 下的全部产物
//   swift Scripts/gen-app-icon.swift --verify   # 重新生成到临时目录,与入库产物逐字节比对(不写仓库)
//   swift Scripts/gen-app-icon.swift --out DIR  # 生成到别处(不碰入库产物)
//
// ============================================================================
// 为什么是"程序化重绘",不是把概念稿裁一裁
// ============================================================================
// `assets/branding/concepts/aymax-logo-concept-v3-a-squared.png` 是一张 **AI 生成的海报小样**:
// 1536×1024 的位图,里面的圆角方只有 231px 见方 —— 放大到 1024 就是一团糊,而且它带着海报底色、
// 落款「AYMAX」(已作废的旧命名)。所以它的身份是**设计意图的样本**,不是素材。
// 本脚本做的事:把那张样本**量出来**(几何比例 + 色值),再用 CoreGraphics/CoreText 按同一比例重画。
// 于是产物是矢量级清晰的、任意尺寸原生渲染的、且**可复现**的。
//
// ============================================================================
// 实测约束:这个脚本不能 `import AppKit`
// ============================================================================
// `swift <file>.swift` 走的是解释器(JIT),它**加载不了 AppKit 的 ObjC 类**:一 `NSImage` 就
//   `JIT session error: Symbols not found: [_OBJC_CLASS_$_NSImage, _OBJC_CLASS_$_NSBitmapImageRep]`。
// CoreGraphics / CoreText / ImageIO 是 C API,JIT 下正常;Foundation 的 `FileManager` / `Process`
//   (ObjC 类,但 Foundation 在解释器里是链上的)实测可用。
// 所以:**画图一律 CG/CT/ImageIO,不碰 AppKit** —— 这是"单文件可直跑"这条要求的硬约束,不是偏好。
//
// ============================================================================
// 网格与比例(每个数都有出处)
// ============================================================================
// * 画布 1024,圆角方 **824×824 居中**(macOS Big Sur 图标网格)—— 四周各留 100px,那是**给系统
//   加投影用的余量**;本脚本**不画投影**:素材保持干净,投影由系统在各展示场景自加(Dock/Finder/
//   打开面板各不相同,画死了到处对不上)。
// * 圆角半径 **184**(= 824 × 0.2233,HIG 模板比例 ≈0.2237 取整)。**macOS 的圆角必须画进素材里** ——
//   系统不代裁(那是 iOS 的规矩)。顺带记一笔:v3 小样自己的圆角实测 ≈ 边长的 0.208(231 方、R≈48),
//   比 HIG 略圆一点;这里**以 HIG 为准**,因为这是要进 Dock/Finder 与别的 macOS 图标并排的东西。
// * 字形比例**全部量自 v3 小样右下角那两个圆角方**(黑底版与橙底版,两版量出来一致到 1%):
//     - A 的 cap 高 / 方边 = 0.472(橙)/ 0.465(黑) → 取 **0.470**;
//     - 上标 2 的高 / A 的 cap 高 = 0.321 / 0.308 → 取 **0.315**;
//     - 2 的**顶与 A 的顶齐平**(实测两版都只差 1px / 109px ≈ 0.9%)→ 取 **齐平**;
//     - 2 的左边缘**内嵌进 A 的右边缘** 22px / A 宽 122px → 取 **0.180 × A 宽**(它卡在 A 右斜边上方的缺口里);
//     - 记号(A + 2 的并集包围盒)在方内**上下左右居中**(实测小样偏下 6.5px/231 ≈ 2.8%,不复刻这点偏移)。
//   ⚠️ 票面给的目测值是「A 高约占方的 55–60%」「2 约 40% 字号」—— **实测把这两个数都纠正了**
//   (47% 与 31.5%)。以量出来的为准:那才是"照小样"。
//
// ============================================================================
// 色值(取自 v3 小样,写死在这里)
// ============================================================================
// * 陶土橙 `#C36446` —— 橙底小样内部取样区中位色(样本 1071 像素)。
// * 米白   `#FDF9F1` —— 黑底小样里那个字形的中位色(样本 8480 像素),也与海报底色一致。
// * 近黑   `#242424` —— 黑底小样的底色中位色(黑底变体用,**备选、不接线**)。
// 取样脚本是一次性的(不入库):CGImageSource 解 PNG → 连通域拆出 A 与 2 → 量 bbox 与中位色。
//
// ============================================================================
// 字体:`.SFNS-Black`(SF Pro 的 Black 字重)
// ============================================================================
// 票面允许「SF Pro / Helvetica Bold 族」。本机把两族的 A 与 2 都渲染出来,与小样做了**客观对账**
// (A 的宽高比、墨水占比;小样 A = 1.119 / 0.503,2 = 0.829 / 0.629):
//     .SFNS-Black 1.020 / 0.578 · HelveticaNeue-Bold 0.980 / 0.461 · Helvetica-Bold 0.945 / 0.480
// 三者里 SF Pro Black 最接近,而且它就是这台机器上系统 UI 的黑体字重 —— 与 macOS 原生观感同源。
// (如实记:整机最接近小样的其实是 **Arial-Black**(1.090 / 0.557),但它不在票面允许的两族里,没用。)
//
// **取字体的方式是有讲究的**:`CTFontCreateWithName(".SFNS-Black")` 会被 CoreText **静默换成
// Times New Roman**(它拦截了对系统字体私有名的直接请求,只在控制台留一行 note)。可用的是
// `.AppleSystemUIFontBlack` 这个别名 —— 拿到后**回读 PostScript 名核对**,不是那个就当场退出:
// 字体一换,产物的每个像素都变,"可复现"就成了空话。
//
// ============================================================================
// 可复现判据(19 票实测)
// ============================================================================
// 判据是**逐字节**:`--verify` 重新生成到临时目录,与入库产物 `Data ==` 比。本机连跑两次,
// 13 个产物(2 母版 + 10 iconset + 1 icns;template 2 张同理)**全部逐字节相同** ——
// 画的是字形轮廓路径(`CTFontCreatePathForGlyph` + `fillPath`),不经字体 hinting / 亚像素那一套,
// 于是同字体同机器下渲染是确定的;`iconutil -c icns` 亦然。
// 跨机器/跨系统版本**不承诺**逐字节:SF Pro 是随系统更新的字体,Apple 改一次字形产物就变一次
// (那时该做的是重跑本脚本、重看图、重录产物,而不是把判据放宽)。
// 门禁里另有一层**便宜的**守卫(`Tests/A2PanelSnapshotTests/A2BrandAssetTests.swift`):
// 直接量入库产物的几何与色值(圆角方位置、圆角半径、A 高占比、上标比例与齐平关系、色值、
// 模板纯黑+alpha、icns 十档往返)—— 改了本文件的常量却忘了重跑脚本,那一套当场红。
//
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ============================================================================
// ① 设计常量(改这里 = 改设计;改完必须重跑本脚本,否则门禁那套几何断言会红)
// ============================================================================
enum Design {
    /// 母版画布。
    static let canvas = 1024

    /// 圆角方边长 / 画布(Big Sur 网格 824/1024);余下的边距是**给系统投影的**,素材里不画投影。
    static let squareRatio = 824.0 / 1024.0
    /// 圆角半径 / 圆角方边长(184/824 ≈ 0.2233;HIG 模板 ≈0.2237)。
    static let cornerRatio = 184.0 / 824.0

    /// A 的 cap 高 / 圆角方边长(v3 小样实测 0.472 与 0.465)。
    static let capRatio = 0.470
    /// 上标 2 的高 / A 的 cap 高(实测 0.321 与 0.308)。
    static let superscriptRatio = 0.315
    /// 上标 2 的左边缘相对 A 右边缘的**内嵌量** / A 宽(实测 22/122)。
    static let superscriptOverlapRatio = 0.180

    /// 菜单栏 template:A 的 cap 高 / 18pt 见方的边长。
    /// 这一条**不照小样**:小样里 A 只占方的 47%,那是因为它外面有一个实心圆角方托着;
    /// 菜单栏图标没有底,再留那么多空白就只剩一个小得看不清的记号。0.72 让记号占满 18pt 的可视区,
    /// 与相邻的系统图标(Wi-Fi / 电池)体量相当。
    static let templateCapRatio = 0.72

    /// 色值(出处见文件头)。
    static let terracotta = rgb(0xC3, 0x64, 0x46)
    static let cream      = rgb(0xFD, 0xF9, 0xF1)
    static let nearBlack  = rgb(0x24, 0x24, 0x24)
    static let pureBlack  = rgb(0x00, 0x00, 0x00)

    /// iconset 的十档(`iconutil` 认这套文件名,少一档它就只收到少一档)。
    static let iconsetEntries: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]

    /// 菜单栏 template 的两档(18×18pt 的 @1x 与 @2x)。
    static let templateEntries: [(name: String, pixels: Int)] = [
        ("a2-menubar-template.png", 18), ("a2-menubar-template@2x.png", 36),
    ]

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

// ============================================================================
// ② 字体:拿到 SF Pro Black,并**回读核对**
// ============================================================================
enum BrandFont {
    /// CoreText 拦截系统字体私有名的直接请求,只有这个别名能拿到 Black 字重。
    static let requestName = ".AppleSystemUIFontBlack"
    /// 拿到之后必须是它(否则说明这台机器上取到的是别的字体,产物会与入库那份不同)。
    static let expectedPostScriptName = ".SFNS-Black"

    static func make(size: CGFloat) -> CTFont {
        let font = CTFontCreateWithName(requestName as CFString, size, nil)
        let got = CTFontCopyPostScriptName(font) as String
        guard got == expectedPostScriptName else {
            fail("字体取错了:请求 \(requestName) 却拿到 \(got)(期望 \(expectedPostScriptName))。"
                 + "换了字体产物的每个像素都会变 —— 这里宁可当场停,也不悄悄出一份对不上的图标。")
        }
        return font
    }

    /// 单个字形的填充路径 + 它自己的紧包围盒(**不是** advance / 行高:排版靠 bbox 定位,像量小样那样)。
    static func glyphPath(_ font: CTFont, _ character: Character) -> (path: CGPath, box: CGRect) {
        let scalars = Array(String(character).utf16)
        var chars = scalars
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
              let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
            fail("字体里取不到字形「\(character)」的轮廓")
        }
        return (path, path.boundingBox)
    }
}

// ============================================================================
// ③ 记号:把 A² 按比例居中画进一个方框
// ============================================================================
/// - Parameters:
///   - box: 记号要居中进去的方框(母版里 = 圆角方;菜单栏里 = 整张 18pt 画布)
///   - capHeight: A 的 cap 高(像素)
enum Mark {
    static func draw(in ctx: CGContext, box: CGRect, capHeight: CGFloat, color: CGColor) {
        // 字号随便给(这里给 capHeight 的量级),真正的尺寸靠 bbox 缩放定 —— 于是"A 多高"是显式的,
        // 不依赖某个字体的 cap-height 元数据是否诚实。
        let font = BrandFont.make(size: capHeight * 2)
        let a = BrandFont.glyphPath(font, "A")
        let s = BrandFont.glyphPath(font, "2")

        let aScale = capHeight / a.box.height
        let aWidth = a.box.width * aScale
        let sScale = (capHeight * Design.superscriptRatio) / s.box.height
        let sWidth = s.box.width * sScale

        // 组的尺寸:2 的顶与 A 的顶齐平 ⇒ 组高 = A 的 cap 高;组宽 = A 宽 + 2 宽 - 内嵌量。
        let overlap = aWidth * Design.superscriptOverlapRatio
        let groupWidth = aWidth + sWidth - overlap
        let groupHeight = capHeight

        let left = box.midX - groupWidth / 2
        let baseline = box.midY - groupHeight / 2      // A 的基线(= 组的下沿)
        let capTop = baseline + capHeight

        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(place(a, scale: aScale, x: left, y: baseline))
        ctx.addPath(place(s, scale: sScale,
                          x: left + aWidth - overlap,
                          y: capTop - capHeight * Design.superscriptRatio))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// 把字形路径缩放到 `scale`,并让它的**包围盒左下角**落在 (x, y)。
    private static func place(_ glyph: (path: CGPath, box: CGRect),
                              scale: CGFloat, x: CGFloat, y: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: x - glyph.box.minX * scale,
                                  y: y - glyph.box.minY * scale)
            .scaledBy(x: scale, y: scale)
        return glyph.path.copy(using: &t)!
    }
}

// ============================================================================
// ④ 两种画布
// ============================================================================
enum Canvas {
    static func context(_ pixels: Int) -> CGContext {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fail("建不出 \(pixels)×\(pixels) 的位图上下文")
        }
        // 显式打开抗锯齿:小尺寸档全靠它,而"默认值是什么"不该由 CG 的版本说了算。
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        return ctx
    }

    /// App 图标:透明画布 + 居中的实心圆角方 + 记号。**每一档都按该档的像素原生重画**
    /// (不是从 1024 缩下来的)—— 16px 那档缩出来是一团糊,重画才有清楚的边。
    static func appIcon(pixels: Int, background: CGColor, glyph: CGColor) -> CGImage {
        let ctx = context(pixels)
        let side = CGFloat(pixels) * Design.squareRatio
        let origin = (CGFloat(pixels) - side) / 2
        let square = CGRect(x: origin, y: origin, width: side, height: side)

        ctx.saveGState()
        ctx.setFillColor(background)
        ctx.addPath(CGPath(roundedRect: square,
                           cornerWidth: side * Design.cornerRatio,
                           cornerHeight: side * Design.cornerRatio, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        Mark.draw(in: ctx, box: square, capHeight: side * Design.capRatio, color: glyph)
        guard let image = ctx.makeImage() else { fail("导不出 \(pixels)px 的图") }
        return image
    }

    /// 菜单栏 template:透明底 + **纯黑** 记号。`isTemplate = true` 之后 AppKit 只看 alpha,
    /// 明暗外观下自动换色(所以这里不能画任何"颜色",只能画黑与透明)。
    static func menuBarTemplate(pixels: Int) -> CGImage {
        let ctx = context(pixels)
        let box = CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
        Mark.draw(in: ctx, box: box,
                  capHeight: CGFloat(pixels) * Design.templateCapRatio, color: Design.pureBlack)
        guard let image = ctx.makeImage() else { fail("导不出 \(pixels)px 的模板图") }
        return image
    }
}

// ============================================================================
// ⑤ 写盘 / 外部工具
// ============================================================================
func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        fail("建不出 PNG 写入器:\(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("PNG 写入失败:\(url.path)") }
}

@discardableResult
func run(_ launchPath: String, _ arguments: [String]) -> (code: Int32, output: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { fail("起不来 \(launchPath):\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}

// ============================================================================
// ⑥ 一趟生成:把全部产物写进 `dir`
// ============================================================================
/// 返回**相对 `dir` 的产物路径清单**(顺序固定,给比对用)。
@discardableResult
func generate(into dir: URL) -> [String] {
    let fm = FileManager.default
    let iconset = dir.appendingPathComponent("AppIcon.iconset")
    try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    // 陈旧档不许留在 iconset 里:`iconutil` 会把它一起打进 .icns(于是产物里混着上一版的某一档)。
    for stale in (try? fm.contentsOfDirectory(atPath: iconset.path)) ?? []
    where !Design.iconsetEntries.contains(where: { $0.name == stale }) {
        try? fm.removeItem(at: iconset.appendingPathComponent(stale))
    }

    var produced: [String] = []

    // 母版两张(陶土橙 = 主选并接线;近黑 = 备选,只存不接线)
    writePNG(Canvas.appIcon(pixels: Design.canvas,
                           background: Design.terracotta, glyph: Design.cream),
             to: dir.appendingPathComponent("a2-icon-master-terracotta-1024.png"))
    produced.append("a2-icon-master-terracotta-1024.png")
    writePNG(Canvas.appIcon(pixels: Design.canvas,
                           background: Design.nearBlack, glyph: Design.cream),
             to: dir.appendingPathComponent("a2-icon-master-black-1024.png"))
    produced.append("a2-icon-master-black-1024.png")

    // iconset 十档(主选色)
    for entry in Design.iconsetEntries {
        writePNG(Canvas.appIcon(pixels: entry.pixels,
                               background: Design.terracotta, glyph: Design.cream),
                 to: iconset.appendingPathComponent(entry.name))
        produced.append("AppIcon.iconset/" + entry.name)
    }

    // .icns —— `iconutil` 是 macOS 自带的唯一权威打包器(自己拼 icns 容器格式没有任何好处)
    let icns = dir.appendingPathComponent("AppIcon.icns")
    try? fm.removeItem(at: icns)
    let r = run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
    guard r.code == 0, fm.fileExists(atPath: icns.path) else {
        fail("iconutil -c icns 失败(rc=\(r.code)):\(r.output)")
    }
    produced.append("AppIcon.icns")

    // 菜单栏 template 两档
    for entry in Design.templateEntries {
        writePNG(Canvas.menuBarTemplate(pixels: entry.pixels),
                 to: dir.appendingPathComponent(entry.name))
        produced.append(entry.name)
    }
    return produced
}

// ============================================================================
// ⑦ 入口
// ============================================================================
// 仓库根由 `#filePath` 推(与 `GoldenSampleLoader` / 快照测试同一条口径:不经环境变量注入)。
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // Scripts
    .deletingLastPathComponent()      // 仓库根
let brandDir = repoRoot.appendingPathComponent("assets/branding")

var verifyMode = false
var outputDir = brandDir
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--verify": verifyMode = true
    case "--out":
        guard let value = args.first else { fail("--out 需要一个目录") }
        args.removeFirst()
        outputDir = URL(fileURLWithPath: value)
    case "-h", "--help":
        print("""
        用法: swift Scripts/gen-app-icon.swift [--verify | --out DIR]
          (无参数)  生成并覆盖 assets/branding/ 下的全部产物
          --verify  重新生成到临时目录并与入库产物逐字节比对(不写仓库),不一致即非零退出
          --out DIR 生成到 DIR
        """)
        exit(0)
    default: fail("未知参数:\(arg)(用 --help 看用法)")
    }
}

if verifyMode {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("a2-icon-verify-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let produced = generate(into: tmp)
    var differing: [String] = []
    print("==== gen-app-icon --verify:重跑脚本 × 入库产物,逐字节 ====")
    for name in produced {
        let fresh = try? Data(contentsOf: tmp.appendingPathComponent(name))
        let stored = try? Data(contentsOf: brandDir.appendingPathComponent(name))
        switch (fresh, stored) {
        case let (f?, s?) where f == s:
            print(String(format: "  同 %-44@ %7d 字节", name as NSString, s.count))
        case let (f?, s?):
            let firstDiff = zip(f, s).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            print(String(format: "  异 %-44@ 重跑 %d 字节 / 入库 %d 字节;首个不同字节 @%@",
                         name as NSString, f.count, s.count,
                         firstDiff.map(String.init) ?? "(长度不同)"))
            differing.append(name)
        case (nil, _): print("  缺 \(name) —— 重跑没生成出来"); differing.append(name)
        case (_, nil): print("  缺 \(name) —— 入库里没有这一份"); differing.append(name)
        }
    }
    if differing.isEmpty {
        print("OK: \(produced.count) 个产物与入库逐字节相同(判据见文件头「可复现判据」一节)")
        exit(0)
    }
    print("FAILED: \(differing.count)/\(produced.count) 个产物与入库不同 —— "
          + "要么设计常量改了没重跑脚本,要么字体/系统换了。前者重跑本脚本并**看图**,后者见文件头。")
    exit(1)
}

let produced = generate(into: outputDir)
print("==== gen-app-icon:\(outputDir.path) ====")
for name in produced {
    let size = (try? Data(contentsOf: outputDir.appendingPathComponent(name)))?.count ?? -1
    print(String(format: "  %-44@ %7d 字节", name as NSString, size))
}
print("OK: \(produced.count) 个产物(母版 2 · iconset \(Design.iconsetEntries.count) · icns 1 · 菜单栏 template \(Design.templateEntries.count))")
print("   字体 \(BrandFont.expectedPostScriptName) · 陶土橙 #C36446 · 米白 #FDF9F1 · 圆角方 824/1024 · 圆角 184")
