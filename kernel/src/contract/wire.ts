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
 * `detail` 放原始细节(异常文本等)。
 *
 * **`guidance` 在包封这一层是可选的,这是真话**(08 票纠正了 03 票注释里"必填"的说法):
 * 「你敲错了」类错误(`unknown_op`、`bad_request`)本来就没有"人类如何完成"可言,硬填等于编。
 * 真正必须带指引的是**「这条路走不通」**那一族 —— 它们由更窄的 schema 各自强制,而不是靠一句注释:
 * 见本文件的 `ConfirmationErrorSchema`(仲裁三码,`guidance` 必填,有金标样本 + 活体对照断言)。
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
   *
   * **08 票补齐第③层后本码的含义与形状一字未改**(04 票承诺兑现):除了"一个确认器都没有",
   * 还有一种情况归到这一码 —— **在途挂起时确认器全部断线**(降级)。理由:对发起方而言这两件事
   * 是同一件事(此刻没人能替你确认),客户端不该为"它是什么时候消失的"多写一个分支。
   */
  confirmationUnavailable: "confirmation_unavailable",

  // MARK: 仲裁第③层(08 票)—— 确认器在场时的两种收场

  /**
   * 确认器在场,人类**明确点了拒绝**。与 `confirmation_unavailable` 是两件事:
   * 那条说"没人能替你确认",这条说"有人看了,他不同意"。退出码同为 2(都是 denied 档)。
   */
  confirmationDenied: "confirmation_denied",
  /**
   * 确认器在场、请求也送到了,但在超时窗口内**没人做决定**。退出码 3(超时档,本码是它的首个产出面)。
   * 超时即拒绝(fail-closed):内核绝不因为没人应答就放行。
   */
  confirmationTimeout: "confirmation_timeout",

  // MARK: 长连接与角色协议(08 票)

  /**
   * 对端不是同一个 UID —— 连接当场被拒(内核经 `getpeereid`/`SO_PEERCRED` 校验,见 `daemon/peer.ts`)。
   * 这是纵深的第三道门(前两道是 `run/` 0700 与 socket 0600,由 OS 强制)。
   */
  peerRejected: "peer_rejected",
  /** `confirmations.resolve` 指向的确认请求不存在,或已经收场了(超时/被别的确认器先决定了)。 */
  confirmationUnknown: "confirmation_unknown",
  /**
   * 这条连接没有注册所需的角色就来干这个角色的活(如未注册 confirm-agent 就想替人做决定)。
   * **角色是连接的属性,不是报文里的一句自称** —— 所以这条错误只可能出现在长连接面上。
   */
  roleNotRegistered: "role_not_registered",

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

  // MARK: 代理控制面(07 票)

  /**
   * 代理控制面的操作发出去了、但没成:REST 非 2xx、组或节点不存在、重载被内核拒绝。
   * 与 `mihomo_unreachable`(压根连不上)分开:这一档说明**通了,是这件事本身没办成**。
   */
  proxyOperationFailed: "proxy_operation_failed",
  /** 系统代理那条路没走通:`networksetup` 非零退出、读不回状态、接管写到一半已回滚。 */
  systemProxyFailed: "system_proxy_failed",
  /**
   * 本平台没有已支持的系统代理接管路径(V1 只认 macOS 的 `networksetup`)。
   * 与 `service_unsupported_platform` 同一档:不是你敲错了,是这条请求在这台机器上不成立(退出码 6)。
   */
  systemProxyUnsupported: "system_proxy_unsupported",
  /** 订阅拉取/物化/清单读写没成(含「清单文件损坏,拒绝读写以免覆盖既有数据」)。 */
  subscriptionFailed: "subscription_failed",
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
  /**
   * 在**当前这条长连接**上注册一个角色(confirm-agent / subscriber),08 票。
   * 注册是连接级的事实:连接在 = 角色在,连接断 = 角色立刻消失(无心跳、无 TTL、无陈旧窗口)。
   */
  rolesRegister: "roles.register",
  /** 确认器对一条待确认请求做决定(批准/拒绝)。**只有注册过 confirm-agent 的连接能发**。 */
  confirmationsResolve: "confirmations.resolve",
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

/**
 * 能力 manifest:agent 靠它决定"调什么、怎么调、会不会被拦"。
 *
 * `cliAlias`(07 票加回)是**同一条能力的域子命令写法**:`["proxy","on"]` ⇒ `a2 proxy on`。
 * 它只是 argv 的一层门面 —— 解析在客户端做,**仲裁仍在 `registry.invoke` 里发生**
 * (`a2 proxy on` 与 `a2 capabilities call proxy.system.enable` 逐字节同一个结果,有断言)。
 * 04 票曾把它标为"可派生的展示串"而淘汰,05 票改标顺延 07;此处按域子命令面的实际需要收回契约。
 */
