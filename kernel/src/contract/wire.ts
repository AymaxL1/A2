// 线协议契约 —— **单一事实源**(ADR 0010:契约 TS 为源,导出 JSON Schema,Swift 侧手写 Codable 对照)。
//
// 传输形态(沿用 v1 的 UDS 逐行 JSON,并为将来的订阅推送留门):
//   * 帧 = 一行 UTF-8 JSON,以 '\n' 收尾(NDJSON)。
//   * 客户端连上后写一行请求,读一行响应;长连接上服务端可继续推行(08 票的订阅/确认器角色)。
//   * 每条报文自带 `v`(协议版本)与 `id`(相关性 id):响应的 `id` 原样回填请求的 `id`。
//
// 本文件只定义**基础报文族**(03 票):请求包封、响应包封、结构化错误、拒绝即指引。
// 具体 op 的 params/result 形状由各自的票追加(04 票控制面、08 票仲裁……)。

import { z } from "zod";

/** 线协议版本。不兼容变更才 +1;可选字段追加不算不兼容。 */
export const PROTOCOL_VERSION = 1;

/** 任意 JSON 值(result / params 的兜底类型)。 */
export const JsonValueSchema: z.ZodType<JsonValue> = z.lazy(() =>
  z.union([
    z.string(),
    z.number(),
    z.boolean(),
    z.null(),
    z.array(JsonValueSchema),
    z.record(z.string(), JsonValueSchema),
  ]),
);
export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

// MARK: - 拒绝即指引

/**
 * 指引的一步。`command` 是**给人类原样执行**的精确命令(agent 只转告、不代跑)。
 * 没有对应命令的说明步骤(如「在菜单栏点确认」)只填 description。
 */
export const GuidanceStepSchema = z.object({
  description: z.string().min(1),
  command: z.string().min(1).optional(),
});
export type GuidanceStep = z.infer<typeof GuidanceStepSchema>;

/**
 * 「拒绝即指引」载荷(ADR 0008 第 3/6 条):任何拒绝/不可用都带机器可读的「人类如何完成」。
 * `context` 是给 agent 免猜的事实(如展开后的 socketPath),值一律字符串,便于跨端对照。
 */
export const GuidanceSchema = z.object({
  summary: z.string().min(1),
  steps: z.array(GuidanceStepSchema).min(1),
  context: z.record(z.string(), z.string()).optional(),
});
export type Guidance = z.infer<typeof GuidanceSchema>;

// MARK: - 结构化错误

/**
 * 统一错误载荷。`code` 供机器分支(取值见 `ErrorCode`),`message` 给人/agent 读,
 * `detail` 放原始细节(异常文本等),`guidance` 在「这条路走不通」时必填。
 */
export const WireErrorSchema = z.object({
  code: z.string().min(1),
  message: z.string().min(1),
  detail: z.string().optional(),
  guidance: GuidanceSchema.optional(),
});
export type WireError = z.infer<typeof WireErrorSchema>;

/** 已登记的 `error.code`(基础族)。后续票只增不改,值即契约。 */
export const ErrorCode = {
  /** 请求不是合法 JSON,或不符合请求包封 schema。 */
  badRequest: "bad_request",
  /** 未知 op。 */
  unknownOp: "unknown_op",
  /** 内核内部异常(未预期的抛出)。 */
  internalError: "internal_error",
  /** daemon 未安装/未运行/socket 不可连 —— 客户端侧产生,必带指引,永不隐式拉起。 */
  daemonUnreachable: "daemon_unreachable",
  /** CLI 用法错(未知子命令、缺参数),未触达 daemon 语义。 */
  usage: "usage",
  /** 该 A2_HOME 下已经有一个 daemon 在监听 —— 不抢别人的 socket,报错退出。 */
  daemonAlreadyRunning: "daemon_already_running",
} as const;
export type ErrorCode = (typeof ErrorCode)[keyof typeof ErrorCode];

// MARK: - 包封

/** 请求包封。`op` 路由,`params` 由各 op 自行约束。 */
export const RequestEnvelopeSchema = z.object({
  v: z.literal(PROTOCOL_VERSION),
  id: z.string().min(1),
  op: z.string().min(1),
  params: z.record(z.string(), JsonValueSchema).optional(),
});
export type RequestEnvelope = z.infer<typeof RequestEnvelopeSchema>;

