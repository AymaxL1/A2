// AAHostMacOS —— NetworkConfigPort 真实现(NetworkSetupPort,调 `networksetup`)+ 文件后端假件(test-only E2E seam)。
// 依赖边:AAHostMacOS → AAPluginSDK(NetworkConfigPort 协议 / 值类型)、Foundation。
//
// 07 票:系统代理接管/还原的「真副作用」落点在宿主。真实现调 macOS 的 `/usr/sbin/networksetup`(per-service per-kind);
//   E2E 绝不碰真设置——宿主经 env seam(AA_NETWORKSETUP_FAKE_STATE)改用文件后端假件读写一个 JSON 状态文件,
//   check.sh 据该文件断言「接管指向内核端口 / 精确还原 / 退出后复原」。
//
// ⚠️ FileBackedNetworkConfigPort 是 **test-only**(与 AA_CONFIRM_AUTO / AA_MIHOMO_KERNEL_PATH 同口径的 env seam):
//    12/13 真机分发前按需保留/门控。安全缺省是真 NetworkSetupPort;不设该 env 变量时绝不走文件后端。

import Foundation
import AAPluginSDK

/// 系统代理读写的错误(真实现/文件后端共用)。
public enum NetworkConfigError: Error, Equatable {
    case toolFailed(String)          // networksetup 非零退出 / 无法启动
    case unknownService(String)      // 未知网络服务
    case stateFileUnreadable(String) // 文件后端:状态文件读/解失败
    case stateFileUnwritable(String) // 文件后端:状态文件写失败
}

// ============ 真实现:调 networksetup ============

/// 基于 `/usr/sbin/networksetup` 的 NetworkConfigPort 真实现(per-service per-kind)。
/// **check.sh 从不驱动它**(E2E 全走文件后端假件);真机验证留用户。
///
/// 真机验证点(记债,check.sh 不驱动,留人肉验证):
///   * `set*` 系操作通常需要管理员权限(sudo / 授权),无权时 networksetup 会失败——本层如实抛 toolFailed。
///   * VPN / PPP / 部分虚拟服务可能拒绝 `-setwebproxy`;`-listallnetworkservices` 亦可能列出不适用服务。
///   * 「原本关闭但 Server 字段有残值」的服务,`-setwebproxystate off` 只关状态、不清 Server,UI 可能残留旧地址(无害)。
///   * 上述均属真机场景,须在有真实网络服务的机器上人肉核验读回一致性。
public final class NetworkSetupPort: NetworkConfigPort, @unchecked Sendable {
    private let toolPath = "/usr/sbin/networksetup"

    public init() {}

