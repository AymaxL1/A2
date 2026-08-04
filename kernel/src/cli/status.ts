// `a2 status` —— 内核运行态查询,全程走 UDS 往返(不靠"socket 文件在不在"这类旁证)。

import { callKernel } from "../client/kernel-client.ts";
import { Op, StatusResultSchema } from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { outcomeFromEnvelope, type CommandOutcome } from "./outcome.ts";

export async function statusCommand(paths: KernelPaths): Promise<CommandOutcome> {
  // 自家 daemon 的应答也照契约校验一次(outcomeFromEnvelope 负责),契约漂移在这里就被发现。
  return outcomeFromEnvelope(
    await callKernel(paths, Op.statusGet),
    "status",
    StatusResultSchema,
    ({ version, pid, uptimeMs, socketPath }) =>
      `a2 daemon 运行中(版本 ${version},pid ${pid},已运行 ${Math.floor(uptimeMs / 1000)}s,socket ${socketPath})`,
  );
}