/** 成功响应:`ok=true` 恒带 `result`,恒无 `error`。 */
export const SuccessResponseSchema = z.object({
  v: z.literal(PROTOCOL_VERSION),
  id: z.string().min(1),
  ok: z.literal(true),
  result: JsonValueSchema,
});
export type SuccessResponse = z.infer<typeof SuccessResponseSchema>;

/** 失败响应:`ok=false` 恒带 `error`,恒无 `result`。 */
export const FailureResponseSchema = z.object({
  v: z.literal(PROTOCOL_VERSION),
  id: z.string().min(1),
  ok: z.literal(false),
  error: WireErrorSchema,
});
export type FailureResponse = z.infer<typeof FailureResponseSchema>;

/** 响应包封 = 成功 | 失败(按 `ok` 判别,一种包封贯穿所有 op)。 */
export const ResponseEnvelopeSchema = z.discriminatedUnion("ok", [
  SuccessResponseSchema,
  FailureResponseSchema,
]);
export type ResponseEnvelope = z.infer<typeof ResponseEnvelopeSchema>;

// MARK: - op 与其 result 形状(基础族)

/** 已登记的 op。 */
export const Op = {
  /** 取内核运行态快照。 */
  statusGet: "status.get",
} as const;
export type Op = (typeof Op)[keyof typeof Op];

/** `status.get` 的 result:内核运行态快照(机读,字段只增不改)。 */
export const StatusResultSchema = z.object({
  /** 恒为 "running" —— 能应答就说明活着;不可达是客户端侧的错误分支,不是一种 status 值。 */
  state: z.literal("running"),
  /** 内核版本(bin 与 daemon 天然同版本,见 ADR 0010)。 */
  version: z.string().min(1),
  /** 线协议版本,便于客户端做兼容判断。 */
  protocol: z.literal(PROTOCOL_VERSION),
  /** daemon 进程 pid。 */
  pid: z.number().int().positive(),
  /** daemon 启动时刻(ISO 8601 UTC)。 */
  startedAt: z.string().min(1),
  /** 已运行毫秒数。 */
  uptimeMs: z.number().int().nonnegative(),
  /** 展开后的 A2_HOME 与 socket 路径(agent 免猜)。 */
  home: z.string().min(1),
  socketPath: z.string().min(1),
});
export type StatusResult = z.infer<typeof StatusResultSchema>;

/**
 * `a2 version --json` 的 result。**没有对应的 op** —— 版本是 bin 自报的本地事实,不必往返 daemon;
 * 但它照样是机读输出,所以照样是登记契约(`--json` 时 stdout 只有一条 JSON 包封,无一例外)。
 */
export const VersionResultSchema = z.object({
  /** 内核版本(bin 与 daemon 天然同版本)。 */
  version: z.string().min(1),
  /** 本 bin 说的线协议版本。 */
  protocol: z.literal(PROTOCOL_VERSION),
});
export type VersionResult = z.infer<typeof VersionResultSchema>;

/** `a2 help --json`(以及缺子命令时)的 result:帮助文本本身。同样无 op、同样是登记契约。 */
export const HelpResultSchema = z.object({
  usage: z.string().min(1),
});
export type HelpResult = z.infer<typeof HelpResultSchema>;

// MARK: - 构造器(包封只在这里拼,禁止各处手搓字面量)

export function successResponse(id: string, result: JsonValue): SuccessResponse {
  return { v: PROTOCOL_VERSION, id, ok: true, result };
}

export function failureResponse(id: string, error: WireError): FailureResponse {
  return { v: PROTOCOL_VERSION, id, ok: false, error };
}

export function request(op: string, params?: Record<string, JsonValue>): RequestEnvelope {
  return params === undefined
    ? { v: PROTOCOL_VERSION, id: crypto.randomUUID(), op }
    : { v: PROTOCOL_VERSION, id: crypto.randomUUID(), op, params };
}

/** 编码成一帧(带换行)。 */
export function encodeFrame(message: RequestEnvelope | ResponseEnvelope): string {
  return `${JSON.stringify(message)}\n`;
}