export const CapabilityDescriptorSchema = z.object({
  id: z.string().min(1),
  risk: RiskLevelSchema,
  summary: z.string().min(1),
  parameters: z.array(ParameterSpecSchema),
  /** 域子命令写法(有序 token;缺省 = 这条能力只能用 `capabilities call` 调)。 */
  cliAlias: z.array(z.string().min(1)).min(1).optional(),
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

// MARK: - 代理控制面 result(07 票)
//
// 与 service / mihomo 两面**不同口径**:代理域全部是**真能力**(经注册表、经 daemon,`a2 capabilities call`
// 与 `a2 proxy …` 走的是同一条路)。理由:它们要对 external-controller 发写请求、要动系统代理、
// 要读 daemon 里那份存活观测 —— 每一件都必须有一个唯一的仲裁点与唯一的状态持有者。
//
// 一条贯穿本节的边界:**「这份归不归 a2 管」决定写面能发到哪一层**。
//   * 归 a2 管(自管档)→ 配置文件、整份重载、订阅激活全都可以;
//   * 不归 a2 管(收编档)→ 只能 `PATCH /configs`(改 mode)与 `PUT /proxies/<组>`(选节点),
//     凡是"换配置文件"的动作一律 `mihomo_not_managed`。这是「生命周期归原托管方」在代理面的投影。

/** 代理模式三档。取值即契约(**大小写敏感**,与旧 `aa` 同口径:`RULE` 会被 allowedValues 拒掉)。 */
export const ProxyModeSchema = z.enum(["rule", "global", "direct"]);
export type ProxyMode = z.infer<typeof ProxyModeSchema>;

/** 「我这条命令是在跟谁说话」—— 每条代理 result 都带上,agent 不必再问一次 `a2 mihomo status`。 */
export const ProxyEndpointSchema = z.object({
  owner: MihomoOwnerSchema,
  /** external-controller 地址(恒回环)。 */
  controller: z.string().min(1),
  /** 这份归不归 a2 管(决定"换配置文件"类写面能不能发)。 */
  managed: z.boolean(),
  /** a2 自管那份的配置文件路径(收编档缺省 —— 那是别人的文件,内核不写)。 */
  configPath: z.string().optional(),
});
export type ProxyEndpoint = z.infer<typeof ProxyEndpointSchema>;

/** 系统代理的三类(macOS `networksetup` 的三组子命令,一一对应)。 */
export const ProxyKindSchema = z.enum(["http", "https", "socks"]);
export type ProxyKind = z.infer<typeof ProxyKindSchema>;

/** 一个网络服务上某一类代理的设置。**逐字段**(而不是只记开/关)—— 精确还原全靠它。 */
export const ProxySettingSchema = z.object({
  enabled: z.boolean(),
  host: z.string(),
  port: z.number().int().nonnegative(),
});
export type ProxySetting = z.infer<typeof ProxySettingSchema>;

/** 一个网络服务(Wi-Fi / Ethernet / …)的三类代理设置。 */
export const NetworkServiceProxySchema = z.object({
  service: z.string().min(1),
  http: ProxySettingSchema,
  https: ProxySettingSchema,
  socks: ProxySettingSchema,
});
export type NetworkServiceProxy = z.infer<typeof NetworkServiceProxySchema>;

/** 系统代理的紧凑摘要(嵌进 `proxy.status`;完整实况见 `proxy.system.status`)。 */
export const SystemProxySummarySchema = z.object({
  /** 本平台有没有已支持的接管路径(V1 只有 macOS)。 */
  supported: z.boolean(),
  /** a2 手里有没有一份接管快照 —— **有 = 现在是我接管着,还原有据可依**。 */
  takenOver: z.boolean(),
  host: z.string().optional(),
  port: z.number().int().positive().optional(),
});
export type SystemProxySummary = z.infer<typeof SystemProxySummarySchema>;

/** `proxy.system.status` 的 output:摘要 + 快照落点 + **当前实况**(逐服务逐类型)。 */
export const SystemProxyStatusResultSchema = SystemProxySummarySchema.extend({
  /** 接管快照的落点(未接管时也给出:那是接管会写的位置)。 */
  snapshotPath: z.string().min(1),
  takenOverAt: z.string().optional(),
  /** 此刻系统上的真实设置(读回来的,不是推断的)。平台不支持时为空数组。 */
  services: z.array(NetworkServiceProxySchema),
});
export type SystemProxyStatusResult = z.infer<typeof SystemProxyStatusResultSchema>;

/** `proxy.system.enable|disable` 的 output。`restored` 只在 disable 出现(**本次真的还原了吗**)。 */
export const SystemProxyChangeResultSchema = z.object({
  enabled: z.boolean(),
  restored: z.boolean().optional(),
  host: z.string().optional(),
  port: z.number().int().positive().optional(),
  status: SystemProxyStatusResultSchema,
});
export type SystemProxyChangeResult = z.infer<typeof SystemProxyChangeResultSchema>;

/**
 * `proxy.status` 的 output。**两条独立事实不合并**(沿旧口径):
 * `running` = 有没有一个实例在(进程/实例层),`apiReachable` = 控制面答不答话。
 * 内核没跑时**不臆造 mode/端口/节点** —— 那几个字段直接缺省。
 */
export const ProxyStatusResultSchema = z.object({
  running: z.boolean(),
  apiReachable: z.boolean(),
  /** 一个实例都没有时缺省。 */
  endpoint: ProxyEndpointSchema.optional(),
  version: z.string().optional(),
  /** **原样透传字符串,不强枚举** —— 内核将来新增模式时客户端不该炸。 */
  mode: z.string().optional(),
  mixedPort: z.number().int().positive().optional(),
  node: z.string().optional(),
  systemProxy: SystemProxySummarySchema,
});
export type ProxyStatusResult = z.infer<typeof ProxyStatusResultSchema>;

/**
 * 一个可切换分组。**判据是条目带 `all`**(不看 type)—— Selector/URLTest/Fallback/LoadBalance 都带,
 * 裸节点不带,内核新增组类型时不必改代码。`now` 为空串时归一为缺省。
 */
export const ProxyGroupSchema = z.object({
  name: z.string().min(1),
  type: z.string().min(1),
  now: z.string().optional(),
  all: z.array(z.string()),
});
export type ProxyGroup = z.infer<typeof ProxyGroupSchema>;

/** `proxy.groups.list` 的 output。数组**按组名排序**(确定性,便于 diff 与逐字断言)。 */
export const ProxyGroupsResultSchema = z.object({
  endpoint: ProxyEndpointSchema,
  groups: z.array(ProxyGroupSchema),
});
export type ProxyGroupsResult = z.infer<typeof ProxyGroupsResultSchema>;

/** `proxy.mode.get|set` 的 output(`set` 只在 set 时出现)。 */
export const ProxyModeResultSchema = z.object({
  endpoint: ProxyEndpointSchema,
  mode: z.string().min(1),
  set: z.boolean().optional(),
});
export type ProxyModeResult = z.infer<typeof ProxyModeResultSchema>;

/** `proxy.node.select` 的 output。 */
export const ProxyNodeSelectResultSchema = z.object({
  endpoint: ProxyEndpointSchema,
  group: z.string().min(1),
  node: z.string().min(1),
  selected: z.literal(true),
});
export type ProxyNodeSelectResult = z.infer<typeof ProxyNodeSelectResultSchema>;

/**
 * `proxy.latency.test` 的 output。**结果以该组候选清单为准逐个对齐**:
 * 内核的 delay map 里缺席的节点就是超时(`delayMs` 缺省 + `timeout: true`),**绝不臆造 0**。
 */
export const ProxyLatencyResultSchema = z.object({
  endpoint: ProxyEndpointSchema,
  group: z.string().min(1),
  url: z.string().min(1),
  timeoutMs: z.number().int().positive(),
  results: z.array(
    z.object({
      node: z.string().min(1),
      delayMs: z.number().int().nonnegative().optional(),
      timeout: z.boolean(),
    }),
  ),
});
export type ProxyLatencyResult = z.infer<typeof ProxyLatencyResultSchema>;

/** a2 自管配置里的可调项(**只有这几项可调** —— 其余由内核渲染,手改会在下次收敛时被改回)。 */
export const ProxySettingsSchema = z.object({
  /** 混合入站端口(HTTP + SOCKS 同一个;系统代理接管指向的就是它)。 */
  mixedPort: z.number().int().positive(),
  allowLan: z.boolean(),
  logLevel: z.enum(["silent", "error", "warning", "info", "debug"]),
  /** 写进配置文件的默认模式(运行时改 mode 走 `proxy.mode.set`,不落盘)。 */
  mode: ProxyModeSchema,
});
export type ProxySettings = z.infer<typeof ProxySettingsSchema>;

/** 配置面的收敛动作(词表封闭,审计素材)。空数组 = 本来就是这个样子。 */
export const ProxyConfigActionSchema = z.enum([
  /** 写了 `<A2_HOME>/mihomo/settings.json`。 */
  "settings_written",
  /** 渲染并写了 a2 自管配置(逐字比较有差才写)。 */
  "config_written",
  /** 让内核从配置文件整份重载(`PUT /configs`)。 */
  "config_reloaded",
]);
export type ProxyConfigAction = z.infer<typeof ProxyConfigActionSchema>;

/** `proxy.config.get|set` 的 output。 */
export const ProxyConfigResultSchema = z.object({
  settings: ProxySettingsSchema,
  configPath: z.string().min(1),
  controller: z.string().min(1),
  /** 当前激活的订阅 id(没有则 null)。 */
  activeSubscription: z.string().nullable(),
  /** 磁盘上那份配置与内核此刻应当渲染出的内容是否逐字一致。 */
  inSync: z.boolean(),
  actions: z.array(ProxyConfigActionSchema),
});
export type ProxyConfigResult = z.infer<typeof ProxyConfigResultSchema>;

/** 一条订阅。`id` 由名字确定性派生(同名 → 同 id,即 upsert 语义)。 */
export const SubscriptionSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  source: z.string().min(1),
  /** 最近一次成功拉取的时刻(ISO 8601 UTC);从未拉取成功过则缺省。 */
  lastUpdatedAt: z.string().optional(),
  /** 物化配置的字节数(拉到的是不是空东西,agent 一眼可见)。 */
  bytes: z.number().int().nonnegative().optional(),
});
export type Subscription = z.infer<typeof SubscriptionSchema>;

