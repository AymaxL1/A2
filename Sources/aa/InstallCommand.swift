// ============ aa install-cli(符号链接入 PATH)============
import Foundation
import Darwin
import AAContracts

/// install-cli 的机读成功载荷。
struct InstallResult: Codable, Sendable, Equatable {
    /// installed / already-installed / overwritten。
    let action: String
    let target: String
    let source: String
}

/// 当前 aa 可执行的绝对路径(符号链接的源)。首选 `_NSGetExecutablePath`(macOS 规范取法),
/// 回退 argv[0] / Bundle;经 resolvingSymlinksInPath 规整为干净绝对路径。
func currentExecutablePath() -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)               // 先探所需缓冲大小
    if size > 0 {
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 {
            let raw = String(cString: buf)
            return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        }
    }
    if let p = Bundle.main.executablePath {
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
    let a0 = CommandLine.arguments.first ?? "aa"
    let abs = a0.hasPrefix("/") ? a0 : FileManager.default.currentDirectoryPath + "/" + a0
    return URL(fileURLWithPath: abs).resolvingSymlinksInPath().path
}

/// target 处的符号链接(canonical 化后)是否指向 source。
/// `destinationOfSymbolicLink` 返回原样存储值(可能相对 / 未规整);必须按链接所在目录解析成绝对路径再 canonical 化,
/// 否则相对链接、`/tmp` vs `/private/tmp`(/tmp 本身是 symlink)等"等价但字面不同"会被误判成"指向别处"、逼用户 --force。
/// source 已由 currentExecutablePath() 经 resolvingSymlinksInPath 规整,两边同等 canonical 再比。
func symlinkCanonicalDestination(linkPath: String) -> String? {
    guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else { return nil }
    let base = URL(fileURLWithPath: linkPath).deletingLastPathComponent()
    return URL(fileURLWithPath: dest, relativeTo: base).resolvingSymlinksInPath().path
}

func symlinkPointsTo(linkPath: String, source: String) -> Bool {
    symlinkCanonicalDestination(linkPath: linkPath) == source
}

/// 覆盖/卸载前删除旧目标;失败时如实报(remove_failed),不吞错、也不归因成 link_failed 建议 sudo。
/// 返回 Void(成功),失败走 failUsage(Never)。
func removeExistingTarget(_ path: String, json: Bool) {
    do {
        try FileManager.default.removeItem(atPath: path)
    } catch {
        failUsage(code: CLIErrorCode.removeFailed,
                  detail: "删除旧目标失败: \(path): \(error.localizedDescription)",
                  human: "install-cli 失败:无法删除旧目标 \(path)(\(error.localizedDescription))。", json: json)
    }
}

/// `aa install-cli [--prefix <dir>] [--force] [--json]`:把当前 aa 符号链接进 PATH。
/// 幂等:已指向同源→no-op 成功;指向别处/非链接文件→需 --force 覆盖;目标目录不存在→明确错误。均不连宿主。
func dispatchInstallCli(_ rest: [String]) -> Never {
    var prefix: String? = nil
    var force = false
    var json = false
    var uninstall = false
    var i = 0
    while i < rest.count {
        let tok = rest[i]
        switch tok {
        case "--force":     force = true
        case "--json":      json = true
        case "--uninstall": uninstall = true
        case "--prefix":
            i += 1
            guard i < rest.count else { errPrint("--prefix 需要一个目录参数"); exit(AAExitCode.usage) }
            prefix = rest[i]
        case "-h", "--help":
            outPrint(installCliUsage()); exit(AAExitCode.success)
        default:
            errPrint("未知选项: \(tok)"); errPrint(installCliUsage()); exit(AAExitCode.usage)
        }
        i += 1
    }
    if uninstall {
        doUninstallCli(prefix: prefix, json: json)   // --uninstall 与 --force 无关(卸载不需要 force)
    }
    doInstallCli(prefix: prefix, force: force, json: json)
}

func installCliUsage() -> String {
    """
    用法: aa install-cli [--prefix <dir>] [--force] [--json]
          aa install-cli --uninstall [--prefix <dir>] [--json]
      默认把 aa 符号链接到 /usr/local/bin/aa;--prefix 覆盖目标目录。
      幂等:已指向同一 aa → no-op 成功;指向别处/普通文件 → 需 --force 覆盖;目标目录不存在 → 报错。
      --uninstall:删除指向本 aa 的符号链接(幂等:不存在即成功;不误删普通文件/目录/指向别处的链接)。
    """
}

