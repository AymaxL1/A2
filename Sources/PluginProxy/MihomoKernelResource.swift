import Foundation

/// PluginProxy 随包携带的唯一锁版内核。生产调用方绝不从 PATH 或环境变量解析可执行文件。
public enum MihomoKernelResource {
    public static let version = "v1.19.28"
    public static let sha256 = "55b7286331cb30a54b2564013b02b84a0c280e8b690bd1e5da4b9d4f4ca007ac"

    // ---- 15 票:GPL 义务的「出处」三件套 ------------------------------------------------
    // 为什么放这里而不是各自散落:**内核的版本与出处只有这一个真值来源**。
    //   关于页、`proxy.license` 能力、门禁断言全部从本类型取值,谁都不许再写一遍字面量。
    //   门禁侧的对应单一来源是 `Scripts/check/bootstrap.sh` 从 `Resources/MIHOMO-VERSION.txt`
    //   解析出的 `$MIHOMO_VERSION` —— 两侧同源于那个 txt(它同时写着 Source: 与 License: 两行),
    //   断言 APP9 每轮门禁把「Swift 侧常量」与「txt 侧解析值」当场对一次(经 `aa proxy license` 读回),漂了就红。

    /// 许可证标识。与 `Resources/MIHOMO-VERSION.txt` 的 `License:` 行取值一致。
    public static let license = "GPL-3.0"

    /// 源码获取地址(GPL-3.0 的「书面提供源码」义务落点)。
    /// **由 `version` 派生**,不写死整条 URL —— 否则换内核版本时这里会悄悄留在旧 tag 上,
    /// 而那正是 GPL 义务里最不能错的一处(附的源码必须是所分发二进制对应的那份)。
    /// 与 `Resources/MIHOMO-VERSION.txt` 的 `Source:` 行取值一致。
    public static let sourceURL = "https://github.com/MetaCubeX/mihomo/releases/tag/\(version)"

    /// 子进程红线原文(ADR 0007 的提炼句)。
    ///
    /// 单一来源放这里的理由:这句话要同时出现在**关于页**与 **`proxy.license` 能力输出**里,
    /// 而关于页的数据一律经能力面取(GUI 是薄壳,不许有私有逻辑)——于是两处其实是同一个字符串,
    /// 只该书写一次。改这句话 = 改集成红线,必须同步改 `docs/adr/0007-mihomo-subprocess-gpl-compliance.md`。
    public static let subprocessBoundary =
        "mihomo 内核仅以独立子进程运行,控制面仅走其外部接口(REST API / 配置文件)通信,永不进程内链接(含 c-archive/cgo 静态链接)。"

    public static var executablePath: String {
        resourcePath("mihomo-darwin-arm64")
    }

    public static var defaultConfigPath: String {
        resourcePath("default-config.yaml")
    }

    /// 随包 GPL-3.0 全文的绝对路径(关于页的「全文入口」指向它;`.copy("Resources")` 自动带进资源 bundle 与 `.app`)。
    ///
    /// **刻意复用 `resourcePath`**,不另写一套查找逻辑:内核可执行、默认配置、许可证全文住同一个资源 bundle,
    /// 三者的落点解析必须逐字一致 —— 否则 `.app` 形态下会出现「内核找得到、许可证找不到」这种只在打包后才暴露的分叉。
    /// **与 `executablePath` 不同口径:找不到时不崩,返回「期望落点」供如实展示。** 理由值得写清楚 ——
    /// 「打包漏了许可证」是**构建期**的合规缺陷,而门禁断言 APP7 已经用 SHA-256 精确抓住它
    /// (比对 `.app` 内那份与仓库源文件)。运行时再崩一次不增加任何保护,只是把一个合规问题
    /// 变成用户机器上的崩溃 —— 而且崩的是**整个宿主**,连带代理功能一起没了。
    /// 内核可执行与默认配置则仍然崩:那两样缺了插件根本没法工作,快速失败是对的。
    /// 于是 `proxy.license` 的 `licenseTextAvailable` 成为真信号,关于页那条「⚠️ 全文未找到」分支也不再是死码。
    public static var licenseTextPath: String {
        resourcePath("LICENSE-mihomo-GPL-3.0.txt", fatalIfMissing: false)
    }

