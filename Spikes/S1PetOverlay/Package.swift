// swift-tools-version:6.0
// PROTOTYPE — S1 宠物悬浮窗 spike，抛弃式代码，不进产品。见同目录 README.md。
import PackageDescription

let package = Package(
    name: "S1PetOverlay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "S1PetOverlay",
            path: "Sources/S1PetOverlay"
        )
    ],
    swiftLanguageVersions: [.v5]
)
