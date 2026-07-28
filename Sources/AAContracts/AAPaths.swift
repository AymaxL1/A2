// AAContracts —— 运行时路径常量。UDS socket 路径在此定义一次,宿主与 aa 都从这里读,禁止各写各的。
//
// 位置:`~/Library/Application Support/AA/aa.sock`(用户域 Application Support 下的 AA 子目录)。
//   * 落在运行时目录,不进仓库(E2E 用的 socket 也在此,别落进工作区)。
//   * 父目录由宿主启动时自建;旧 socket 文件由宿主启动时 unlink(UDS 文件不随进程退出自动清除)。
//   * 路径长度须 < sockaddr_un.sun_path 容量(macOS 为 104 字节),此路径远短于上限。

import Foundation

/// AA 运行时文件系统路径。
public enum AAPaths {
    /// Application Support 下的 AA 专属子目录名。
    public static let appSupportSubdirectory = "AA"

    /// UDS socket 文件名。
    public static let socketFileName = "aa.sock"

    /// 接管态清单文件名(08 崩溃自愈)。宿主接管系统代理成功时写入,正常退出还原成功时清除。
    /// 文件存在 == 「上一世代仍持有接管、可能残留」,下次启动据此自愈(见 PluginProxy.selfHeal)。
    public static let takeoverStateFileName = "takeover-state.json"

    /// socket 所在目录 URL(宿主用它 createDirectory)。
    public static var socketDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appSupportSubdirectory, isDirectory: true)
    }

    /// UDS socket 绝对路径。宿主 bind、aa connect 都读这个值。
    public static var socketPath: String {
        socketDirectoryURL.appendingPathComponent(socketFileName).path
    }

    /// 接管态清单绝对路径(08 崩溃自愈的持久化落点;与 socket 同在 AA 子目录)。
    /// 生产缺省用此路径;test-only env seam `AA_TAKEOVER_STATE_PATH` 可覆盖到临时区(E2E 绝不污染真实 AppSupport)。
    public static var takeoverStatePath: String {
        socketDirectoryURL.appendingPathComponent(takeoverStateFileName).path
    }
}