/** `proxy.subscription.list` 的 output。`active` 显式可为 null(「一个都没激活」是合法答案)。 */
export const SubscriptionListResultSchema = z.object({
  active: z.string().nullable(),
  subscriptions: z.array(SubscriptionSchema),
  directory: z.string().min(1),
});
export type SubscriptionListResult = z.infer<typeof SubscriptionListResultSchema>;

/** 订阅面的变更动作。 */
export const SubscriptionActionSchema = z.enum([
  "added",
  /** 同名再 add = 换源(id 不变,配置字节被替换)。 */
  "replaced",
  "updated",
  "activated",
  "removed",
]);
export type SubscriptionAction = z.infer<typeof SubscriptionActionSchema>;

/** `proxy.subscription.add|update|activate|remove` 的 output。 */
export const SubscriptionChangeResultSchema = z.object({
  id: z.string().min(1),
  action: SubscriptionActionSchema,
  /** 变更后的那一条(remove 时缺省 —— 它已经不在了)。 */
  subscription: SubscriptionSchema.optional(),
  active: z.string().nullable(),
  /** 本次有没有让内核真的重载配置(add 恒 false:**add 不自动激活**)。 */
  reloaded: z.boolean(),
});
export type SubscriptionChangeResult = z.infer<typeof SubscriptionChangeResultSchema>;

