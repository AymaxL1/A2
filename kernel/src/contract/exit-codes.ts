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
    // mihomo 面四码同档:探测发了、命令走了,但这件事这会儿办不成 —— 报文里带的是「人类如何完成」,
    // 不是"你参数写错了"。特别地,`mihomo_not_managed` 是**红线的报文投影**(那份不归我管,我不动它),
    // 它也不是用法错:命令本身完全成立,只是对象不对。
    case ErrorCode.mihomoUnreachable:
    case ErrorCode.mihomoBelowFloor:
    case ErrorCode.mihomoNotManaged:
    case ErrorCode.mihomoOperationFailed:
    // 代理面同档:控制面通了但这件事没办成 / networksetup 报错 / 订阅拉不到。
    // 「参数写错了」仍归 6(那是校验层的事),这三码说的都是"路走通了、事没办成"。
    case ErrorCode.proxyOperationFailed:
    case ErrorCode.systemProxyFailed:
    case ErrorCode.subscriptionFailed:
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
    // 同理:Linux 上没有 `networksetup`,这条请求在那台机器上根本不成立。
    case ErrorCode.systemProxyUnsupported:
    // 长连接协议面的两条"你这条报文不成立":指向不存在/已收场的确认请求;没注册角色就干角色的活。
    case ErrorCode.confirmationUnknown:
    case ErrorCode.roleNotRegistered:
      return ExitCode.protocolError;
    default:
      return ExitCode.protocolError;
  }
}
