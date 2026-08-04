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

  // MARK: mihomo 共存面(06 票)—— 四码全部映射退出码 5(路走通了、事没办成)

  /**
   * 该走的那个 mihomo external-controller 连不上(或鉴权不过)。
   * **收编档的核心分支**:被收编的实例是别人托管的,它没了只能报警 + 指引,内核绝不越权重拉。
   */
  mihomoUnreachable: "mihomo_unreachable",
  /** 要用的 mihomo 版本/能力位不达兼容地板。内核**不擅自升级别人的东西**,只给结构化降级报告与指引。 */
  mihomoBelowFloor: "mihomo_below_floor",
  /**
   * 这件事只能对 **a2 自管的** mihomo 做,而当前那份不归 a2 管(被收编的实例 / 只读复用的二进制)。
   * 这是「生命周期归原托管方」这条红线在报文上的投影。
   */
  mihomoNotManaged: "mihomo_not_managed",
  /** mihomo 操作执行了但没成:下载失败、摘要对不上、落位失败、unit 装了却没跑起来。 */
  mihomoOperationFailed: "mihomo_operation_failed",
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

// MARK: - mihomo 共存面 result(06 票)
//
// 与服务面同一种口径:**没有对应的 op**。「本机 mihomo 是个什么现状」问的是文件系统、supervisor 与
// external-controller,不是 daemon 自己;daemon 没跑的时候这几条命令更要能答话。
//
// 一条贯穿本节的语义红线:**被收编的实例其生命周期归原托管方**。内核对它只做只读探测与配置面接管,
// 绝不 stop/restart/kill;凡是"只能对 a2 自管那份做"的动作,对它一律返回 `mihomo_not_managed`。

/**
 * 本机 mihomo 现状三态(取值即契约):
 *   * `running_instance` —— 有跑着的实例,且它的 external-controller 可达;
 *   * `binary_only` —— 盘上有 mihomo 二进制,但没有可达的实例;
 *   * `absent` —— 两样都没有。
 */
export const MihomoPresenceSchema = z.enum(["running_instance", "binary_only", "absent"]);
export type MihomoPresence = z.infer<typeof MihomoPresenceSchema>;

/**
 * 共存阶梯三档(spec「共存 = 检测并优先复用,复用到实例级」):
 *   * `adopt_instance` —— 收编跑着的实例:经 API 接管配置与存活监督,**进程生死归原托管方**;
 *   * `reuse_binary` —— 只读复用既有二进制:配置/数据目录与 `com.a2.mihomo` unit 全套自建;
 *   * `managed_install` —— 全无(或显式隔离):按锁定版下载校验落位,再挂 `com.a2.mihomo` unit。
 */
export const MihomoRungSchema = z.enum(["adopt_instance", "reuse_binary", "managed_install"]);
export type MihomoRung = z.infer<typeof MihomoRungSchema>;

/** 实例归属:`a2` = `com.a2.mihomo` 托管的那份;`foreign` = 别人的(内核只读不碰生死)。 */
export const MihomoOwnerSchema = z.enum(["a2", "foreign"]);
export type MihomoOwner = z.infer<typeof MihomoOwnerSchema>;

/**
 * 能力位 —— **观察到的事实,不是推断**:每一位都对应一次真实探测。
 *   * `rest_api` —— `GET /version` 应答了;
 *   * `meta_core` —— `/version` 的 `meta` 为真(mihomo 系内核,不是原版 clash);
 *   * `configs_read` —— `GET /configs` 读得到(07 票的配置面要靠它)。
 */
export const MihomoCapabilitySchema = z.enum(["rest_api", "meta_core", "configs_read"]);
export type MihomoCapability = z.infer<typeof MihomoCapabilitySchema>;

/** 兼容地板的不达标项(机读词表,不是自由文本 —— 它是 agent 分支与审计的素材)。 */
export const MihomoShortfallSchema = z.enum([
  /** 问不出版本(`-v` 不认、`/version` 不给)。 */
  "version_unknown",
  /** 版本低于兼容地板。 */
  "version_below_floor",
  /** external-controller 不可达(或鉴权不过)。 */
  "rest_api_unreachable",
  /** 不是 mihomo 系内核(`/version` 的 meta 不为真)。 */
  "not_meta_core",
  /** `GET /configs` 读不到。 */
  "configs_unreadable",
]);
export type MihomoShortfall = z.infer<typeof MihomoShortfallSchema>;

/** 兼容地板判定。`meets=false` 时 `shortfalls` 非空,且拒绝报文必带指引(内核不擅自升级)。 */
export const MihomoCompatibilitySchema = z.object({
  /** 地板版本(内核编译期常量)。 */
  floor: z.string().min(1),
  meets: z.boolean(),
  /** 被判定的那份东西的版本(问不出时缺省)。 */
  version: z.string().optional(),
  shortfalls: z.array(MihomoShortfallSchema),
});
export type MihomoCompatibility = z.infer<typeof MihomoCompatibilitySchema>;

/** 一个可达实例的事实。 */
export const MihomoInstanceSchema = z.object({
  owner: MihomoOwnerSchema,
  /** external-controller 地址(恒为回环:非回环端点内核不探测)。 */
  controller: z.string().min(1),
  /** 该端点是否需要 secret(有配置到 secret 即真)。 */
  secretConfigured: z.boolean(),
  version: z.string().optional(),
  capabilities: z.array(MihomoCapabilitySchema),
  /** controller 地址是从哪份配置里读到的(显式指定时缺省)。 */
  configFile: z.string().optional(),
});
export type MihomoInstance = z.infer<typeof MihomoInstanceSchema>;