    /// SwiftPM 给带 resources 的 target 生成的资源 bundle 名 = `<包名>_<target名>.bundle`。
    /// 这里必须写死一次:12 票的 `.app` 里要在 `Bundle.module` 之外**先**按约定落点找它(见 resourcePath 注释)。
    /// 与 SwiftPM 生成的 `resource_bundle_accessor.swift` 里那个同名常量是同一个事实的两处书写 ——
    /// 包名或 target 名一改,两处一起变(改错的表现是 `.app` 里起宿主当场 fatalError,不会静默降级)。
    private static let packageResourceBundleName = "PROJECT_AA_PluginProxy.bundle"

    /// - Parameter fatalIfMissing: `true`(缺省)= 找不到就 fatalError,用于内核可执行/默认配置这类
    ///   「缺了插件根本没法工作」的资源;`false` = 找不到时返回**期望落点**的路径字符串(供如实展示),
    ///   由调用方另行判断文件是否真在盘上(见 `licenseTextPath` 的说明)。
    private static func resourcePath(_ name: String, fatalIfMissing: Bool = true) -> String {
#if SWIFT_PACKAGE
        // ① 先查 `Bundle.main.resourceURL/<资源bundle>/Resources/<name>`。
        //
        // 为什么不能只靠 `Bundle.module`(12 票实测结论,不是推测):
        //   SwiftPM 生成的访问器只试**两个**路径 —— `Bundle.main.bundleURL/<资源bundle>` 与构建目录里的绝对路径。
        //   在 `.app` 里 `Bundle.main.bundleURL` 就是 `AA.app` 本身,于是它要求资源 bundle 落在 **bundle root**
        //   (`AA.app/PROJECT_AA_PluginProxy.bundle`,与 `Contents` 平级)。而 `codesign` 明确拒绝这种布局:
        //   签 `.app` 本体时报 `unsealed contents present in the bundle root`(rc=1),换成 bundle root 放符号链接
        //   同样被拒 —— 三种落点都实测过,结论写在 `Scripts/build-app.sh` 顶部。
        //   即「Bundle.module 能找到的落点」与「codesign 能接受的落点」在 `.app` 形态下**没有交集**。
        //   故 `.app` 里资源 bundle 必须住 `Contents/Resources/`(可签、可校验),由本分支负责找到它。
        //
        // 这一支对**非 bundle 形态**(`swift build` 出来的裸可执行、门禁的 registry-tests)同样成立且更直接:
        //   非 bundle 可执行的 `Bundle.main.resourceURL` 就是可执行所在目录,而 SwiftPM 正把资源 bundle
        //   产在那里 —— 命中的是同一份东西,不改变既有行为。
        var expected: String?
        if let mainResourceURL = Bundle.main.resourceURL {
            let candidate = mainResourceURL
                .appendingPathComponent(packageResourceBundleName, isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            expected = candidate.path        // 没命中也记下来:非致命调用方要拿它如实展示「期望落点」
        }
        // ② 回退到 SwiftPM 的 `Bundle.module`。保留它是为了不依赖上面那条约定的唯一性
        //    (例如将来 SwiftPM 改布局、或有人直接跑构建目录里的可执行而 resourceURL 语义变了)。
        let viaModule = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")?.path
        if let viaModule { return viaModule }
        // ③ 两条都没命中。致命档当场崩(内核/配置缺了插件没法工作,快速失败优于带病运行);
        //    非致命档返回期望落点,由调用方去判存在性并如实呈现。
        if fatalIfMissing {
            fatalError("随包资源缺失: \(name)(期望落点: \(expected ?? "无法推算"))")
        }
        return expected ?? name
#else
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name).path
#endif
    }
}
