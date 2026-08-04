// a2 CLI 退出码契约(单一来源)。粗分类走退出码,细因走响应 `error.code`(见 wire.ts 的 `ErrorCode`)。
//
// 数值沿用旧 `aa` 已锁定的表(`Sources/AAContracts/ExitCodes.swift`,行为规范参考),
// 好让既有 agent 接入文档与脚本的判据不因改名而漂移:
//   0 成功 / 1 用法错 / 2 denied / 3 超时 / 4 daemon 不可达 / 5 能力业务失败 / 6 协议·校验错
// 03 票只用到 0、1、4;2/3/5/6 的使用面由 04(控制面)、08(仲裁)票接上,数值在此一次登记、后续不改。

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
      return ExitCode.usage;
    case ErrorCode.badRequest:
    case ErrorCode.unknownOp:
    case ErrorCode.internalError:
      return ExitCode.protocolError;
    default:
      return ExitCode.protocolError;
  }
}