/**
 * 存活监督的一条观测事件。**内容即 08 票的推送载荷** —— 本票只落日志 + 可查询,
 * 推送面(订阅/确认器)归 08,届时把同一份对象发出去即可,形状不变。
 */
export const ProxySupervisionEventSchema = z.object({
  at: z.string().min(1),
  kind: z.enum([
    /** daemon 起来了,开始盯着某个端点。 */
    "watch_started",
    /** 之前不可达 → 现在可达。 */
    "instance_up",
    /** 之前可达 → 现在不可达(**这就是票面说的报警**)。 */
    "instance_down",
    /** 盯的对象换了(比如从收编档切到自管档)。 */
    "target_changed",
    /** daemon 要停了。 */
    "watch_stopped",
  ]),
  controller: z.string().min(1),
  owner: MihomoOwnerSchema,
  detail: z.string().optional(),
  /** `instance_down` 必带 —— 「人类如何完成」与 `a2 mihomo install` 那条同源。 */
  guidance: GuidanceSchema.optional(),
});
export type ProxySupervisionEvent = z.infer<typeof ProxySupervisionEventSchema>;

/** `proxy.supervision.get` 的 output:当下观测 + 最近若干条事件(全量在日志文件里)。 */
export const ProxySupervisionResultSchema = z.object({
  /** daemon 里那条观测循环在不在跑。 */
  watching: z.boolean(),
  intervalMs: z.number().int().positive(),
  /** 起来之后一共探了多少次(证明它真在跑,而不是"看起来在跑")。 */
  checks: z.number().int().nonnegative(),
  target: ProxyEndpointSchema.optional(),
  alive: z.boolean().optional(),
  lastCheckAt: z.string().optional(),
  lastTransitionAt: z.string().optional(),
  /** 事件全量落这儿(NDJSON,一行一条)。 */
  logPath: z.string().min(1),
  /** 最近若干条(新的在后),供 CLI 直接看;要全量请读 `logPath`。 */
  events: z.array(ProxySupervisionEventSchema),
});
export type ProxySupervisionResult = z.infer<typeof ProxySupervisionResultSchema>;

