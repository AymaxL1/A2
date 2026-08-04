// 报文路由:一行进,一行出。
//
// 铁律:**永不抛**。任何输入(坏 JSON、缺字段、未知 op、handler 炸了)都必须变成一条合法的失败包封 ——
// 客户端拿到的永远是「一种形状」,这是 agent 面能一次 JSON.parse 就分支的前提。
//
// handler 只说 op 层的成败(`OpOutcome`),包封由本文件统一裹 —— 各 op 不手搓包封、不靠异常表达失败。

import {
  CapabilityCallParamsSchema,
  CapabilityDescribeParamsSchema,
  ErrorCode,
  Op,
  RequestEnvelopeSchema,
  encodeFrame,
  failureResponse,
  opFailure,
  opSuccess,
  successResponse,
  type OpOutcome,
  type RequestEnvelope,
} from "../contract/wire.ts";
import { statusSnapshot, type KernelRuntime } from "./runtime.ts";

type OpHandler = (
  request: RequestEnvelope,
  runtime: KernelRuntime,
) => OpOutcome | Promise<OpOutcome>;

/** op → handler。08 票的角色注册也往这张表上挂。 */
const HANDLERS: Record<string, OpHandler> = {
  [Op.statusGet]: (_request, runtime) => opSuccess(statusSnapshot(runtime)),

  [Op.capabilitiesList]: (_request, runtime) =>
    opSuccess({ capabilities: runtime.registry.list() }),

  [Op.capabilitiesDescribe]: (request, runtime) => {
    const params = CapabilityDescribeParamsSchema.safeParse(request.params ?? {});
    if (!params.success) return invalidParams("capabilities.describe", params.error.message);

    const descriptor = runtime.registry.describe(params.data.capability);
    if (!descriptor) return opFailure(runtime.registry.unknownCapabilityError(params.data.capability));
    return opSuccess({ descriptor });
  },

  [Op.capabilitiesCall]: async (request, runtime) => {
    const params = CapabilityCallParamsSchema.safeParse(request.params ?? {});
    if (!params.success) return invalidParams("capabilities.call", params.error.message);

    // 仲裁与校验全在 registry.invoke 里 —— 裸 UDS 直连走的也是这一条路,绕不过去。
    const outcome = await runtime.registry.invoke(params.data.capability, params.data.input ?? {}, {
      confirmerPresent: runtime.confirmerPresent(),
      paths: runtime.paths,
    });
    // 注册表只管"能力吐了什么"(output),线上的 result 形状由 op 层拼(带上 capability 便于对号)。
    return outcome.ok
      ? opSuccess({ capability: params.data.capability, output: outcome.result })
      : outcome;
  },
};

function invalidParams(op: string, detail: string): OpOutcome {
  return opFailure({
    code: ErrorCode.invalidParams,
    message: `${op} 的 params 不符合契约。`,
    detail,
  });
}

/** 已登记 op 清单(错误细节里回给客户端,省得对方翻文档)。 */
const KNOWN_OPS = Object.keys(HANDLERS).sort();

/** 处理一行请求,返回一帧响应(含换行)。 */
export async function handleLine(line: string, runtime: KernelRuntime): Promise<string> {
  return encodeFrame(await handleRequestLine(line, runtime));
}

async function handleRequestLine(line: string, runtime: KernelRuntime) {
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
    const outcome = await handler(envelope.data, runtime);
    return outcome.ok
      ? successResponse(envelope.data.id, outcome.result)
      : failureResponse(envelope.data.id, outcome.error);
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
