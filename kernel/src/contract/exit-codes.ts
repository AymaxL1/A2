// a2 CLI 退出码契约(单一来源)。粗分类走退出码,细因走响应 `error.code`(见 wire.ts 的 `ErrorCode`)。
//
// 数值沿用旧 `aa` 已锁定的表(`Sources/AAContracts/ExitCodes.swift`,行为规范参考),
// 好让既有 agent 接入文档与脚本的判据不因改名而漂移:
//   0 成功 / 1 用法错 / 2 denied / 3 超时 / 4 daemon 不可达 / 5 能力业务失败 / 6 协议·校验错
// 数值在此一次登记、后续不改。各值的产出面:
//   0/1/4 —— 03 票(status、用法错、daemon 不可达);
//   6     —— 03 票起即可达(坏包封/未知 op,以及自家 daemon 应答不符契约那条分支),04 票补上能力校验四码,
//            05 票补上「本平台没有已支持的 supervisor」;
//   2/5   —— 04 票(dangerous 默拒 = 2、能力业务失败 = 5);05 票把 5 的口径从「能力业务失败」放宽成
//            **「路走通了、事没办成」**(service 操作失败同档:装了没跑起来、supervisor 命令非零退出);
//            08 票给 2 补上另外两个来源:确认器明确拒绝、对端 UID 不符;
//   3     —— **08 票起有唯一产出面:`confirmation_timeout`**(确认器在场却没人做决定)。
//            客户端等不到响应仍归 4 —— "没人点"与"这条路走不通"是两件事。

import { ErrorCode } from "./wire.ts";

export const ExitCode = {
  /** 0 成功。 */
  success: 0,
  /** 1 用法错(CLI 参数/本地错,未触达 daemon 语义)。 */
  usage: 1,
  /** 2 denied(dangerous 被拒:无确认器时 fail-closed)。 */
  denied: 2,
  /** 3 超时。 */
  timeout: 3,
  /** 4 daemon 不可达(未安装/未运行/socket 不可连)。 */
  daemonUnreachable: 4,
  /** 5 执行了但没成(能力业务失败;05 票起也含 service 操作失败)。 */
  capabilityFailure: 5,
  /** 6 协议·校验错(非法请求 / schema 校验失败 / 未知 op)。 */
  protocolError: 6,
} as const;
export type ExitCode = (typeof ExitCode)[keyof typeof ExitCode];

/**
 * `error.code` → 退出码。未识别的 code 保守归 6(协议·校验错)——
 * 宁可让上层察觉「有个没预期的错」,也不吞成成功。
 */