// MARK: - 角色注册、订阅推送与三层仲裁(08 票)
//
// 这一节是本效应安全模型的落点。三件事一起长出来,因为它们其实是同一件事的三个面:
//   * **角色**:长连接上注册 confirm-agent(确认器)或 subscriber(订阅者)。**在场 = 长连接**
//     (ADR 0005 修订后第 4 条):连接在即在场,断线即离场,无心跳、无 TTL、无陈旧状态窗口。
//   * **推送**:注册即回全量快照,此后增量推送。**零轮询**是壳侧(10 票)的硬要求。
//   * **仲裁**:无确认器 → `confirmation_unavailable`(第①层,形状不变);有确认器 → 带外确认,
//     三种收场(批准 / `confirmation_denied` / `confirmation_timeout`);在途时确认器全断
//     → **立即降回第①层**(同一条 `confirmation_unavailable`)。
//
// **V1 不做身份校验,这是已知边界,如实记在契约里**(06 票裁定、ADR 0008 第 5 条):
// 注册报文的 `identity` 字段一律**原样收下、不验签**,同 UID 的恶意代码可以冒充确认器。
// 仲裁保护的是「受认可路径上的 AI agent 不能自批」,不对抗已经拿到该用户身份的任意本机代码 ——
// 那种攻击者可以直接替换 `a2` 这个二进制,任何协议层校验都拦不住。真正被**验证过**的身份事实
// 只有一条:对端 UID(`getpeereid`/`SO_PEERCRED`,见 `daemon/peer.ts`),它进审计、进快照。

/**
 * 长连接上可注册的角色。取值即契约,**逐字取自 spec 与 ADR 0005/0008**(`confirm-agent` / `subscriber`):
 *   * `confirm-agent` —— 确认器:替人类出面呈现 dangerous 确认并安全回传决定;
 *   * `subscriber` —— 订阅者:只收状态投影,不参与仲裁。
 *
 * 一条连接可以两个角色都注册(菜单栏壳就是这样:既确认也投影);重复注册同一角色是幂等的。
 */
export const ClientRoleSchema = z.enum(["confirm-agent", "subscriber"]);
export type ClientRole = z.infer<typeof ClientRoleSchema>;

/**
 * 注册时客户端自报的身份。**V1 全部字段只用于展示与审计,内核一个都不校验**。
 *
 * 后两个字段是给将来的身份强化留的插槽(ADR 0008 第 5 条「注册协议预留身份强化字段」):
 * 届时内核会用 `getpeereid` 拿到的 pid 反查可执行文件并核对 cdhash/团队 ID。**现在没有做**,
 * 所以此刻填什么都不改变任何判断 —— 客户端填了不会更可信,不填也不会被拒。
 */
export const ClientIdentitySchema = z.object({
  /** 客户端自报的名字(如 `a2-panel`)。**不构成身份**,只是审计与人读的标签。 */
  name: z.string().min(1),
  version: z.string().min(1).optional(),
  /** 预留:代码签名摘要(cdhash)。**V1 不校验**。 */
  codeDirectoryHash: z.string().min(1).optional(),
  /** 预留:团队标识(Apple Team ID 等)。**V1 不校验**。 */
  teamIdentifier: z.string().min(1).optional(),
});
export type ClientIdentity = z.infer<typeof ClientIdentitySchema>;

/** `roles.register` 的 params。 */
export const RoleRegisterParamsSchema = z.object({
  role: ClientRoleSchema,
  identity: ClientIdentitySchema,
});

/** 确认器能给的两种决定。**没有第三种** —— 「不理」不是决定,那是超时(内核自己裁)。 */
export const ConfirmationDecisionSchema = z.enum(["approve", "deny"]);
export type ConfirmationDecision = z.infer<typeof ConfirmationDecisionSchema>;

/** `confirmations.resolve` 的 params。 */
export const ConfirmationResolveParamsSchema = z.object({
  /** 要决定的那条确认请求的 id(来自推给确认器的 `confirmation` 事件)。 */
  confirmation: z.string().min(1),
  decision: ConfirmationDecisionSchema,
  /** 人类给的理由(可选,进审计日志)。 */
  reason: z.string().min(1).optional(),
});

/**
 * 一条在途的待确认请求 —— **只有坐标,没有 input**。
 *
 * 这不是省字段,是边界:快照与仲裁事件发给**所有**订阅者,而 input 是"人类要亲眼核对的东西"
 * (防社工话术的关键),它只出现在推给 **confirm-agent** 的 `ConfirmationRequest` 里。有断言守这条。
 */
export const PendingConfirmationSchema = z.object({
  id: z.string().min(1),
  capability: z.string().min(1),
  /** 恒为 `dangerous`(只有这一档会进仲裁);写出来是免得客户端去猜。 */
  risk: RiskLevelSchema,
  requestedAt: z.string().min(1),
  /** 超过这个时刻还没人决定就算超时(内核自己算好,客户端不必再拿 timeoutMs 去加)。 */
  expiresAt: z.string().min(1),
});
export type PendingConfirmation = z.infer<typeof PendingConfirmationSchema>;

