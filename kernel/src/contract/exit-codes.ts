// a2 CLI 退出码契约(单一来源)。粗分类走退出码,细因走响应 `error.code`(见 wire.ts 的 `ErrorCode`)。
//
// 数值沿用旧 `aa` 已锁定的表(`Sources/AAContracts/ExitCodes.swift`,行为规范参考),
// 好让既有 agent 接入文档与脚本的判据不因改名而漂移:
//   0 成功 / 1 用法错 / 2 denied / 3 超时 / 4 daemon 不可达 / 5 能力业务失败 / 6 协议·校验错
// 数值在此一次登记、后续不改。各值的产出面:
//   0/1/4 —— 03 票(status、用法错、daemon 不可达);
//   6     —— 03 票起即可达(坏包封/未知 op,以及自家 daemon 应答不符契约那条分支),04 票补上能力校验四码;
//   2/5   —— 04 票(dangerous 默拒 = 2、能力业务失败 = 5);
//   3     —— 尚无产出面(客户端超时目前按 daemon 不可达归 4;确认超时归 08 票)。

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
  /** 5 能力业务失败(能力执行了但返回错误)。 */
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
    // dangerous 被拒(本版唯一的来源是"无确认器"的 fail-closed 默拒;08 票的用户拒绝/超时也归这档)。
    case ErrorCode.confirmationUnavailable:
      return ExitCode.denied;
    // 能力执行了但业务失败 —— 与"没执行成"分开,agent 据此决定要不要改参数重试。
    case ErrorCode.capabilityFailed:
      return ExitCode.capabilityFailure;
    case ErrorCode.badRequest:
    case ErrorCode.unknownOp:
    case ErrorCode.internalError:
    case ErrorCode.unknownCapability:
    case ErrorCode.missingParameter:
    case ErrorCode.typeMismatch:
    case ErrorCode.invalidParams:
      return ExitCode.protocolError;
    default:
      return ExitCode.protocolError;
  }
}
