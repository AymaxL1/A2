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

    private static func resourcePath(_ name: String) -> String {
#if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")!.path
#else
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name).path
#endif
    }
}