/** 仲裁面此刻的状态。快照里有一份,变化时也整份推一次(它只有几个标量,增量没有意义)。 */
export const ArbitrationStateSchema = z.object({
  /**
   * 有没有确认器在场。**这就是 dangerous 能不能走通的那条运行时事实**
   * (ADR 0008 Consequences:「dangerous 的可用性变成一条可观测的运行时事实」)。
   */
  confirmerPresent: z.boolean(),
  confirmers: z.number().int().nonnegative(),
  subscribers: z.number().int().nonnegative(),
  /** 确认超时窗口(毫秒)。 */
  timeoutMs: z.number().int().positive(),
  pending: z.array(PendingConfirmationSchema),
});
export type ArbitrationState = z.infer<typeof ArbitrationStateSchema>;

/**
 * 推给**确认器**的待确认请求全文。
 *
 * `descriptor` 与 `input` 都在:确认器必须能原样展示"这是哪条能力、这次到底要干什么"——
 * 旧 Swift 宿主那条 `[confirm] <id> key=value` 日志与确认框里的「本次请求参数」就是这件事,
 * 新架构把它从"日志里的一行"升成了**协议字段**(对等映射见 `test/swift-parity-map.md`)。
 */
export const ConfirmationRequestSchema = z.object({
  id: z.string().min(1),
  capability: z.string().min(1),
  /** 完整 manifest —— 确认器不该自己存一份会漂的副本。 */
  descriptor: CapabilityDescriptorSchema,
  /** 本次调用的**真实入参**。确认器必须原样呈现(防「agent 替用户点确认」的社工话术)。 */
  input: z.record(z.string(), JsonValueSchema),
  requestedAt: z.string().min(1),
  expiresAt: z.string().min(1),
});
export type ConfirmationRequest = z.infer<typeof ConfirmationRequestSchema>;

/**
 * 审计动作(词表封闭,值即契约)。dangerous 的**每一次**仲裁在这里都留得下痕迹,
 * 角色进出也留痕 —— 「确认器什么时候在、什么时候走的」是事后复盘 dangerous 可用性的唯一依据。
 */
export const AuditActionSchema = z.enum([
  /** dangerous 调用进了仲裁(此刻还不知道会怎么收场)。 */
  "requested",
  /** 确认器批准 —— 只有这一条之后 handler 才会被执行。 */
  "approved",
  /** 确认器明确拒绝。 */
  "denied",
  /** 等确认超时(fail-closed,超时即拒)。 */
  "timed_out",
  /** 无确认器在场,直接默拒(第①层)。 */
  "unavailable",
  /** **在途时确认器全部断线** → 立即降回默拒(第③层塌回第①层)。 */
  "downgraded",
  /** **发起那次调用的连接断开了** → 在途确认取消(没人在等这个答案了)。 */
  "cancelled",
  "confirmer_joined",
  "confirmer_left",
  "subscriber_joined",
  "subscriber_left",
  /**
   * 对端 UID 与内核不符,连接被拒。**留痕的意义在这条上最大** ——
   * 它是"有别的用户在敲这个 socket"的唯一记录。
   */
  "peer_rejected",
  /**
   * 对端凭据**问不出来**,连接照常放行(fail-open,见 `daemon/peer.ts` 的取舍与 ADR 0005/0008 修订记录)。
   * 按原因去重 + 限频 —— 它在正常机器上一次都不该出现,一旦出现就说明取凭据那条路失效了。
   */
  "peer_unverified",
  /**
   * 推送积压超限,该连接被判定为**慢消费者**并断连。它重连时会拿到一份新的全量快照,
   * 所以丢掉中间那些增量不会让它错乱(这正是"全量快照 + 增量"模型的兜底)。
   */
  "backpressure_dropped",
]);
export type AuditAction = z.infer<typeof AuditActionSchema>;

/** 审计事件里的客户端事实。`uid` 是**唯一被验证过的**那一个,`name` 只是自称。 */
export const AuditClientSchema = z.object({
  role: ClientRoleSchema.optional(),
  /** 自报的名字(不构成身份)。角色事件必带;`peer_rejected` 时还没注册,缺省。 */
  name: z.string().min(1).optional(),
  /** 内核校验到的对端 uid。取不到凭据时缺省(见 `daemon/peer.ts` 的口径)。 */
  uid: z.number().int().nonnegative().optional(),
});
export type AuditClient = z.infer<typeof AuditClientSchema>;

/** 一条审计事件(NDJSON 落 `<A2_HOME>/log/arbitration.log`,同时推给订阅者与确认器)。 */
export const AuditEventSchema = z.object({
  at: z.string().min(1),
  action: AuditActionSchema,
  /** 涉及的能力(角色进出与 `peer_rejected` 缺省)。 */
  capability: z.string().optional(),
  /** 确认请求 id(第①层默拒也有一个,好让"请求—收场"能配对)。 */
  confirmation: z.string().optional(),
  client: AuditClientSchema.optional(),
  detail: z.string().optional(),
});
export type AuditEvent = z.infer<typeof AuditEventSchema>;