    public func networkServices() throws -> [String] {
        let out = try run(["-listallnetworkservices"])
        // 首行是说明抬头(An asterisk ...),跳过;`*` 前缀 = 已禁用的服务,跳过;空行跳过。
        return out.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    public func proxyState(service: String) throws -> ServiceProxyState {
        ServiceProxyState(
            service: service,
            http:  try readProxy(getArg: "-getwebproxy", service: service),
            https: try readProxy(getArg: "-getsecurewebproxy", service: service),
            socks: try readProxy(getArg: "-getsocksfirewallproxy", service: service)
        )
    }

    public func setProxy(service: String, kind: ProxyKind, host: String, port: Int) throws {
        // 防呆:无效目标(端口 <=0 / host 空)绝不发 `-setwebproxy <svc> <host> 0`——真机 networksetup 会拒并拖垮整条还原。
        //   语义上「端口无效的代理」== 未配置,按「关闭该 kind」处理(如实记日志),让还原不因一个坏值抛败。
        //   此坏值主要来自读回解析失败(见 readProxy):enabled=Yes 但 Port 解析不出而落 0。
        guard port > 0, !host.isEmpty else {
            FileHandle.standardError.write(Data(
                "[AAHost] NetworkSetupPort: 跳过无效代理 set(\(service)/\(kind.rawValue) host=\"\(host)\" port=\(port)),按关闭处理\n".utf8))
            try disableProxy(service: service, kind: kind)
            return
        }
        _ = try run([setArg(kind), service, host, String(port)])
        // networksetup 的 set* 会顺带把该类代理置为 on;个别版本需显式确保开启,再补一发 state on(幂等)。
        _ = try run([stateArg(kind), service, "on"])
    }

    public func disableProxy(service: String, kind: ProxyKind) throws {
        _ = try run([stateArg(kind), service, "off"])
    }

    // —— networksetup 子命令映射 ——
    private func setArg(_ kind: ProxyKind) -> String {
        switch kind {
        case .http:  return "-setwebproxy"
        case .https: return "-setsecurewebproxy"
        case .socks: return "-setsocksfirewallproxy"
        }
    }
    private func stateArg(_ kind: ProxyKind) -> String {
        switch kind {
        case .http:  return "-setwebproxystate"
        case .https: return "-setsecurewebproxystate"
        case .socks: return "-setsocksfirewallproxystate"
        }
    }

    /// 解析 `-getwebproxy` 一类的输出:
    ///   Enabled: Yes/No
    ///   Server: <host>
    ///   Port: <port>
    private func readProxy(getArg: String, service: String) throws -> ProxySetting {
        let out = try run([getArg, service])
        var enabled = false, host = "", port = 0
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "enabled": enabled = (parts[1].lowercased() == "yes")
            case "server":  host = parts[1]
            case "port":    port = Int(parts[1]) ?? 0
            default: break
            }
        }
        return enabled ? ProxySetting(enabled: true, host: host, port: port) : .off
    }

    /// 同步跑 networksetup;非零退出抛错。
    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: toolPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            throw NetworkConfigError.toolFailed("无法启动 networksetup: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard proc.terminationStatus == 0 else {
            throw NetworkConfigError.toolFailed("networksetup \(args.joined(separator: " ")) 退出码=\(proc.terminationStatus): \(out)")
        }
        return out
    }
}

// ============ 文件后端假件(test-only env seam)============

/// 文件后端假 NetworkConfigPort(**test-only**):把「系统代理状态」持久化到一个 JSON 文件,读写全在文件上,
/// **绝不触碰真 networksetup**。供 headless E2E 注入(AA_NETWORKSETUP_FAKE_STATE=<path>),check.sh 据该文件断言。
///
/// 文件格式(与 check.sh 约定):`{"services":[ ServiceProxyState... ]}`(JSONEncoder sortedKeys 编码)。
public final class FileBackedNetworkConfigPort: NetworkConfigPort, @unchecked Sendable {
    /// 状态文件的 Codable 容器(与 check.sh 约定的 JSON 形状一致)。
    private struct StateFile: Codable {
        var services: [ServiceProxyState]
    }

    private let path: String
    private let lock = NSLock()

    public init(statePath: String) {
        self.path = statePath
    }

    private func load() throws -> StateFile {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let state = try? JSONDecoder().decode(StateFile.self, from: data) else {
            throw NetworkConfigError.stateFileUnreadable(path)
        }
        return state
    }

    private func save(_ state: StateFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state),
              (try? data.write(to: URL(fileURLWithPath: path))) != nil else {
            throw NetworkConfigError.stateFileUnwritable(path)
        }
    }

    public func networkServices() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try load().services.map { $0.service }
    }

    public func proxyState(service: String) throws -> ServiceProxyState {
        lock.lock(); defer { lock.unlock() }
        guard let s = try load().services.first(where: { $0.service == service }) else {
            throw NetworkConfigError.unknownService(service)
        }
        return s
    }

    public func setProxy(service: String, kind: ProxyKind, host: String, port: Int) throws {
        lock.lock(); defer { lock.unlock() }
        var state = try load()
        guard let idx = state.services.firstIndex(where: { $0.service == service }) else {
            throw NetworkConfigError.unknownService(service)
        }
        state.services[idx] = state.services[idx].replacing(kind, with: ProxySetting(enabled: true, host: host, port: port))
        try save(state)
    }

    public func disableProxy(service: String, kind: ProxyKind) throws {
        lock.lock(); defer { lock.unlock() }
        var state = try load()
        guard let idx = state.services.firstIndex(where: { $0.service == service }) else {
            throw NetworkConfigError.unknownService(service)
        }
        // 关闭态归零 host/port(便于 E2E「终态=接管前快照」的语义对比;真实现走 networksetup 不清 host/port)。
        state.services[idx] = state.services[idx].replacing(kind, with: .off)
        try save(state)
    }
}
