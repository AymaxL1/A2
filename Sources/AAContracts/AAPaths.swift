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

    /// 订阅数据子目录名(10 票):清单 catalog.json + 物化配置 configs/<id>.conf 都落这里(与 socket 同在 AA 子目录下)。
    public static let subscriptionsSubdirectory = "subscriptions"

    /// 订阅数据目录绝对路径(10 票)。生产缺省用此路径;test-only env seam `AA_SUBSCRIPTION_DIR` 可覆盖到临时区
    /// (E2E 绝不污染真实 AppSupport;与 AA_TAKEOVER_STATE_PATH 同口径,12/13 前按需门控)。
    /// 布局:catalog = `<dir>/catalog.json`;物化配置 = `<dir>/configs/<id>.conf`。
    public static var subscriptionsDirectory: String {
        socketDirectoryURL.appendingPathComponent(subscriptionsSubdirectory, isDirectory: true).path
    }

    // MARK: - agent 委托(agent-delegation 04:任务工作区根目录)

    /// AA 用户域根目录名(`~/.aa`)。agent 委托任务工作区落在它下面。
    ///
    /// 为何不复用上面的 Application Support 路径:那条路径是**运行时**产物(socket)的家,
    ///   用户不会去翻;而 agent 任务工作区是**用户要亲自 `cd` 进去、`tail -f`、`open report.html`** 的东西
    ///   (提案 §5 的三种消费姿态),放在 `~/.aa/` 下才敲得动。二者定位不同,故是两条路径。
    public static let userRootDirectoryName = ".aa"

    /// agent 委托任务工作区根目录(`~/.aa/agent-tasks/`)。**单一来源,禁止各处各拼**。
    ///
    /// 目录结构由 `AAAgentCore.AgentTaskWorkspace` 拥有(03 票《任务工作区结构提案》);
    /// 这里只负责回答「根在哪」,好让 CLI / 宿主 / 适配层不会各写各的路径字面量。
    public static var agentTasksRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(userRootDirectoryName, isDirectory: true)
            .appendingPathComponent("agent-tasks", isDirectory: true)
            .path
    }
}