/**
 * 「有人改了状态」事件 —— **只对 `normal` / `dangerous` 两档发**(`safe` 是只读,发了是噪音)。
 *
 * 它带着能力自己的 `output`,所以订阅者可以**直接投影**、不必回头再查一次 —— 那正是「零轮询」
 * 的实质(壳收到 `proxy.mode.set` 的 output 就知道新模式是什么,不用再发一条 `proxy.status`)。
 */
export const CapabilityEventSchema = z.object({
  capability: z.string().min(1),
  risk: RiskLevelSchema,
  output: JsonValueSchema,
});
export type CapabilityEvent = z.infer<typeof CapabilityEventSchema>;

/**
 * 注册那一刻回给客户端的**全量快照**。之后的变化一律走增量推送(`KernelEvent`)。
 *
 * **快照即基线,此后才是增量 —— 这条顺序是协议保证,不是巧合**(09/10 票的客户端要依赖它):
 *   * `roles.register` 的**响应**(含本快照)是这条连接上的**第一帧**,任何推送都排在它之后;
 *   * 快照里的 `arbitration` 计数**已经含这条连接自己**,所以内核**不会**再把它自己的
 *     `confirmer_joined` / `subscriber_joined` 推给它 —— 否则严格按"快照 + 增量"记账的客户端会重复计入。
 *     别的已注册连接照常收到那条进场事件(对它们那是真增量)。
 * 于是客户端的算法可以是最简单的那种:拿快照当初值,之后每条事件直接叠上去,不必去重、不必对账。
 *
 * 为什么快照就是这五样:客户端要投影的东西全在内核的**进程内状态**里,取它们不发一次网络请求、
 * 不读一次外部进程 —— 快照必须是廉价且瞬时一致的,否则"注册即快照"会变成一次慢启动。
 * (代理的实时模式/节点不在此列:那要问 external-controller。壳按需调 `proxy.status` 能力,
 * 此后靠 `capability` 事件跟进变化 —— 仍然零轮询。)
 */
export const KernelSnapshotSchema = z.object({
  status: StatusResultSchema,
  /** 能力全集(11 票插件装上后这张表会变,届时随 `capabilities` 事件推增量)。 */
  capabilities: z.array(CapabilityDescriptorSchema),
  arbitration: ArbitrationStateSchema,
  /** 存活监督的当下观测 + 最近事件(07 票的形状原样复用)。 */
  supervision: ProxySupervisionResultSchema,
  /** 最近若干条审计事件(全量在 `arbitration.log` 里)。 */
  audit: z.array(AuditEventSchema),
});
export type KernelSnapshot = z.infer<typeof KernelSnapshotSchema>;

/**
 * 增量推送的事件族(按 `kind` 判别)。**推送对象各不相同**,这是协议的一部分:
 *   * `confirmation` —— **只推给 confirm-agent**(带 input);
 *   * `confirmation-pending` —— **只推给发起那次调用的那条连接**(告诉它"我转给人了,最多等这么久");
 *   * 其余 —— 推给全体已注册连接(确认器 + 订阅者)。
 */
export const KernelEventSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("arbitration"),
    at: z.string().min(1),
    state: ArbitrationStateSchema,
  }),
  z.object({
    kind: z.literal("confirmation"),
    at: z.string().min(1),
    request: ConfirmationRequestSchema,
  }),
  z.object({
    kind: z.literal("confirmation-pending"),
    at: z.string().min(1),
    /** 对应的请求包封 id —— 客户端据此认出"说的是我这条"。 */
    requestId: z.string().min(1),
    /** 内核承诺在此毫秒数内给出最终响应(客户端据此延长等待,**不必与内核共享环境变量**)。 */
    timeoutMs: z.number().int().positive(),
    confirmation: PendingConfirmationSchema,
  }),
  z.object({ kind: z.literal("audit"), at: z.string().min(1), audit: AuditEventSchema }),
  z.object({
    kind: z.literal("supervision"),
    at: z.string().min(1),
    supervision: ProxySupervisionEventSchema,
  }),
  z.object({
    kind: z.literal("capability"),
    at: z.string().min(1),
    capability: CapabilityEventSchema,
  }),
]);
export type KernelEvent = z.infer<typeof KernelEventSchema>;

/**
 * 推送帧。与响应包封的判别方式是**结构性的**:响应有 `ok`,推送有 `push`,两者永不同时出现 ——
 * 客户端一次 `JSON.parse` 就能分流,不必先猜再试。
 *
 * `id` 是这条推送自己的 id(不对应任何请求)。唯一的例外语义在 `confirmation-pending` 事件里:
 * 它自带 `requestId` 指回那条正在等的请求。
 */
