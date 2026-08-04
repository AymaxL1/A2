// A2KernelClient —— 客户端侧的错误分类。
//
// 分类口径与内核的退出码语义对齐(客户端不发明新的世界观):
//   * 连不上 / 连上又断了 → `daemonUnreachable` / `connectionClosed`(内核退出码 4 的那一族);
//   * 内核答了但说"不行" → `kernelRefused`,**理由原样带着**(含 guidance —— 拒绝即指引);
//   * 内核答了但不是本协议 → `protocolViolation`(宁可吵,不猜);
//   * 到点了还没答 → `timeout`。

import Foundation
import A2Contract

public enum A2ClientError: Error, CustomStringConvertible {
    /// socket 连不上(daemon 未装 / 未起 / 路径不对)。**客户端永不隐式拉起 daemon**。
    case daemonUnreachable(String)
    /// 连接中途断了(内核退出、被拒、写失败)。
    case connectionClosed(String)
    /// 对方说的不是本协议(非 JSON、不符包封 schema、判别字段缺失)。
    case protocolViolation(String)
    /// 到点了内核还没给出这条请求的响应。
    case timeout(String)
    /// 内核明确回了失败包封 —— **理由原样带着**(`guidance` 就在里面,壳要原样展示)。
    case kernelRefused(A2WireError)

    public var description: String {
        switch self {
        case let .daemonUnreachable(detail): return "内核不可达:\(detail)"
        case let .connectionClosed(detail): return "连接已断:\(detail)"
        case let .protocolViolation(detail): return "响应不符合线协议:\(detail)"
        case let .timeout(detail): return "等响应超时:\(detail)"
        case let .kernelRefused(error): return "内核拒绝(\(error.code)):\(error.message)"
        }
    }
}