/** 盘上一份 mihomo 二进制的事实。 */
export const MihomoBinarySchema = z.object({
  path: z.string().min(1),
  version: z.string().optional(),
});
export type MihomoBinary = z.infer<typeof MihomoBinarySchema>;

/**
 * a2 自管二进制的形态:
 *   * `absent` —— 还没就位;
 *   * `downloaded` —— 按锁定版下载校验落位的真文件;
 *   * `reused` —— 指向既有二进制的**符号链接**(只读复用:内核从不写那个真身)。
 */
export const MihomoBinaryKindSchema = z.enum(["absent", "downloaded", "reused"]);
export type MihomoBinaryKind = z.infer<typeof MihomoBinaryKindSchema>;

/** a2 自管那一份(`com.a2.mihomo`)的落点与状态。未就位时路径照样给出:那是就位会写的位置。 */
export const MihomoManagedSchema = z.object({
  /** unit 名(恒为 `com.a2.mihomo`;它与 `com.a2.kernel` 各自独立 —— 数据面不随控制面起落)。 */
  label: z.string().min(1),
  supervisor: SupervisorKindSchema,
  unitPath: z.string().min(1),
  unitInstalled: z.boolean(),
  /** 与 `a2 service status` 同一套三态,取 supervisor 视角。 */
  state: ServiceStateSchema,
  pid: z.number().int().positive().optional(),
  binaryKind: MihomoBinaryKindSchema,
  binaryPath: z.string().min(1),
  /** `reused` 时符号链接指向的真身路径。 */
  binaryTarget: z.string().optional(),
  version: z.string().optional(),
  configPath: z.string().min(1),
  dataDir: z.string().min(1),
  controller: z.string().min(1),
});
export type MihomoManaged = z.infer<typeof MihomoManagedSchema>;

/** `a2 mihomo status` 的 result:现状 + 将采用的阶梯档位 + 兼容地板 + 双方各自的事实。 */
export const MihomoStatusResultSchema = z.object({
  presence: MihomoPresenceSchema,
  rung: MihomoRungSchema,
  /** a2 这边是否已就位(判据 = `com.a2.mihomo` 的 unit 文件在不在)。 */
  provisioned: z.boolean(),
  /** 脚本安装档会装的锁定版;`a2 mihomo upgrade` 也只升到它。 */
  lockedVersion: z.string().min(1),
  /** 当前可达的实例(a2 自管优先;都没有则缺省)。 */
  instance: MihomoInstanceSchema.optional(),
  /** 盘上找到的**别人的**二进制(复用档的复用对象)。 */
  foreignBinary: MihomoBinarySchema.optional(),
  managed: MihomoManagedSchema,
  compatibility: MihomoCompatibilitySchema,
  /**
   * 档位是**回退**来的时候的原委(spec「兼容性不达标回退隔离安装」)。
   * 只在"本来要复用、但那份不达地板"时出现 —— 收编档不回退(见 `reason` 里写明的理由)。
   */
  fallback: z
    .object({
      from: MihomoRungSchema,
      shortfalls: z.array(MihomoShortfallSchema),
      reason: z.string().min(1),
    })
    .optional(),
  /** 配置里写着、但不是回环地址因而**内核有意没去探**的 external-controller(如实报告,不静默丢弃)。 */
  skippedController: z.string().optional(),
  home: z.string().min(1),
});
export type MihomoStatusResult = z.infer<typeof MihomoStatusResultSchema>;

/**
 * mihomo 面的收敛动作(审计素材,词表封闭)。unit 那几个与服务面同名同义;
 * 二进制/配置那几个是本面独有。**没有任何一个动作作用在被收编的实例上** —— 那是设计,不是遗漏。
 */
export const MihomoActionSchema = z.enum([
  /**
   * 记下了「我收编的是这个实例」。**这是收编档唯一会落盘的东西**(a2 自己 home 里的一个小记录),
   * 不装二进制、不写 unit、不碰对方一根汗毛 —— 但有了它,"我收编的那个实例死了"才是一句有主语的话。
   */
  "adoption_recorded",
  /** 解除收编(卸载,或显式改走隔离安装)。同样只动 a2 自己的记录。 */
  "adoption_released",
  /** 建了 a2 自管的数据目录。 */
  "data_dir_created",
  /** 写(或收敛)了 a2 自管的配置文件。 */
  "config_written",
  /** 按锁定版下载 + 校验 + 落位了二进制。 */
  "binary_downloaded",
  /** 建了指向既有二进制的符号链接(只读复用)。 */
  "binary_linked",
  /** 显式升级把自管二进制换成了锁定版。 */
  "binary_upgraded",
  "unit_written",
  "unit_removed",
  "supervisor_loaded",
  "supervisor_unloaded",
  "supervisor_reloaded",
  /** 拉起了 a2 自管的 mihomo 进程。 */
  "mihomo_started",
  /** 重启了 a2 自管的 mihomo 进程(unit 漂移收敛 / 升级换版之后)。 */
  "mihomo_restarted",
]);
export type MihomoAction = z.infer<typeof MihomoActionSchema>;

/** `a2 mihomo install|uninstall|upgrade` 的 result:收敛后的状态 + 本次真改了什么(空数组 = 本来就这样)。 */
export const MihomoChangeResultSchema = z.object({
  status: MihomoStatusResultSchema,
  actions: z.array(MihomoActionSchema),
});
export type MihomoChangeResult = z.infer<typeof MihomoChangeResultSchema>;

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