export const PushEnvelopeSchema = z.object({
  v: z.literal(PROTOCOL_VERSION),
  id: z.string().min(1),
  push: z.literal(true),
  event: KernelEventSchema,
});
export type PushEnvelope = z.infer<typeof PushEnvelopeSchema>;

/** 服务端可能写到连接上的一切:响应 | 推送。长连接客户端按这个解。 */
export const ServerFrameSchema = z.union([ResponseEnvelopeSchema, PushEnvelopeSchema]);
export type ServerFrame = z.infer<typeof ServerFrameSchema>;

/** `roles.register` 的 result:确认注册了什么 + 全量快照(**注册与首帧快照是同一次往返**)。 */
export const RoleRegisterResultSchema = z.object({
  role: ClientRoleSchema,
  /** 这条连接在本内核里的 id(进审计,便于把日志与连接对上)。 */
  connection: z.string().min(1),
  /**
   * 内核校验到的对端 uid。**缺省 = 这台机器上取不到 peer credential**(FFI 不可用等)——
   * 此时连接照常可用,把关的是 `run/` 0700 与 socket 0600 那两道 OS 强制的门(见 `daemon/peer.ts`)。
   */
  uid: z.number().int().nonnegative().optional(),
  /** 本次注册后已持有的全部角色(重复注册幂等,这里能看出连接的真实身份组合)。 */
  roles: z.array(ClientRoleSchema),
  snapshot: KernelSnapshotSchema,
});
export type RoleRegisterResult = z.infer<typeof RoleRegisterResultSchema>;

/** `confirmations.resolve` 的 result。 */
export const ConfirmationResolveResultSchema = z.object({
  confirmation: z.string().min(1),
  decision: ConfirmationDecisionSchema,
  /** 恒 true —— 决定没被采纳的情形一律走失败包封(`confirmation_unknown` / `role_not_registered`)。 */
  settled: z.literal(true),
});
export type ConfirmationResolveResult = z.infer<typeof ConfirmationResolveResultSchema>;

/** `arbitration.status` 能力的 output:仲裁面现状 + 审计落点 + 最近事件(「可查询」那一半)。 */
export const ArbitrationStatusResultSchema = z.object({
  state: ArbitrationStateSchema,
  /** 审计事件全量落这儿(NDJSON,一行一条)。 */
  logPath: z.string().min(1),
  /** 最近若干条(新的在后);要全量请读 `logPath`。 */
  events: z.array(AuditEventSchema),
});
export type ArbitrationStatusResult = z.infer<typeof ArbitrationStatusResultSchema>;

/**
 * **仲裁三码的错误载荷** —— `WireError` 的收窄版:`code` 限定在这三个,且 **`guidance` 必填**。
 *
 * 它的存在就是为了让「拒绝即指引」不再只是一句注释(04 票 CR 抓到的那处口径不实):
 * 契约在这里强制,金标样本按这个 schema 登记,活体报文有"除 id/路径外逐字段等于金标"的对照断言。
 */
export const ConfirmationErrorSchema = WireErrorSchema.extend({
  code: z.enum([
    ErrorCode.confirmationUnavailable,
    ErrorCode.confirmationDenied,
    ErrorCode.confirmationTimeout,
  ]),
  guidance: GuidanceSchema,
});
export type ConfirmationError = z.infer<typeof ConfirmationErrorSchema>;

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

/** 推送帧(08 票)。`id` 现造 —— 它不对应任何请求。 */
export function pushEnvelope(event: KernelEvent): PushEnvelope {
  return { v: PROTOCOL_VERSION, id: crypto.randomUUID(), push: true, event };
}

/**
 * 具名 result 对象 → `JsonValue`(全内核**唯一**的一次类型放行)。
 *
 * 为什么需要它:handler 与 op 的返回值本质上是"某个已登记 result 的形状"(`ProxyStatusResult`
 * `RoleRegisterResult` 之类),而 `JsonValue` 是个递归联合类型 —— TS 不认为一个具名 interface
 * 结构化地属于它(可选字段的 `| undefined` 在联合里对不上),于是每处都要写一遍
 * `as unknown as JsonValue`。**运行时什么都没发生**:那些对象本来就只含 JSON 值。
 * 收敛到这一个函数,是为了让"这里有一次类型放行"只需要读一遍、也只有一个地方可以出错。
 * (真正的形状把关在别处:CLI 侧 `outcomeFromEnvelope` 拿 zod schema 校验 daemon 的应答,漂了就红;
 * 金标样本双向核对同一批形状。)
 */
export function payload(value: object): JsonValue {
  return value as unknown as JsonValue;
}

/** 编码成一帧(带换行)。 */
export function encodeFrame(message: RequestEnvelope | ResponseEnvelope | PushEnvelope): string {
  return `${JSON.stringify(message)}\n`;
}
