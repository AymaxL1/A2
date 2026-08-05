// 报文路由:一行进,一行出。
//
// 铁律:**永不抛**。任何输入(坏 JSON、缺字段、未知 op、handler 炸了)都必须变成一条合法的失败包封 ——
// 客户端拿到的永远是「一种形状」,这是 agent 面能一次 JSON.parse 就分支的前提。
//
// handler 只说 op 层的成败(`OpOutcome`),包封由本文件统一裹 —— 各 op 不手搓包封、不靠异常表达失败。
//
// 08 票起 handler 多拿一个 `connection`:角色是**连接的属性**,所以 `roles.register` 与
// `confirmations.resolve` 必须知道"这句话是哪条连接说的"。一问一答的 op 照旧不看它。

import {
  CapabilityCallParamsSchema,
  CapabilityDescribeParamsSchema,
  ConfirmationResolveParamsSchema,
  ErrorCode,
  Op,
  PluginAddParamsSchema,
  PluginRemoveParamsSchema,
  RequestEnvelopeSchema,
  RoleRegisterParamsSchema,
  encodeFrame,
  failureResponse,
  opFailure,
  opSuccess,
  payload,
  pushEnvelope,
  successResponse,
  type OpOutcome,
  type RequestEnvelope,
} from "../contract/wire.ts";
import {
  addPlugin,
  listPlugins,
  removePlugin,
  type PluginHostContext,
} from "../plugin/host.ts";
import type { ClientConnection } from "./hub.ts";
import { statusSnapshot, type KernelRuntime } from "./runtime.ts";

/** 插件宿主要的那四样,全在运行态里现成 —— op 层只负责把它们凑到一起。 */
function pluginContext(runtime: KernelRuntime): PluginHostContext {
  return {
    paths: runtime.paths,
    registry: runtime.registry,
    audit: runtime.audit,
    hub: runtime.hub,
    env: runtime.env,
  };
}

type OpHandler = (
  request: RequestEnvelope,
  runtime: KernelRuntime,
  connection: ClientConnection,
) => OpOutcome | Promise<OpOutcome>;