func doInstallCli(prefix: String?, force: Bool, json: Bool) -> Never {
    let fm = FileManager.default
    let source = currentExecutablePath()
    let dir = prefix ?? "/usr/local/bin"
    let target = (dir as NSString).appendingPathComponent("aa")

    // 目标目录须已存在(不代建,避免误建系统目录)。
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
        failUsage(code: CLIErrorCode.targetDirMissing, detail: "目标目录不存在: \(dir)",
                  human: "install-cli 失败:目标目录不存在: \(dir)(请先创建,或用 --prefix 指定已存在目录)。", json: json)
    }

    // 用 attributesOfItem(不追随末端符号链接)判目标当前形态。
    let itemType = (try? fm.attributesOfItem(atPath: target))?[.type] as? FileAttributeType

    if itemType == nil {
        // 不存在 → 直接建链接。
        installCreateLink(source: source, target: target, action: "installed", json: json)
    }
    if itemType == .typeSymbolicLink {
        // canonical 化后比较(修:相对链接 / /tmp vs /private/tmp 等价但字面不同不再误判为"指向别处")。
        let canonicalDest = symlinkCanonicalDestination(linkPath: target) ?? "(无法解析)"
        if symlinkPointsTo(linkPath: target, source: source) {
            // 幂等:已指向同源 → no-op 成功。
            installFinishSuccess(action: "already-installed", source: source, target: target, json: json,
                                 human: "install-cli:已安装且指向一致(no-op) \(target) → \(source)")
        }
        if !force {
            failUsage(code: CLIErrorCode.targetExists,
                      detail: "符号链接已存在且指向别处: \(target) → \(canonicalDest)",
                      human: "install-cli 失败:\(target) 已存在且指向 \(canonicalDest)(非本 aa)。确认后加 --force 覆盖。", json: json)
        }
        removeExistingTarget(target, json: json)
        installCreateLink(source: source, target: target, action: "overwritten", json: json)
    }
    if itemType == .typeDirectory {
        // 目录一律不覆盖(哪怕 --force),避免误删。
        failUsage(code: CLIErrorCode.targetIsDirectory, detail: "目标是目录,拒绝覆盖: \(target)",
                  human: "install-cli 失败:目标是目录,拒绝覆盖: \(target)。", json: json)
    }
    // 普通文件(或其它非目录非链接类型):需 --force 才覆盖。
    if !force {
        failUsage(code: CLIErrorCode.targetExists, detail: "目标已存在(非符号链接): \(target)",
                  human: "install-cli 失败:\(target) 已存在(非符号链接)。确认后加 --force 覆盖。", json: json)
    }
    removeExistingTarget(target, json: json)
    installCreateLink(source: source, target: target, action: "overwritten", json: json)
}

/// `aa install-cli --uninstall [--prefix <dir>]`:删除指向本 aa 的符号链接。
/// 幂等:目标不存在 → no-op 成功(not-installed);指向本 aa 的符号链接 → 删除(uninstalled);
/// 普通文件/目录 / 指向别处的链接 → 拒绝(不误删非自己建的),退出码 1。均不连宿主。
func doUninstallCli(prefix: String?, json: Bool) -> Never {
    let fm = FileManager.default
    let source = currentExecutablePath()
    let dir = prefix ?? "/usr/local/bin"
    let target = (dir as NSString).appendingPathComponent("aa")

    let itemType = (try? fm.attributesOfItem(atPath: target))?[.type] as? FileAttributeType
    if itemType == nil {
        // 幂等:本就不存在 → no-op 成功。
        installFinishSuccess(action: "not-installed", source: source, target: target, json: json,
                             human: "install-cli --uninstall:目标不存在,无需卸载(no-op) \(target)")
    }
    // 只删"指向本 aa 的符号链接";普通文件/目录 / 指向别处的链接一律拒绝(避免误删非自己建的)。
    guard itemType == .typeSymbolicLink, symlinkPointsTo(linkPath: target, source: source) else {
        let cur = symlinkCanonicalDestination(linkPath: target) ?? "(非符号链接)"
        failUsage(code: CLIErrorCode.notOurLink,
                  detail: "拒绝卸载:\(target) 不是指向本 aa 的符号链接(当前: \(cur))",
                  human: "install-cli --uninstall 失败:\(target) 不是本 aa 建的符号链接(当前指向 \(cur)),"
                       + "拒绝删除(避免误删非自己建的)。", json: json)
    }
    removeExistingTarget(target, json: json)
    installFinishSuccess(action: "uninstalled", source: source, target: target, json: json,
                         human: "install-cli:已卸载 \(target)(原指向 \(source))")
}

/// 建符号链接;失败(如目录无写权限)→ 退出码 1 + 明确提示。成功走统一成功收口。
func installCreateLink(source: String, target: String, action: String, json: Bool) -> Never {
    do {
        try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: source)
    } catch {
        failUsage(code: CLIErrorCode.linkFailed,
                  detail: "创建符号链接失败: \(target) → \(source): \(error.localizedDescription)",
                  human: "install-cli 失败:无法创建符号链接 \(target)(\(error.localizedDescription))。"
                       + "若目标目录需要权限,请用 sudo 或改 --prefix 到可写目录。", json: json)
    }
    let verb = action == "overwritten" ? "覆盖并安装" : "安装"
    installFinishSuccess(action: action, source: source, target: target, json: json,
                         human: "install-cli:已\(verb) \(target) → \(source)")
}

/// install-cli 成功收口:`--json` 打机读信封;否则人读一行;退出码 0。
func installFinishSuccess(action: String, source: String, target: String, json: Bool, human: String) -> Never {
    if json {
        emitEnvelope(WireResponse.success(InstallResult(action: action, target: target, source: source)))
    } else {
        outPrint(human)
    }
    exit(AAExitCode.success)
}
