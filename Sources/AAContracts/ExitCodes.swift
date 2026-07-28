// AAContracts —— aa CLI 退出码契约(永久,单一来源)。
//
// 这是 agent/脚本据以判断结果的稳定契约:粗分类走退出码,细因走响应 `error.code`(见 `WireErrorCode`)。
// aa 只引用本表,绝不在 CLI 里散写魔数;05 票的 agent 接入文档也以本表为准。
//
// 锁定表(不要改动语义/数值):
//   0 成功
//   1 用法错(客户端侧 CLI 参数错/本地错,未触达宿主语义)
//   2 denied(dangerous 被拒;本票不产生,留给 04 票)
//   3 超时
//   4 宿主不可达
//   5 能力业务失败(能力执行了但返回错误)
//   6 协议/校验错(请求非法:未知能力 / schema 校验失败 / 缺必填参数 / 类型不符)

/// aa 退出码常量表(单一来源)。
public enum AAExitCode {
    /// 0 成功。
    public static let success: Int32 = 0
    /// 1 用法错(CLI 参数/本地错,未触达宿主语义)。
    public static let usage: Int32 = 1
    /// 2 denied(dangerous 被拒;04 票实现,本票不产生)。
    public static let denied: Int32 = 2
    /// 3 超时。
    public static let timeout: Int32 = 3
    /// 4 宿主不可达。
    public static let hostUnreachable: Int32 = 4
    /// 5 能力业务失败(能力执行了但返回错误)。
    public static let capabilityFailure: Int32 = 5
    /// 6 协议/校验错(未知能力 / 缺必填 / 类型不符 / schema 校验失败 / 非法请求)。
    public static let protocolError: Int32 = 6

    /// 退出码 → 一句简短语义标签(单一来源)。CLI 帮助表由此遍历生成,不再手写数字/语义,杜绝重复知识。
    /// 顺序即展示顺序(0…6);数字取自上面的常量,标签在此登记一次。
    public static let semantics: [(code: Int32, label: String)] = [
        (success,           "成功"),
        (usage,             "用法错(CLI 参数/本地错,未触达宿主语义)"),
        (denied,            "denied(dangerous 被拒;04 票实现,本票不产生)"),
        (timeout,           "超时"),
        (hostUnreachable,   "宿主不可达"),
        (capabilityFailure, "能力业务失败(能力执行了但返回错误)"),
        (protocolError,     "协议/校验错(未知能力 / 缺必填参数 / 类型不符 / schema 校验失败 / 非法请求)"),
    ]

    /// 把宿主响应里的 `error.code`(见 `WireErrorCode`)映射到退出码粗分类。
    /// 未识别的 code 保守归 6(协议/校验错)—— 宁可让上层察觉「有个没预期的错」,也不吞成成功。
    public static func forErrorCode(_ code: String) -> Int32 {
        switch code {
        case WireErrorCode.capabilityFailed:
            return capabilityFailure                     // 5:业务失败
        case WireErrorCode.denied:
            return denied                                // 2:被拒(04 票)
        case WireErrorCode.unknownCapability,
             WireErrorCode.missingParameter,
             WireErrorCode.typeMismatch,
             WireErrorCode.invalidParams,
             WireErrorCode.badRequest,
             WireErrorCode.unknownOp,
             WireErrorCode.notImplemented,
             WireErrorCode.encodeFailed:
            return protocolError                         // 6:协议/校验错
        default:
            return protocolError                         // 未知 code → 6
        }
    }
}
