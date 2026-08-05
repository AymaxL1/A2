// a2-panel-snapshot —— 壳快照的**产物工具**(门禁内部工具,Package.swift 里刻意不给 product)。
//
// ============================================================================
// 它与门禁的分工(10 票改了 14 票的安排,理由写在这里)
// ============================================================================
// 14 票:比对由这个可执行做,`Scripts/check/menubar.sh` 起它、grep 它的结论行。
// 10 票:**比对搬进 `swift test`**(`Tests/A2PanelSnapshotTests`)—— 新门禁的口径是
//   「壳快照(swift test)」,少一条 shell 中间层就少一处会漂的判据。
//
// 于是本工具只剩两件事,都是**给人用的**,门禁一条都不引用:
//   ① `AA_SNAPSHOT_RECORD=1` → **重录 golden**(文案一改 golden 必然全红,得有一条正当的更新路径;
//      它必须**显式**,绝不能让门禁自己在发现不一致时顺手覆盖 golden —— 那等于断言永远为真);
//   ② 不带该环境变量时 → 渲染一份产物到 `.build/` 并打出绝对路径,供人眼抽查那几张图。
// 录制模式**刻意以非零退出码结束**,免得有人拿「录一遍就绿了」糊弄过去。
//
// ⚠️ 本文件不叫 main.swift(理由同 a2-panel:要 `@MainActor` 隔离才碰得了渲染器)。

import AppKit
import Foundation
import A2Panel
import A2PanelMacOS
import A2PanelFixtures

@main
@MainActor
struct A2PanelSnapshotMain {

    static func main() {
        let env = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath
        let outDir = env["AA_SNAPSHOT_OUT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(cwd)/.build/a2-panel-snapshots"
        let goldenDir = env["AA_SNAPSHOT_GOLDEN_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(cwd)/Snapshots/a2-panel"
        let recording = (env["AA_SNAPSHOT_RECORD"] == "1")

        A2MenuSnapshotRenderer.prepareGraphicsStack()

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            if recording { try fm.createDirectory(atPath: goldenDir, withIntermediateDirectories: true) }
        } catch {
            fail("目录创建失败: \(error.localizedDescription)")
        }

        print("a2-panel-snapshot —— 10 票壳快照产物(渲染器 B:A2MenuModel → PNG)")
        print("  产物目录 : \(outDir)")
        print("  golden   : \(goldenDir)")
        print("  模式     : \(recording ? "录制(AA_SNAPSHOT_RECORD=1,退出码 3)" : "产物 + 参考比对")")
        print("  ⚠️ 门禁的判据在 `swift test`(Tests/A2PanelSnapshotTests),不是本工具。")

        var mismatched = 0

        for fixture in A2PanelFixtures.fixtures {
            let model = A2MenuModelBuilder.build(state: fixture.state)
            let size = A2MenuSnapshotRenderer.pixelSize(for: model)
            let png: Data
            do { png = try A2MenuSnapshotRenderer.renderPNG(model) }
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
            print("SNAPSHOT_RENDER: name=\(fixture.name) title=\(fixture.title) "
                  + "size=\(size.width)×\(size.height) png=\(pngPath) txt=\(txtPath) bytes=\(png.count)")

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

            guard let gPNG = fm.contents(atPath: goldenPNG),
                  let gTXTData = fm.contents(atPath: goldenTXT) else {
                mismatched += 1
                print("SNAPSHOT_DIFF: name=\(fixture.name) 状态=golden 缺失(用 AA_SNAPSHOT_RECORD=1 录制)")
                continue
            }
            let textEqual = (String(data: gTXTData, encoding: .utf8) == text)
            if !textEqual {
                mismatched += 1
                print(A2MenuSnapshotRenderer.textDiffReport(
                    golden: String(data: gTXTData, encoding: .utf8) ?? "", current: text))
            }
            guard let cmp = A2MenuSnapshotRenderer.comparePNG(png, gPNG) else {
                mismatched += 1
                print("SNAPSHOT_DIFF: name=\(fixture.name) 状态=无法比对(解码失败或尺寸不同)")
                continue
            }
            if cmp.over > A2MenuSnapshotRenderer.allowedOverTolerancePixels { mismatched += 1 }
            print("SNAPSHOT_DIFF: name=\(fixture.name) diffPixels=\(cmp.diff) total=\(cmp.total) "
                  + "overTolerance=\(cmp.over) textEqual=\(textEqual ? "yes" : "no")")
        }

        print("SNAPSHOT_SUMMARY: fixtures=\(A2PanelFixtures.fixtures.count) mismatched=\(mismatched) "
              + "recording=\(recording ? 1 : 0)")
        fflush(stdout)
        // 录制给 rc=3(与「比对失败」的 rc=1 区分开)。
        exit(recording ? 3 : (mismatched == 0 ? 0 : 1))
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("a2-panel-snapshot 致命错误: \(msg)\n".utf8))
        exit(2)
    }
}
