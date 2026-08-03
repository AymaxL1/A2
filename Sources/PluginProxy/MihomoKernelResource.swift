import Foundation

/// PluginProxy 随包携带的唯一锁版内核。生产调用方绝不从 PATH 或环境变量解析可执行文件。
public enum MihomoKernelResource {
    public static let version = "v1.19.28"
    public static let sha256 = "55b7286331cb30a54b2564013b02b84a0c280e8b690bd1e5da4b9d4f4ca007ac"

    public static var executablePath: String {
        resourcePath("mihomo-darwin-arm64")
    }

    public static var defaultConfigPath: String {
        resourcePath("default-config.yaml")
    }

    /// SwiftPM 给带 resources 的 target 生成的资源 bundle 名 = `<包名>_<target名>.bundle`。
    /// 这里必须写死一次:12 票的 `.app` 里要在 `Bundle.module` 之外**先**按约定落点找它(见 resourcePath 注释)。
    /// 与 SwiftPM 生成的 `resource_bundle_accessor.swift` 里那个同名常量是同一个事实的两处书写 ——
    /// 包名或 target 名一改,两处一起变(改错的表现是 `.app` 里起宿主当场 fatalError,不会静默降级)。
    private static let packageResourceBundleName = "PROJECT_AA_PluginProxy.bundle"

    private static func resourcePath(_ name: String) -> String {
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
        if let mainResourceURL = Bundle.main.resourceURL {
            let candidate = mainResourceURL
                .appendingPathComponent(packageResourceBundleName, isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        // ② 回退到 SwiftPM 的 `Bundle.module`。保留它是为了不依赖上面那条约定的唯一性
        //    (例如将来 SwiftPM 改布局、或有人直接跑构建目录里的可执行而 resourceURL 语义变了)。
        //    它内部强解包 —— 真找不到就当场 fatalError,**刻意不吞**:内核缺失时静默降级比崩更危险。
        return Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")!.path
#else
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name).path
#endif
    }
}
