// `a2 status` —— 内核运行态查询,全程走 UDS 往返(不靠"socket 文件在不在"这类旁证)。

import { callKernel } from "../client/kernel-client.ts";
import { ExitCode, exitCodeForErrorCode } from "../contract/exit-codes.ts";
import { ErrorCode, Op, StatusResultSchema, failureResponse } from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { renderWireError, type CommandOutcome } from "./outcome.ts";

export async function statusCommand(paths: KernelPaths): Promise<CommandOutcome> {
  const envelope = await callKernel(paths, Op.statusGet);
  if (!envelope.ok) {
    return {
      envelope,
      human: renderWireError(envelope.error),
      exitCode: exitCodeForErrorCode(envelope.error.code),
    };
  }

  // 自家 daemon 的应答也照契约校验一次:契约漂移要在这里就被发现,而不是让 agent 拿到怪 JSON。
  const status = StatusResultSchema.safeParse(envelope.result);
  if (!status.success) {
    const failure = failureResponse(envelope.id, {
      code: ErrorCode.badRequest,
      message: "daemon 返回的 status 结果不符合契约。",
      detail: status.error.message,
    });
    return {
      envelope: failure,
      human: renderWireError(failure.error),
      exitCode: ExitCode.protocolError,
    };
  }

  const { version, pid, uptimeMs, socketPath } = status.data;
  const uptimeSeconds = Math.floor(uptimeMs / 1000);
  return {
    envelope,
    human: `a2 daemon 运行中(版本 ${version},pid ${pid},已运行 ${uptimeSeconds}s,socket ${socketPath})`,
    exitCode: ExitCode.success,
  };
}