export function exitCodeForErrorCode(code: string): number {
  switch (code) {
    case ErrorCode.daemonUnreachable:
      return ExitCode.daemonUnreachable;
    case ErrorCode.usage:
    // 「已经在跑」不是能力失败也不是协议错,而是"你这条命令这会儿不该发" —— 与用法错同一档。
    case ErrorCode.daemonAlreadyRunning:
    // 同一档(17 票):`--purge` 撞上系统代理仍处接管态。命令本身完全成立、什么都没做,
    // 只是**这会儿不该发** —— 敲一次 `a2 proxy off` 之后同一条命令就成立了。
    // 不归 5(那是"路走通了、事没办成",而这次连走都没走),也不归 6(那是"在这台机器/
    // 这个 bin 上根本不成立",而这次只是时机不对)。
    case ErrorCode.servicePurgeBlocked:
    // 同一档(17 票 CR 尾款):purge 站错了 home。命令没错、什么都没做,到那个 home 去执行
    // (或先把那边收拾干净)这条就成立了 —— 与上面两条是同一种"此刻/此地不该发"。
    case ErrorCode.servicePurgeHomeMismatch:
      return ExitCode.usage;
    // dangerous 被拒的两种:没人能替你确认(第①层默拒 / 在途降级)、有人看了但不同意(第③层)。
    case ErrorCode.confirmationUnavailable:
    case ErrorCode.confirmationDenied:
    // 对端 UID 不符 = 这条连接被**拒绝**,与 dangerous 被拒同一档(都是"不许",不是"你敲错了")。
    case ErrorCode.peerRejected:
      return ExitCode.denied;
    // 3 的首个也是唯一的产出面(08 票裁定):**确认器在场但没人做决定**。
    // 客户端连不上/等不到响应仍归 4(那是"这条路走不通"),与"人没点"是两件事。
    case ErrorCode.confirmationTimeout:
      return ExitCode.timeout;
    // 能力执行了但业务失败 —— 与"没执行成"分开,agent 据此决定要不要改参数重试。
    case ErrorCode.capabilityFailed:
    // service 操作同理:unit 写了、命令发了,但事没办成(supervisor 报错 / 装完没跑起来)。
    case ErrorCode.serviceOperationFailed:
    // mihomo 面五码同档:探测发了、命令走了,但这件事这会儿办不成 —— 报文里带的是「人类如何完成」,
    // 不是"你参数写错了"。特别地,`mihomo_not_managed` 是**红线的报文投影**(那份不归我管,我不动它),
    // 它也不是用法错:命令本身完全成立,只是对象不对。
    // `mihomo_not_enabled` / `mihomo_failed` 同理 —— 一个是"还没选模式",一个是"它此刻是坏的",
    // 两者的下一步都在 guidance 里写着(选模式 / 看 lastError 改配置再 restart)。
    case ErrorCode.mihomoUnreachable:
    case ErrorCode.mihomoNotManaged:
    case ErrorCode.mihomoNotEnabled:
    case ErrorCode.mihomoFailed:
    case ErrorCode.mihomoOperationFailed:
    // 代理面同档:控制面通了但这件事没办成 / networksetup 报错 / 订阅拉不到。
    // 「参数写错了」仍归 6(那是校验层的事),这三码说的都是"路走通了、事没办成"。
    case ErrorCode.proxyOperationFailed:
    case ErrorCode.systemProxyFailed:
    case ErrorCode.subscriptionFailed:
    // 插件面同档:进程真的起来了、协议也走通了,是**这次调用**没成(异常/非零退出/超时),
    // 或者**这次装载**没成(文件不在、不是零依赖单文件)。
    //
    // **超时为什么不归 3**:退出码 3 的语义是「人没点」(确认器在场却没人做决定,08 票裁的唯一产出面)。
    // 插件卡住与人没点是两件事,agent 的下一步也完全不同(改插件/加大超时 vs 去催人),
    // 合流只会让"重试还是别重试"这个判断变糊。这条是 11 票的显式取舍,不是遗漏。
    case ErrorCode.pluginFailed:
    case ErrorCode.pluginTimeout:
    case ErrorCode.pluginLoadFailed:
      return ExitCode.capabilityFailure;
    case ErrorCode.badRequest:
    case ErrorCode.unknownOp:
    case ErrorCode.internalError:
    case ErrorCode.unknownCapability:
    case ErrorCode.missingParameter:
    case ErrorCode.typeMismatch:
    case ErrorCode.invalidParams:
    // 「本平台没有已支持的 supervisor」不是你敲错了命令(1),也不是事没办成(5)——
    // 是这条请求在这台机器上根本不成立,与校验层拒绝同档。
    case ErrorCode.serviceUnsupportedPlatform:
    // 同理(15 票):`--copy-to-home` 在源码态的 bin 上根本不成立 —— 没有可分发的"自身"可拷。
    // 那条说的是这台机器,这条说的是这个 bin,同一档。
    case ErrorCode.serviceSelfCopyUnsupported:
    // 同理(17 票 CR 尾款立,18 票扩):`--purge` 在这个 `$A2_HOME` 上根本不成立 ——
    // **`non_default_home`(18 票后生产路径上唯一可达的那一档:不是缺省 `~/.a2`)**,
    // 或者它是 `/`、是家目录本身、是家目录的祖先(这三档已被上一条挡在前面,作纵深保留),
    // 或者它是一根符号链接(删链不删树)。上一条说的是这个 bin,这条说的是这个 home。
    // 与 1 的分界:1 那一档等状态变了同一条命令就成立,而这些形状**换不掉 `A2_HOME` 就永远不成立**。
    case ErrorCode.servicePurgeUnsafeHome:
    // 同理:Linux 上没有 `networksetup`,这条请求在那台机器上根本不成立。
    case ErrorCode.systemProxyUnsupported:
    // 长连接协议面的两条"你这条报文不成立":指向不存在/已收场的确认请求;没注册角色就干角色的活。
    case ErrorCode.confirmationUnknown:
    case ErrorCode.roleNotRegistered:
    // 插件说的话不合协议(describe 输出坏了 / 退出码不在词表 / 清单里有的工具它自己不认)——
    // 与 `unknown_capability` 同档:这条请求本身不成立,要改的是插件而不是参数。
    case ErrorCode.pluginProtocolError:
    // 指名道姓的那个插件没登记过 —— 同 `unknown_capability`。
    case ErrorCode.unknownPlugin:
      return ExitCode.protocolError;
    default:
      return ExitCode.protocolError;
  }
}
