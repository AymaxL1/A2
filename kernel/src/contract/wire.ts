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

  // MARK: 能力面(04 票)—— 校验三码 + 业务失败 + dangerous 默拒

  /** 能力 id 未登记。 */
  unknownCapability: "unknown_capability",
  /** 缺必填参数。 */
  missingParameter: "missing_parameter",
  /** 参数类型与声明不符。 */
  typeMismatch: "type_mismatch",
  /** 参数取值非法(不在 allowedValues 内、input 不是 JSON 对象等)。 */
  invalidParams: "invalid_params",
  /** 能力执行了,但业务上失败了(与"没执行成"分开:退出码 5,不是 6)。 */
  capabilityFailed: "capability_failed",
  /**
   * dangerous 能力被调用,但**没有任何确认器在场** —— fail-closed 默拒(ADR 0005 第 4 条第①层)。
   * 这不是功能缺失,是无 GUI 形态的设计行为;拒绝报文必带 guidance(第②层「拒绝即指引」)。
   * 08 票补第③层(确认器在场时带外确认),届时新增 `confirmation_denied` / `confirmation_timeout`,
   * **本码的含义与形状不变** —— 客户端对"没人能替你确认"的分支不必跟着改。
   */
  confirmationUnavailable: "confirmation_unavailable",

  // MARK: 服务面(05 票)—— 系统托管常驻的安装/卸载

  /** 本平台没有已支持的 supervisor(只认 macOS launchd 与 Linux systemd)。 */
  serviceUnsupportedPlatform: "service_unsupported_platform",
  /**
   * 服务操作执行了但没成:写 unit 文件失败、supervisor 命令非零退出、装完了却没跑起来。
   * 与「参数不对」分开(那是 6),这一档是"路走通了、事没办成",退出码 5。
   */
  serviceOperationFailed: "service_operation_failed",
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
  /** 列出已登记能力(manifest 全量)。 */
  capabilitiesList: "capabilities.list",
  /** 取单个能力的 manifest。 */
  capabilitiesDescribe: "capabilities.describe",
  /** 调用一个能力。 */
  capabilitiesCall: "capabilities.call",
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

// MARK: - 能力 manifest 与能力面 result(04 票)

/**
 * 风险三档(ADR 0004 的分级承载,取值即契约):
 *   * `safe` —— 只读,直通;
 *   * `normal` —— 可逆写,直通(不打断,零确认);
 *   * `dangerous` —— 需真人在场证明,走三层仲裁(ADR 0005 第 4 条)。
 */
export const RiskLevelSchema = z.enum(["safe", "normal", "dangerous"]);
export type RiskLevel = z.infer<typeof RiskLevelSchema>;

/**
 * 参数类型词汇表。取的是 **JSON Schema 的词**(`boolean` 而非旧 Swift 的 `bool`):
 * 这张表要同时喂给 agent 和 11 票的插件 `describe` 输出,用 JSON 世界的通用词少一层翻译。
 */
export const ParameterTypeSchema = z.enum(["string", "number", "boolean", "object", "array"]);
export type ParameterType = z.infer<typeof ParameterTypeSchema>;

/**
 * 单个参数的声明。**数据驱动**(而不是把 zod schema 塞进 manifest):
 * 插件(11 票)只能用 JSON 描述自己的工具,能力面必须能被纯数据表达,内置能力与插件才是同一套东西。
 */
export const ParameterSpecSchema = z.object({
  name: z.string().min(1),
  type: ParameterTypeSchema,
  required: z.boolean(),
  description: z.string().min(1),
  /** 仅对 string 生效;缺省/空 = 不约束取值。 */
  allowedValues: z.array(z.string()).min(1).optional(),
});
export type ParameterSpec = z.infer<typeof ParameterSpecSchema>;

/** 能力 manifest:agent 靠它决定"调什么、怎么调、会不会被拦"。 */
export const CapabilityDescriptorSchema = z.object({
  id: z.string().min(1),
  risk: RiskLevelSchema,
  summary: z.string().min(1),
  parameters: z.array(ParameterSpecSchema),
});
export type CapabilityDescriptor = z.infer<typeof CapabilityDescriptorSchema>;

/** `capabilities.list` 的 result。数组顺序 = 登记顺序(稳定,便于人读与 diff)。 */
export const CapabilityListResultSchema = z.object({
  capabilities: z.array(CapabilityDescriptorSchema),
});
export type CapabilityListResult = z.infer<typeof CapabilityListResultSchema>;

/** `capabilities.describe` 的 result。 */
export const CapabilityDescribeResultSchema = z.object({
  descriptor: CapabilityDescriptorSchema,
});
export type CapabilityDescribeResult = z.infer<typeof CapabilityDescribeResultSchema>;

/**
 * `capabilities.call` 的 result。`capability` 回填便于 agent 对号,`output` 是能力自己的返回值。
 * (08 票若引入"带外确认中"的异步态,按可选字段追加 —— 可选字段追加不算不兼容变更。)
 */
export const CapabilityCallResultSchema = z.object({
  capability: z.string().min(1),
  output: JsonValueSchema,
});
export type CapabilityCallResult = z.infer<typeof CapabilityCallResultSchema>;

