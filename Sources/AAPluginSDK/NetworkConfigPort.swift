// AAPluginSDK —— NetworkConfigPort:系统代理读写边界(特权面归宿主)。
// 依赖边:AAPluginSDK → AAContracts(+ Foundation)。绝不 import 任何 Host*。
//
// 07 票:系统代理接管/还原。macOS 的系统代理是 per-network-service(Wi-Fi / Ethernet …)× per-protocol
//   (HTTP / HTTPS / SOCKS)模型,由 `networksetup` 逐项读写。本 Port 把这层「真副作用」抽象出来:
//     * 真实现(AAHostMacOS.NetworkSetupPort)= 调 `networksetup`;
//     * 文件后端假件(AAHostMacOS.FileBackedNetworkConfigPort,test-only env seam)= 读写 JSON 状态文件,供 E2E 断言,绝不碰真设置;
//     * 内存假件(AAHostTestKit.FakeNetworkConfigPort)= 纯逻辑单测用。
//   插件(PluginProxy)只面向本协议编程:快照/接管/还原全是纯逻辑,注入假件即可断言,绝不直连 macOS。
//
// 铁律落点:协议 + 值类型定义在 SDK(插件只依赖 SDK);真实现/假件在 Host* 侧。粒度严格对齐 networksetup 的
//   per-service per-kind 模型——这样「原本就有第三方代理」的服务能被逐项精确快照与还原(而非一律关闭)。

import Foundation

/// 一种代理协议档(对齐 networksetup 的三类子命令)。
/// - `http`  ↔ `-getwebproxy` / `-setwebproxy` / `-setwebproxystate`
/// - `https` ↔ `-getsecurewebproxy` / `-setsecurewebproxy` / `-setsecurewebproxystate`
/// - `socks` ↔ `-getsocksfirewallproxy` / `-setsocksfirewallproxy` / `-setsocksfirewallproxystate`
public enum ProxyKind: String, Sendable, Equatable, Codable, CaseIterable {
    case http
    case https
    case socks
}

/// 单个服务上某一类代理的状态(开关 + host + port)。Codable 以便随快照持久化(08 崩溃自愈埋点)。
/// 关闭态约定 `enabled=false, host="", port=0`(host/port 无意义时取空/零,便于持久化与断言)。
public struct ProxySetting: Sendable, Equatable, Codable {
    public let enabled: Bool
    public let host: String
    public let port: Int

    public init(enabled: Bool, host: String, port: Int) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    /// 关闭态常量(host/port 归零)。
    public static let off = ProxySetting(enabled: false, host: "", port: 0)
}

/// 一个网络服务(如 "Wi-Fi" / "Ethernet")的三类代理状态快照。
/// 这是接管/还原的最小粒度单元:HTTP/HTTPS/SOCKS 各自独立(某服务可能只 HTTP 走了第三方代理、SOCKS 关着)。
public struct ServiceProxyState: Sendable, Equatable, Codable {
    public let service: String
    public let http: ProxySetting
    public let https: ProxySetting
    public let socks: ProxySetting

    public init(service: String, http: ProxySetting, https: ProxySetting, socks: ProxySetting) {
        self.service = service
        self.http = http
        self.https = https
        self.socks = socks
    }

    /// 取某一类代理的当前设置。
    public func setting(for kind: ProxyKind) -> ProxySetting {
        switch kind {
        case .http:  return http
        case .https: return https
        case .socks: return socks
        }
    }

    /// 返回把某一类代理替换为新设置后的副本(值语义,不改自身)。
    public func replacing(_ kind: ProxyKind, with setting: ProxySetting) -> ServiceProxyState {
        switch kind {
        case .http:  return ServiceProxyState(service: service, http: setting, https: https, socks: socks)
        case .https: return ServiceProxyState(service: service, http: http, https: setting, socks: socks)
        case .socks: return ServiceProxyState(service: service, http: http, https: https, socks: setting)
        }
    }
}

/// 系统代理读写边界(per-service per-kind,对齐 networksetup)。
///
/// 语义契约:
/// - `networkServices`:枚举当前(相关)网络服务名。真实现跳过说明抬头与 `*` 前缀的已禁用服务。
/// - `proxyState`:读某服务的三类代理状态(开关 + host + port)。未知服务抛错。
/// - `setProxy`:把某服务某类代理指向 `host:port` 并开启(幂等)。
/// - `disableProxy`:关闭某服务某类代理(幂等)。
///
/// `Sendable`:全为值类型入参/出参;其存在化类型 `any NetworkConfigPort` 因而可被 Sendable 的插件安全持有并跨线程调用。
public protocol NetworkConfigPort: Sendable {
    func networkServices() throws -> [String]
    func proxyState(service: String) throws -> ServiceProxyState
    func setProxy(service: String, kind: ProxyKind, host: String, port: Int) throws
    func disableProxy(service: String, kind: ProxyKind) throws
}