/** op → handler。 */
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

  [Op.capabilitiesCall]: async (request, runtime, connection) => {
    const params = CapabilityCallParamsSchema.safeParse(request.params ?? {});
    if (!params.success) return invalidParams("capabilities.call", params.error.message);

    // 仲裁与校验全在 registry.invoke 里 —— 裸 UDS 直连走的也是这一条路,绕不过去。
    const outcome = await runtime.registry.invoke(params.data.capability, params.data.input ?? {}, {
      confirmerPresent: () => runtime.confirmerPresent(),
      refuseWithoutConfirmer: (descriptor) => runtime.arbiter.refuseWithoutConfirmer(descriptor),
      // 「我把你这条转给人了,最多等这么久」—— 只发给**发起方那条连接**,别的订阅者与此无关。
      confirm: (descriptor, input) =>
        runtime.arbiter.confirm(
          descriptor,
          input,
          (pending, timeoutMs) => {
            connection.send(
              encodeFrame(
                pushEnvelope({
                  kind: "confirmation-pending",
                  at: new Date().toISOString(),
                  requestId: request.id,
                  timeoutMs,
                  confirmation: pending,
                }),
              ),
            );
          },
          // 发起方是**这条连接**:它断了,这次确认就该取消(没人在等答案了)。
          connection,
        ),
    });
    if (!outcome.ok) return outcome;

    // 状态变了就广播一次:订阅者据此直接投影,不必回头再查(零轮询)。
    // **只对 normal / dangerous 发** —— safe 是只读,发了是噪音。
    const risk = runtime.registry.describe(params.data.capability)?.risk;
    if (risk === "normal" || risk === "dangerous") {
      runtime.hub.broadcast({
        kind: "capability",
        at: new Date().toISOString(),
        capability: { capability: params.data.capability, risk, output: outcome.result },
      });
    }
    // 注册表只管"能力吐了什么"(output),线上的 result 形状由 op 层拼(带上 capability 便于对号)。
    return opSuccess({ capability: params.data.capability, output: outcome.result });
  },

  // MARK: 插件面(11 票)——**装载零闸**:这三条不经任何仲裁,与 `capabilities.call` 的 dangerous 分支
  // 是两回事(ADR 0011:装载不设闸,危险性只在**调用层**把关)。留痕由 host 自己发(审计 + 能力增量)。

  [Op.pluginAdd]: async (request, runtime) => {
    const params = PluginAddParamsSchema.safeParse(request.params ?? {});
    if (!params.success) return invalidParams("plugin.add", params.error.message);
    return await addPlugin(pluginContext(runtime), params.data);
  },

  [Op.pluginList]: (_request, runtime) => listPlugins(pluginContext(runtime)),

  [Op.pluginRemove]: async (request, runtime) => {
    const params = PluginRemoveParamsSchema.safeParse(request.params ?? {});
    if (!params.success) return invalidParams("plugin.remove", params.error.message);
    return await removePlugin(pluginContext(runtime), params.data.plugin);
  },

  [Op.rolesRegister]: (request, runtime, connection) => {
    const params = RoleRegisterParamsSchema.safeParse(request.params ?? {});
    if (!params.success) return invalidParams("roles.register", params.error.message);

    const added = runtime.hub.register(connection, params.data.role, params.data.identity);
    // **快照先取**:它必须反映"我已经在里面了"的那一刻,而且要在任何推送发出去之前定格。
    const snapshot = runtime.snapshot();
    if (added) {
      // 进场事件推给**别人**,不推给刚注册的自己 —— 它的成员关系已经含在上面那份快照里,
      // 再推一次会让严格按「快照 + 增量」记账的客户端重复计入(契约见 `KernelSnapshotSchema` 头注)。
      runtime.audit.record(
        {
          action: params.data.role === "confirm-agent" ? "confirmer_joined" : "subscriber_joined",
          client: {
            role: params.data.role,
            name: params.data.identity.name,
            ...(connection.uid === undefined ? {} : { uid: connection.uid }),
          },
          detail: `连接 ${connection.id} 注册为 ${params.data.role}。V1 不校验身份声明(已知边界:同 UID 冒充)。`,
        },
        { exceptPush: connection },
      );
      // 确认器进场 = dangerous 从"走不通"变成"要等人点头",这条事实要让**别的**订阅者知道。
      runtime.arbiter.rosterChanged(connection);
    }

    return opSuccess(
      payload({
        role: params.data.role,
        connection: connection.id,
        ...(connection.uid === undefined ? {} : { uid: connection.uid }),
        roles: [...connection.roles],
        // **注册与首帧快照是同一次往返**,而且这条响应是本连接上的**第一帧**:
        // 没有"注册成功了但还没拿到状态"的中间态,也没有"增量先于基线"的窗口。
        snapshot,
      }),
    );
  },

  [Op.confirmationsResolve]: (request, runtime, connection) => {
    const params = ConfirmationResolveParamsSchema.safeParse(request.params ?? {});
    if (!params.success) return invalidParams("confirmations.resolve", params.error.message);

    // **角色是连接的属性,不是报文里的一句自称**:没注册 confirm-agent 就没有替人做决定的资格。
    if (!connection.roles.has("confirm-agent")) {
      return opFailure({
        code: ErrorCode.roleNotRegistered,
        message: "这条连接没有注册 confirm-agent 角色,不能替人做确认决定。",
        detail:
          "确认器必须先在本连接上 `roles.register`(role=confirm-agent)并保持连接;" +
          "断线即离场,重连后要重新注册。",
        guidance: {
          summary: "先在同一条长连接上注册确认器角色,再回应确认请求。",
          steps: [
            { description: "在这条连接上发 roles.register(role=confirm-agent)" },
            { description: "收到 confirmation 事件后,用它的 id 发 confirmations.resolve" },
          ],
          context: { connection: connection.id },
        },
      });
    }

    const refusal = runtime.arbiter.resolve(
      params.data.confirmation,
      params.data.decision,
      {
        connection: connection.id,
        ...(connection.identity?.name === undefined ? {} : { name: connection.identity.name }),
        ...(connection.uid === undefined ? {} : { uid: connection.uid }),
      },
      params.data.reason,
    );
    if (refusal) return opFailure(refusal);
    return opSuccess({
      confirmation: params.data.confirmation,
      decision: params.data.decision,
      settled: true,
    });
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
export async function handleLine(
  line: string,
  runtime: KernelRuntime,
  connection: ClientConnection,
): Promise<string> {
  return encodeFrame(await handleRequestLine(line, runtime, connection));
}

async function handleRequestLine(
  line: string,
  runtime: KernelRuntime,
  connection: ClientConnection,
) {
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
    const outcome = await handler(envelope.data, runtime, connection);
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
