// 报文路由:一行进,一行出。
//
// 铁律:**永不抛**。任何输入(坏 JSON、缺字段、未知 op、handler 炸了)都必须变成一条合法的失败包封 ——
// 客户端拿到的永远是「一种形状」,这是 agent 面能一次 JSON.parse 就分支的前提。

import {
  ErrorCode,
  Op,
  RequestEnvelopeSchema,
  encodeFrame,
  failureResponse,
  successResponse,
  type JsonValue,
  type RequestEnvelope,
} from "../contract/wire.ts";
import { statusSnapshot, type KernelRuntime } from "./runtime.ts";

type OpHandler = (request: RequestEnvelope, runtime: KernelRuntime) => JsonValue;

/** op → handler。04 票的控制面命令、08 票的角色注册都往这张表上挂。 */
const HANDLERS: Record<string, OpHandler> = {
  [Op.statusGet]: (_request, runtime) => statusSnapshot(runtime),
};

/** 已登记 op 清单(错误细节里回给客户端,省得对方翻文档)。 */
const KNOWN_OPS = Object.keys(HANDLERS).sort();

/** 处理一行请求,返回一帧响应(含换行)。 */
export function handleLine(line: string, runtime: KernelRuntime): string {
  return encodeFrame(handleRequestLine(line, runtime));
}

function handleRequestLine(line: string, runtime: KernelRuntime) {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch (error) {
    return failureResponse(crypto.randomUUID(), {
      code: ErrorCode.badRequest,
      message: "请求不是合法 JSON。",
      detail: String(error),
    });
  }

  const envelope = RequestEnvelopeSchema.safeParse(parsed);
  if (!envelope.success) {
    return failureResponse(salvageId(parsed), {
      code: ErrorCode.badRequest,
      message: "请求不符合请求包封契约。",
      detail: envelope.error.message,
    });
  }

  const handler = HANDLERS[envelope.data.op];
  if (!handler) {
    return failureResponse(envelope.data.id, {
      code: ErrorCode.unknownOp,
      message: `未知 op:${envelope.data.op}`,
      detail: `本版内核已登记的 op:${KNOWN_OPS.join("、")}`,
    });
  }

  try {
    return successResponse(envelope.data.id, handler(envelope.data, runtime));
  } catch (error) {
    return failureResponse(envelope.data.id, {
      code: ErrorCode.internalError,
      message: "内核处理请求时发生未预期的错误。",
      detail: String(error),
    });
  }
}

/** 包封不合法时尽量把对方的 id 捞回来,好让客户端仍能对上号;捞不到就现造一个(id 必须非空)。 */
function salvageId(parsed: unknown): string {
  if (parsed !== null && typeof parsed === "object" && "id" in parsed) {
    const id = (parsed as { id: unknown }).id;
    if (typeof id === "string" && id.length > 0) return id;
  }
  return crypto.randomUUID();
}