// MARK: - 服务面 result(05 票)
//
// 这三个 result **没有对应的 op**:服务面问的是**系统 supervisor**(launchd/systemd),不是 daemon 自己 ——
// daemon 没跑的时候这几条命令更要能答话。同 version/help,无 op 不等于无契约。

/**
 * 服务三态(取值即契约):
 *   * `not_installed` —— unit 文件不在,supervisor 也不认识它;
 *   * `installed_not_running` —— 装了(unit 在或已登记),但此刻没有进程;
 *   * `running` —— supervisor 报了 pid。
 *
 * 判据一律取自 **supervisor 的视角**,不掺 UDS 探活:「daemon 活没活着」是 `a2 status` 的问题,
 * 两条命令各答各的,省得同一件事有两个来源不同的答案。
 */
export const ServiceStateSchema = z.enum(["not_installed", "installed_not_running", "running"]);
export type ServiceState = z.infer<typeof ServiceStateSchema>;

/** 系统 supervisor 种类(macOS = launchd user 域;Linux = systemd user 单元)。 */
export const SupervisorKindSchema = z.enum(["launchd", "systemd"]);
export type SupervisorKind = z.infer<typeof SupervisorKindSchema>;

/**
 * install/uninstall 实际做过的收敛动作。**幂等的可观察面**:已收敛时数组为空(什么都没改),
 * agent 据此判断"这次是真装了还是本来就装好了",不必比对前后状态。
 */
export const ServiceActionSchema = z.enum([
  /** 写(或覆盖)了 unit 文件。 */
  "unit_written",
  /** 删了 unit 文件。 */
  "unit_removed",
  /** 向 supervisor 装载并置为开机自启(launchd bootstrap / systemd enable)。 */
  "supervisor_loaded",
  /** 从 supervisor 卸下(launchd bootout / systemd stop+disable)。 */
  "supervisor_unloaded",
  /** 让 supervisor 重读 unit 目录(systemd daemon-reload;launchd 无此概念,不会出现)。 */
  "supervisor_reloaded",
  /** 显式拉起了内核进程(launchd kickstart / systemd start)。 */
  "kernel_started",
  /**
   * 显式重启了内核进程 —— unit 内容漂了而服务正跑着,重写文件不足以让**已经在跑的那个进程**换成新内容。
   * 只在 systemd 那条路上出现;launchd 的同一情形表现为 `supervisor_unloaded` + `supervisor_loaded`。
   */
  "kernel_restarted",
]);
export type ServiceAction = z.infer<typeof ServiceActionSchema>;

/** `a2 service status` 的 result。 */
export const ServiceStatusResultSchema = z.object({
  state: ServiceStateSchema,
  supervisor: SupervisorKindSchema,
  /** unit 名(恒为 `com.a2.kernel`;内核只碰这一个 unit)。 */
  label: z.string().min(1),
  /** unit 文件的绝对路径(未安装时也给出:那是 install 会写的位置)。 */
  unitPath: z.string().min(1),
  /** unit 文件在不在。 */
  unitInstalled: z.boolean(),
  /** supervisor 认不认识这个 unit。 */
  registered: z.boolean(),
  /** 运行中才有;supervisor 报的进程号。 */
  pid: z.number().int().positive().optional(),
  /** 展开后的 A2_HOME 与 socket 路径(agent 免猜,与 `status.get` 同口径)。 */
  home: z.string().min(1),
  socketPath: z.string().min(1),
});
export type ServiceStatusResult = z.infer<typeof ServiceStatusResultSchema>;

/** `a2 service install|uninstall` 的 result:收敛后的状态 + 本次真改了什么。 */
export const ServiceChangeResultSchema = z.object({
  /** 收敛后的服务状态(与 `a2 service status` 同一形状,免得再问一次)。 */
  status: ServiceStatusResultSchema,
  /** 本次实际执行的动作;**空数组 = 本来就是这个样子**(幂等复跑)。 */
  actions: z.array(ServiceActionSchema),
});
export type ServiceChangeResult = z.infer<typeof ServiceChangeResultSchema>;

/** `capabilities.describe` 的 params。 */
export const CapabilityDescribeParamsSchema = z.object({
  capability: z.string().min(1),
});

/** `capabilities.call` 的 params。`input` 必须是 JSON 对象(参数按名取),缺省等价于空对象。 */
export const CapabilityCallParamsSchema = z.object({
  capability: z.string().min(1),
  input: z.record(z.string(), JsonValueSchema).optional(),
});

// MARK: - 构造器(包封只在这里拼,禁止各处手搓字面量)

export function successResponse(id: string, result: JsonValue): SuccessResponse {
  return { v: PROTOCOL_VERSION, id, ok: true, result };
}

export function failureResponse(id: string, error: WireError): FailureResponse {
  return { v: PROTOCOL_VERSION, id, ok: false, error };
}

/**
 * op 层的成败(**包封之下的一层**):handler 说"成了带这个 result"或"没成带这个 error",
 * 由 router 统一裹进包封。这样 handler 既不用手搓包封,也不必用异常表达业务失败。
 */
export type OpOutcome = { ok: true; result: JsonValue } | { ok: false; error: WireError };

export function opSuccess(result: JsonValue): OpOutcome {
  return { ok: true, result };
}

export function opFailure(error: WireError): OpOutcome {
  return { ok: false, error };
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
