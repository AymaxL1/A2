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
  /**
   * `--copy-to-home` 撞上**开发态**(源码跑,不是 `bun build --compile` 的单文件产物)——
   * 没有"自身"可拷:那时的 `process.execPath` 是 bun 自己,拷过去只会得到一个跑不起来的空壳。
   *
   * 归 6 不归 5(15 票):这不是"事没办成",是**这条请求在这个形态的 bin 上根本不成立** ——
   * 与 `service_unsupported_platform` 同档(那条说的是这台机器,这条说的是这个 bin)。
   */
  serviceSelfCopyUnsupported: "service_self_copy_unsupported",
  /**
   * `service uninstall --purge` 撞上**系统代理仍处接管态**(17 票)——**拒绝,且一个字节都不删**。
   *
   * 为什么非拒不可:接管快照(`<A2_HOME>/system-proxy.json`)是把系统代理还原回接管前的**唯一依据**,
   * 而 purge 要删的正是整个 `$A2_HOME`。连它一起删掉 = 系统代理永远指着一个马上就不存在的端口,
   * 当场断网、且再也还原不回去。**绝不"顺手替他还原"**:还原是一条显式命令(ADR 0008 的立场),
   * 内核不在一次卸载里替人改他的网络配置。
   *
   * 归 1 不归 5/6(与 `daemon_already_running` 同档):命令本身完全成立,只是**这会儿不该发** ——
   * 敲一次 `a2 proxy off` 之后同一条命令就成立了。5 是"路走通了、事没办成"(这次连走都没走),
   * 6 是"在这台机器/这个 bin 上根本不成立"(这次只是时机不对)。
   */
  servicePurgeBlocked: "service_purge_blocked",
  /**
   * `--purge` 的目标 `$A2_HOME` 上,这条请求根本不成立(17 票 CR 尾款立,18 票扩到白名单):
   *   * `non_default_home` —— **不是缺省的 `~/.a2`**(18 票用户裁定:purge 只对缺省 home 生效)。
   *     生产路径上唯一会出现的那一档;
   *   * `filesystem_root` / `home_directory` / `home_ancestor` / `not_absolute` —— 17 票那道地板,
   *     18 票之后被上面那条挡在前面,作为**纵深**保留;
   *   * `symlink` / `dangling_symlink` —— 缺省 home 本身是一根符号链接(删链不删树:数据全在链目标里,
   *     而报文会说"删干净了" —— 那是假账)。这一档在 18 票之后**照样可达**。
   *
   * 归 6(与 `service_unsupported_platform` / `service_self_copy_unsupported` 同档):
   * 那两条说"这条请求在这台机器 / 这个 bin 上不成立",这一条说"在这个 `$A2_HOME` 上不成立" ——
   * 等到什么时候都不成立(要成立就得换掉 `A2_HOME`,那已经是另一条请求了),所以不归 1。
   * **`guidance.context.reason` 是这一族的机读分支依据**:六种拒绝共用一个码、各带自己的 reason,
   * 比为同一句话造六个码更好用。
   */
  servicePurgeUnsafeHome: "service_purge_unsafe_home",
  /**
   * 盘上那份 `com.a2.kernel` unit 记着的 `A2_HOME` 与本次调用的不是同一个(17 票 CR 尾款)。
   *
   * 为什么这是一道门:label 是**每用户一个常量**,而 `$A2_HOME` 是**每次调用现算**的。
   * 在 `A2_HOME=/tmp/x` 下 purge,拆掉的是为真 home 装的那两个 unit,而接管快照判据看的是
   * `/tmp/x` 那份 —— 真 home 的还原依据根本不会被看见。放行 = 拆掉可能正承载系统代理的
   * `com.a2.mihomo`,当场断网。
   *
   * 归 1(与 `daemon_already_running` / `service_purge_blocked` 同档):命令没错,是**站错了地方** ——
   * 到那个 home 去执行、或先把那边收拾干净,这条就成立了。
   */
  servicePurgeHomeMismatch: "service_purge_home_mismatch",

  // MARK: mihomo 托管面(06 票立,14 票重塑)—— 五码全部映射退出码 5(路走通了、事没办成)
  //
  // (退场过两条:`mihomo_below_floor` 随收编档 2026-08-12 废除;
  //  `mihomo_foreign_instance_running` 随 14 票的三值托管模式退场 —— 别人的实例在跑不再是一种拒绝,
  //  而是 `off` 态下由用户在 agent 对话里二选一(observe / embedded 并跑)的岔路口。
  //  留一条永远不会出现的错误码,等于让 agent 为一个不存在的分支写代码。)

  /** 该走的那个 mihomo external-controller 连不上(或鉴权不过)。 */
  mihomoUnreachable: "mihomo_unreachable",
  /**
   * 这件事只能对 **a2 自己那份** mihomo 做,而当前托管模式下没有那样一份
   * (`observe` —— 在跑的是别人的;`off` —— 谁的都不管)。
   * 这是「生命周期归原托管方」这条红线在报文上的投影:内核不会替别人重启、也不会替别人换配置。
   */
  mihomoNotManaged: "mihomo_not_managed",
  /** mihomo 面还没启用(模式仍是 `off`)—— 该做的第一件事是让用户选一个模式,不是重试。 */
  mihomoNotEnabled: "mihomo_not_enabled",
  /**
   * 内嵌子进程处于**故障态**(连续启动失败达上限,已暂停重拉)。
   * 此时除了 `a2 mihomo restart`(修完配置后清零重来)之外的操作都没有意义 —— 报文里带的是
   * mihomo 自己 stderr 的原文与配置路径,让 agent 直接去看错在哪。
   */
  mihomoFailed: "mihomo_failed",
  /** mihomo 操作执行了但没成:下载失败、摘要对不上、落位失败、子进程拉起来就退。 */
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

  // MARK: 插件宿主(11 票)—— exec 一次一调的三种收场 + 装载面两码
  //
  // 三条收场码是**按「谁该改什么」分的**,不是按错误发生在哪一层分的:
  //   * `plugin_protocol_error` —— 插件**说的话不合协议**(describe 输出坏了、退出码不在词表、
  //     清单里有的工具它自己不认)。要改的是插件的代码,agent 拿到它就该回去改文件再 `a2 plugin add`。
  //   * `plugin_failed` —— 插件**跑了但没跑成**(未捕获异常、进程被信号打断、非零退出且不在词表)。
  //   * `plugin_timeout` —— 插件在超时窗口内没有交出结果,已被杀掉。
  // 三条都归退出码 5(「路走通了、事没办成」)吗?不 —— 见 `exit-codes.ts`:协议错归 6,
  // 另两条归 5。**超时不归 3**:退出码 3 的语义是「人没点」(确认器在场却没人做决定),
  // 插件卡住与人没点是两件事,agent 的下一步也不同(改插件 vs 去催人)。
  pluginProtocolError: "plugin_protocol_error",
  /** 插件进程跑了但没跑成(未捕获异常 / 被信号打断 / 非零退出)。 */
  pluginFailed: "plugin_failed",
  /** 插件在超时窗口内没有交出结果,已被杀掉(fail-closed:不等、不猜)。 */
  pluginTimeout: "plugin_timeout",
  /** `a2 plugin add` 没装上:文件不在、不是零依赖单文件、describe 不合协议、名字非法。 */
  pluginLoadFailed: "plugin_load_failed",
  /** 指名道姓的那个插件没登记过(`a2 plugin remove` 的对象不存在)。 */
  unknownPlugin: "unknown_plugin",

  // MARK: URL 分流面(url-router 施工 02 票立,04 票接执行器)
  //
  // (退场过一条:`url_router_executor_unwired` —— 02 票为「执行器还没接线」造的临时码。
  //  04 票把那条链接上之后它**永远不会再出现**,而留一条不可达的错误码等于让 agent 为一个
  //  不存在的分支写代码 —— 与 mihomo 那两条退场码同一条口径,不是"只增不改"的例外,
  //  是"这条分支本身没了"。它的三条真实出口现在是:执行器不在场 → `confirmation_unavailable`;
  //  人点了取消 → `confirmation_denied`;120s 没人点 → `confirmation_timeout`。)

  /**
   * 决策做完了、降级链也走完了,但最后那步 `open` 没能把链接交出去
   * (bundle id 不存在、.app 被删了、`open` 非零退出)。
   *
   * 为什么必须是一条错误而不是一行日志(母本就只写日志):对 agent 与 CLI 而言,
   * 「分流成功」与「链接压根没打开」是天差地别的两件事,而它们在报文上唯一的区别就是这一码。
   */
  urlRouterOpenFailed: "url_router_open_failed",
  /**
   * `takeover` / `restore` 走完了整条执行链,但**只成了一半**:http 与 https 是两次独立的系统弹框,
   * 用户完全可能同意一个、取消另一个(spec §5 明写的一种收场)。
   *
   * 为什么它值一个自己的码而不是并进 `capability_failed`:这一档的下一步是**补齐另一半**
   * (报文里的 `perScheme` 指名道姓说了缺哪个),而不是"这件事没办成、换个参数再来"。
   * 归 5:路走通了、事只办成了一半 —— 半成品也是"执行了但没到位",不是参数错。
   */
  urlRouterPartialTakeover: "url_router_partial_takeover",
  /**
   * `url-router.executor.report` 指向的那条执行指令不存在,或**已经收场了**
   * (超时了 / 同一条指令已经回过一次 / 内核已停)。
   *
   * 与 `confirmation_unknown` 逐字同构 —— 它们是同一件事在两条链上的投影:
   * **首个回话收场胜出**,迟到的那一条拿到的是"没有这条待办了",而不是把已经收场的结果改写掉。
   * 归 6(同 `confirmation_unknown`):这条报文本身不成立。
   */
  urlRouterExecutionUnknown: "url_router_execution_unknown",
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
  /**
   * 机械执行器回报一条执行指令帧的结果(url-router 施工 04 票)。
   * **只有注册过 `url-router-executor` 的连接能发**,与 `confirmations.resolve` 逐条同构。
   *
   * 为什么不做成能力:与那条同理 —— 它没有独立语义,只是内核发起的那次编排的下半程,
   * 而且它的合法性取决于"这句话是哪条连接说的"(角色是连接的属性)。
   */
  urlRouterExecutorReport: "url-router.executor.report",

  // MARK: 插件面(11 票)—— 装载零闸,仲裁只在调用层
  //
  // 三条都走 daemon 而不是 CLI 本地办:**能力注册表住在 daemon 进程里**,装载就是往那张表上加东西
  // (04 票「唯一调用面」的直接推论)。所以 `a2 plugin add` 与 `a2 capabilities call` 同一条路。

  /** 登记一个零依赖单文件插件(即时生效,无确认闸;审计事件推给订阅者)。 */
  pluginAdd: "plugin.add",
  /** 列出已登记插件(机读:工件路径、装载时刻、工具清单、派生出的能力 id)。 */
  pluginList: "plugin.list",
  /** 卸掉一个插件(它的能力当场从注册表消失)。 */
  pluginRemove: "plugin.remove",

  // MARK: mihomo 内嵌子进程的**内部命令**(14 票)—— 不进能力表,与 `confirmations.resolve` 同类
  //
  // 为什么不做成能力:能力是**给 agent 用的调用面**(有 manifest、有仲裁、有别名),而这两条是
  // 「CLI 刚把模式落了盘,通知 daemon 照着办」——它们没有独立的语义,只是同一条命令的下半程。
  // mihomo 域整体不进能力表这条口径(builtin.ts)因此一字未改。

  /** 按落盘的托管模式收敛内嵌子进程(embedded → 确保在跑;off/observe → 确保停了)。 */
  mihomoApply: "mihomo.apply",
  /** 显式重启内嵌子进程(**连续失败计数清零**:故障态唯一的出路)。 */
  mihomoRestart: "mihomo.restart",
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

/**
 * `a2 guide --json` 的 result:**给 AI 助手的 A2 使用说明全文**(08 票)。
 *
 * 与 `help` 分成两条而不是复用它:`help` 是命令表(给人和 agent 查参数),`guide` 是**上手说明**
 * (agent 读完就知道先跑什么、配置归谁改、哪些事不许干)。两者的读者与更新节奏都不同,
 * 挤进同一个 `usage` 字段只会让「面板复制一段说明」与「打印帮助」互相牵制。
 * 同样无 op、不经 daemon —— 说明必须在内核没跑的时候也读得到。
 */
export const GuideResultSchema = z.object({
  text: z.string().min(1),
});
export type GuideResult = z.infer<typeof GuideResultSchema>;

// MARK: - `a2 about`:GPL 义务的必有落点(13 票,ADR 0007 修订版)
//
// 裁决序里**法律义务在 agent-first 之上**,而义务的**落点必须 CLI 化**(ADR 0008 第 4 条):
// 于是这条 result 与 `version` / `help` 同类 —— **无 op、不经 daemon**。
// 理由不是"省一次往返",而是:daemon 没装、没跑、装坏了,声明都必须读得到。
// 把履行义务的唯一入口挂在一个可能不在的进程上,等于没履行。

/**
 * 被调用的**外部**程序(不随包分发,ADR 0007 修订版)。
 *
 * `bundled` 恒为 `false` 且**写死在契约里**:它不是一个"当前取值",是一条不许翻的承诺 ——
 * 哪天有人真往分发物里塞了 GPL 二进制,这条 schema 会当场拒绝那份报文(义务面随之全变,
 * 那是一次要改 ADR 的决策,不该靠改一个布尔值悄悄发生)。
 */
export const ExternalProgramSchema = z.object({
  name: z.string().min(1),
  /** 它在 a2 里担任什么(如"代理数据面")。 */
  role: z.string().min(1),
  license: z.string().min(1),
  /** 安装脚本会装的锁定版(与 `MihomoStatusResult.lockedVersion` 同源)。 */
  lockedVersion: z.string().min(1),
  /** **恒为 false**:我们不分发它的二进制。 */
  bundled: z.literal(false),
  /** 怎么被调用的 —— 独立子进程红线的原文落点。 */
  invocation: z.string().min(1),
  /** 源码获取地址(GPL 的"源码获取指引"义务落在这里)。 */
  source: z.string().min(1),
  /** 发布渠道(安装脚本从这里取二进制)。 */
  releases: z.string().min(1),
  /** 许可证全文的公开地址。 */
  licenseUrl: z.string().min(1),
});
export type ExternalProgram = z.infer<typeof ExternalProgramSchema>;

/** 随包静态文本的一条:名字、用途、**应当在的位置**、以及此刻在不在。 */
export const NoticeFileSchema = z.object({
  name: z.string().min(1),
  purpose: z.string().min(1),
  /** 与 `a2` 同目录的绝对路径(单文件直接下载时可能不在 —— `present` 说的就是这件事)。 */
  path: z.string().min(1),
  present: z.boolean(),
});
export type NoticeFile = z.infer<typeof NoticeFileSchema>;

/** `a2 about --json` 的 result。人类面(无 `--json`)是同一批事实的散文渲染,不另写一套说辞。 */
export const AboutResultSchema = z.object({
  product: z.string().min(1),
  version: z.string().min(1),
  protocol: z.literal(PROTOCOL_VERSION),
  /** a2 本体的许可口径(它不含也不链接任何 GPL 代码 —— 这正是红线的意义)。 */
  license: z.string().min(1),
  externalPrograms: z.array(ExternalProgramSchema).min(1),
  /** 外部程序声明的**静态正文**:随包文本与本字段是同一份字节。 */
  declaration: z.string().min(1),
  noticeFiles: z.array(NoticeFileSchema).min(1),
  /** 升级口径。**没有静默更新**(spec 分发节 / ADR 0006 暂缓清单),这句话进机读面。 */
  upgrade: z.string().min(1),
});
export type AboutResult = z.infer<typeof AboutResultSchema>;

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
 * dangerous 能力的**确认模式**(url-router 施工 04 票新增,取值即契约)。
 *
 *   * `confirm-agent` —— **缺省,也是绝大多数能力唯一该用的那个**:ADR 0005 第 4 条那三层
 *     (无确认器默拒 → 拒绝即指引 → 带外确认)。人在**菜单栏壳的确认框**上点头。
 *   * `os-dialog` —— 确认由**操作系统自己的弹框**承载:内核把执行指令下发给壳,壳调系统 API,
 *     OS 强制呈现一个 agent 伪造不了的框,结果经 completion 回到内核。此时再叠一层 confirm-agent
 *     就是**双确认**(04 决策底账明确否掉的方案),所以这一档**跳过**那三层,
 *     由执行指令帧的往返充当确认仪式本身。
 *
 * **它不是"免确认"的后门,而是"确认换了个地方"**:ADR 0015 把可复用的判据写死成三条
 * (OS 强制呈现、agent 伪造不了、结果可被发起方感知),三条缺一不可 —— 缺一条就只能用
 * `confirm-agent`。眼下满足三条的只有 `url-router.takeover` / `url-router.restore`
 * (`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`,01 研究票钉死),
 * **门禁有断言把这份名单钉死**:别的 dangerous 能力若被标成 os-dialog,测试当场红。
 */
export const ConfirmationModeSchema = z.enum(["confirm-agent", "os-dialog"]);
export type ConfirmationMode = z.infer<typeof ConfirmationModeSchema>;

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
  /**
   * 这条 dangerous 能力的**确认由谁承载**(url-router 施工 04 票)。
   * 缺省(不带这个字段)= `confirm-agent`,即现状:走 ADR 0005 第 4 条那三层。
   * 只对 `risk: "dangerous"` 有意义;别的档带了也不改变任何行为(它们本来就直通)。
   */
  confirmation: ConfirmationModeSchema.optional(),
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
  /**
   * 把本 bin 自己拷进了 `$A2_HOME/bin/a2`(15 票 `--copy-to-home`)。
   * **只在内容真的变了(或本来就不在)时出现** —— 同一份 bin 复跑 install 不报这一条。
   */
  "bin_copied",
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
  /** 显式停止了内核进程,但保留 unit 与开机自启登记。 */
  "kernel_stopped",
  /**
   * 显式重启了内核进程。**两个产出面,各占一端**:
   *   * **unit 内容漂了而服务正跑着** —— 重写文件不足以让已经在跑的那个进程换成新内容。这一路
   *     只有 systemd 走得到;launchd 的同一情形表现为 `supervisor_unloaded` + `supervisor_loaded`。
   *   * **拷贝换了而 unit 没变**(15 票 `--copy-to-home` 的显式升级)—— unit 一个字没动,
   *     收敛逻辑因此什么都不做,而跑着的进程还攥着旧 bin。这一路**两端都走得到**。
   *
   * **代价要说清**:重启换的是进程,于是**所有在途长连接当场断开** —— 已注册的角色随连接消失,
   * 在途的 dangerous 确认按「断线即默拒」收尾(08 票的语义,不因升级而例外)。
   * 面板/订阅者断后自行重连,重连拿到的是新内核的一份全量快照。
   */
  "kernel_restarted",
  /**
   * 拆掉了 **a2 自管的** mihomo unit(`com.a2.mihomo`:bootout + 删 unit 文件)。
   * **只在 `uninstall --purge` 里出现**,而且只在那个 unit 真的在时才出现(不在则整条不报)。
   *
   * 为什么内核的卸载会碰它:`--purge` 承诺的是「a2 在这台机器上留下的东西没了」,而 a2 托管的
   * mihomo 正是 a2 装的。**红线**:范围恒是 `com.a2.*` 那两个 label —— 用户自己装的 mihomo
   * (`io.metacubex.mihomo` 等)在任何路径下都不在清理范围内,契约层由 `ServicePurgeReport`
   * 的 label 形状(`^com\.a2\.`)钉着。
   */
  "mihomo_unit_removed",
  /**
   * 删掉了整个 `$A2_HOME`(17 票 `uninstall --purge`)。**不可撤销**,所以它有三道前置:
   * 系统代理未处接管态(否则结构化拒绝、零删除)、内核进程真的没了、托管的 mihomo 也真的没了。
   * 删的**只有** `$A2_HOME` 这一棵树,路径在 `purge.removedPaths` 里如实列出(先看后删)。
   */
  "home_purged",
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
   /**
   * unit 实际指向的可执行(15 票)。取值语义与 `unitPath` 同一口径:
   *   * unit 文件在**且形状解得出** → **从盘上那份 unit 里读出来的** argv[0],即此刻真被托管的那个 bin;
   *   * unit **不在,或形状解不出**(不是本内核写的 / 被人改坏了)→ 回落到本次调用**会写**的那个
   *     (`--copy-to-home` 时是 `$A2_HOME/bin/a2`,否则是当前这个 bin 自己)。
   *
   * 面板据此判断"托管的是不是我这份内核" —— 所以它必须是**盘上的事实**,而不是本次调用的计划。
   */
  binPath: z.string().min(1),
  /** supervisor 认不认识这个 unit。 */
  registered: z.boolean(),
  /** 运行中才有;supervisor 报的进程号。 */
  pid: z.number().int().positive().optional(),
  /** 展开后的 A2_HOME 与 socket 路径(agent 免猜,与 `status.get` 同口径)。 */
  home: z.string().min(1),
  socketPath: z.string().min(1),
});
export type ServiceStatusResult = z.infer<typeof ServiceStatusResultSchema>;

/**
 * 内核自己碰得到的 unit label 的形状(17 票的**红线在契约层的投影**)。
 *
 * `purge` 的移除清单只允许 `com.a2.*` —— 于是"用户自己装的 mihomo(`io.metacubex.mihomo`)
 * 出现在清理范围里"这件事**在 schema 层就不合法**,不必等到读代码或读测试才发现。
 * 导出的 JSON Schema 里它是一条 `pattern`,agent 与 Swift 侧读同一份约束。
 */
export const A2_UNIT_LABEL_PATTERN = /^com\.a2\.[a-z0-9]+$/;

/**
 * `--purge` 的**对账面**(17 票):这一次到底摘掉了哪几个 unit、删掉了哪几棵树。
 *
 * 为什么要单列而不是让人从 `actions` 反推:`actions` 说的是"做了哪一类事",而删除是不可撤销的 ——
 * 「先看后删」要求报文里有**具体到 label 与绝对路径**的账,人和 agent 才能在事后核对
 * (以及在事前用 `--json` 看一眼同一形状的空账:两个数组都空 = 没什么可删的)。
 */
export const ServicePurgeReportSchema = z.object({
  /**
   * 本次真的**从 supervisor 摘下**的 label(unit 文件在则一并删掉);有序,恒是 `com.a2.*`。
   *
   * 措辞要紧:判据是"这一次对它做了收敛动作",而**不是**"它的文件被删了" —— 半装状态
   * (supervisor 认识它但文件早没了)同样算摘下,它也确实该记进账里。
   */
  removedUnits: z.array(z.string().regex(A2_UNIT_LABEL_PATTERN)),
  /**
   * 本次真的删掉的根路径(恒是 `$A2_HOME` 这一条;没删则为空数组)。
   * **绝对路径**:相对路径在删除的账上毫无意义(读账的人不知道相对谁),schema 层就钉死。
   */
  removedPaths: z.array(z.string().regex(/^\//)),
});
export type ServicePurgeReport = z.infer<typeof ServicePurgeReportSchema>;

/** `a2 service install|uninstall` 的 result:收敛后的状态 + 本次真改了什么。 */
export const ServiceChangeResultSchema = z.object({
  /** 收敛后的服务状态(与 `a2 service status` 同一形状,免得再问一次)。 */
  status: ServiceStatusResultSchema,
  /** 本次实际执行的动作;**空数组 = 本来就是这个样子**(幂等复跑)。 */
  actions: z.array(ServiceActionSchema),
  /**
   * 只有 `uninstall --purge` 才有(17 票)。**在场本身就是信号**:这一次走的是 purge 那条路;
   * 不在场 = 这是一次普通的 install/uninstall,`$A2_HOME` 一个字节都没动。
   */
  purge: ServicePurgeReportSchema.optional(),
});
export type ServiceChangeResult = z.infer<typeof ServiceChangeResultSchema>;

// MARK: - mihomo 托管面 result(06 票立,14 票重塑)
//
// 与服务面同一种口径:**status 没有对应的 op**。「本机 mihomo 是个什么现状」问的是配置、文件系统与
// external-controller,不是 daemon 自己;daemon 没跑的时候这条命令更要能答话。
//
// 14 票(ADR 0014)把这一面整个换了骨:**mihomo 不再挂自己的 unit,而是 a2 daemon 的直接子进程**,
// 随 a2 生、随 a2 死。于是「共存阶梯」(presence / rung / provisioned / 复用档)整族退场,
// 取而代之的是一个**用户显式裁定、一次性落盘**的三值托管模式:
//   * `off`      —— 不管(出厂缺省);
//   * `observe`  —— 只读旁观本机已有的那份(ADR 0013 的只读契约原样并入);
//   * `embedded` —— a2 自己拉起一个子进程(锁定版二进制,配置由 a2 渲染)。
//
// 一条贯穿本节、且比以前更硬的红线:**别人那份 mihomo 的生命周期归它的主人**。内核对它只做只读探测,
// 绝不 stop/restart/kill、也不替它改配置;它只出现在 `foreign` 与 guidance 里,没有任何一条写路径通向它。

/** 托管模式三值(取值即契约)。缺省 `off`;切换是**人的显式裁定**,内核绝不因为检测结果自己改。 */
export const MihomoManagedModeSchema = z.enum(["off", "observe", "embedded"]);
export type MihomoManagedMode = z.infer<typeof MihomoManagedModeSchema>;

/** 实例归属:`a2` = a2 自己那份(14 票起 = daemon 的子进程);`foreign` = 别人的(内核只读不碰生死)。 */
export const MihomoOwnerSchema = z.enum(["a2", "foreign"]);
export type MihomoOwner = z.infer<typeof MihomoOwnerSchema>;

/**
 * 能力位 —— **观察到的事实,不是推断**:每一位都对应一次真实探测。
 *   * `rest_api` —— `GET /version` 应答了;
 *   * `meta_core` —— `/version` 的 `meta` 为真(mihomo 系内核,不是原版 clash);
 *   * `configs_read` —— `GET /configs` 读得到。
 */
export const MihomoCapabilitySchema = z.enum(["rest_api", "meta_core", "configs_read"]);
export type MihomoCapability = z.infer<typeof MihomoCapabilitySchema>;

/**
 * 内嵌子进程的三态。**判据是进程本身**(认尸文件里的身份 + 那个 pid 此刻活不活),不是控制面通不通 ——
 * 「进程在但控制面还没就绪」与「进程压根没了」是两件事,报文必须分得清。
 *   * `running` —— 子进程活着(`pid` 必在);
 *   * `stopped` —— 没在跑(还没启用、daemon 没跑、或刚被 disable);**这不是故障**;
 *   * `failed`  —— 连续启动失败达到上限,a2 **已暂停重拉**(`lastError` 必在,内容是 mihomo stderr 尾部原文)。
 */
export const MihomoEmbeddedStateSchema = z.enum(["running", "stopped", "failed"]);
export type MihomoEmbeddedState = z.infer<typeof MihomoEmbeddedStateSchema>;

/**
 * a2 自己那份(内嵌子进程)的落点与状态。**未启用时路径照样给出**:那是启用会写的位置,agent 不必猜。
 *
 * `restartCount` 是**连续**失败次数(不是历史累计):子进程正常活过一段时间就清零,
 * `a2 mihomo restart` 也清零 —— 它要回答的是「此刻离故障态还有几步」,而不是「这台机器上一共崩过几次」。
 */
export const MihomoEmbeddedSchema = z.object({
  state: MihomoEmbeddedStateSchema,
  /** 子进程 pid(`state=running` 时必在)。 */
  pid: z.number().int().positive().optional(),
  /** 落点上那份二进制的路径(不在盘上时也给 —— 那是下载会落到的位置)。 */
  binaryPath: z.string().min(1),
  /** 落点上那份二进制自报的版本(`mihomo -v`;不在盘上或问不出则缺省)。 */
  binaryVersion: z.string().optional(),
  /** 内核会装的锁定版。`binaryVersion` 与它不一致 = 下次拉起前自动换二进制(升级随 a2 走)。 */
  lockedVersion: z.string().min(1),
  configPath: z.string().min(1),
  dataDir: z.string().min(1),
  /** a2 自管实例的 external-controller(恒回环 + secret)。 */
  controller: z.string().min(1),
  /** 那个控制端点此刻答不答话(有 pid ≠ 能用)。 */
  controllerReachable: z.boolean(),
  /** 配置里有没有代理节点(面板「尚未配置节点」提示行的**机读判据** —— 壳不解析散文)。 */
  hasProxies: z.boolean(),
  /** 连续启动失败次数(达到上限即转 `failed`)。 */
  restartCount: z.number().int().nonnegative(),
  /** `failed` 必带:最近一次失败时 mihomo 自己在 stderr 上说的话(**原文**,不转述)。 */
  lastError: z.string().optional(),
});
export type MihomoEmbedded = z.infer<typeof MihomoEmbeddedSchema>;

/** 盘上一份**别人的** mihomo 二进制的事实(只读报告:内核既不改它也不复用它)。 */
export const MihomoBinarySchema = z.object({
  path: z.string().min(1),
  version: z.string().optional(),
});
export type MihomoBinary = z.infer<typeof MihomoBinarySchema>;

/**
 * 别人那个实例的事实。**全部来自只读探测**:配置里读到的回环地址 + 一次 `GET /version`。
 * `reachable=false` 也要如实报(「配置里写着但连不上」本身就是事实,observe 模式的态 D 靠它)。
 */
export const MihomoForeignInstanceSchema = z.object({
  /** 归一后的连接目标(恒 `127.0.0.1:<port>`)。 */
  controller: z.string().min(1),
  /** 配置里原样写的地址(可能是 `0.0.0.0:9090` 之类)。 */
  address: z.string().min(1),
  /** 那个端点是否配了 secret。 */
  secretConfigured: z.boolean(),
  /** 这个地址是从哪份配置里读到的(显式指定时缺省)。**那是别人的文件,内核只读那两行**。 */
  configFile: z.string().optional(),
  reachable: z.boolean(),
  version: z.string().optional(),
  capabilities: z.array(MihomoCapabilitySchema),
});
export type MihomoForeignInstance = z.infer<typeof MihomoForeignInstanceSchema>;

/**
 * 「本机上不归 a2 管的那些 mihomo 事实」。**在场即报告,永不动手** —— observe 模式读它、
 * embedded 模式用它出并跑提醒,两条路都止于文字。
 */
export const MihomoForeignSchema = z.object({
  binary: MihomoBinarySchema.optional(),
  instance: MihomoForeignInstanceSchema.optional(),
  /** 配置里写着、但不是回环因而**内核有意没去探**的 external-controller(如实报告,不静默丢弃)。 */
  skippedController: z.string().optional(),
});
export type MihomoForeign = z.infer<typeof MihomoForeignSchema>;

/**
 * `a2 mihomo status` 的 result:模式 + 自己那份的实况 + 别人那些的事实 + 给 agent 的下一步指引。
 *
 * `guidance` 在这里**不是错误载荷**(这条命令永远成功),而是「第一读者是 agent」的落点:
 * 六种典型处境各有一段定稿文本,agent 读它就知道该跟用户说什么、该执行哪条命令。
 */
export const MihomoStatusResultSchema = z.object({
  mode: MihomoManagedModeSchema,
  embedded: MihomoEmbeddedSchema,
  /** 三样外来事实一样都没有时缺省(不是空对象 —— 「什么都没检测到」该是一眼可见的形状)。 */
  foreign: MihomoForeignSchema.optional(),
  /**
   * 检出了**旧版 a2 自己装的** `com.a2.mihomo` unit(14 票起内核不再写它)。
   * 只有 true 才出现;`enable --mode=embedded` 会顺手把它 bootout + 删 plist(自己的遗产自己收)。
   * **别人的 unit 永远不在这个字段的射程内**。
   */
  legacyUnit: z.boolean().optional(),
  guidance: GuidanceSchema.optional(),
  home: z.string().min(1),
});
export type MihomoStatusResult = z.infer<typeof MihomoStatusResultSchema>;

/**
 * mihomo 面的收敛动作(审计素材,词表封闭)。**每一个动作都只作用在 a2 自己那份上** —— 那是设计,不是遗漏:
 * 词表里压根没有一个动词能施加于别人的实例。
 */
export const MihomoActionSchema = z.enum([
  /** 托管模式落盘了(`<A2_HOME>/mihomo/settings.json`)。 */
  "mode_set",
  /** 建了 a2 自管的数据目录。 */
  "data_dir_created",
  /** 写(或收敛)了 a2 自管的配置文件。 */
  "config_written",
  /** 按锁定版下载 + 校验 + 落位了二进制(本来没有)。 */
  "binary_downloaded",
  /** 盘上那份不是锁定版 → 换成了锁定版(升级随 a2 走,不再有独立的 upgrade 命令)。 */
  "binary_upgraded",
  /** 拉起了内嵌子进程。 */
  "child_started",
  /** 停掉了内嵌子进程(SIGTERM → 超时 SIGKILL)。 */
  "child_stopped",
  /** 拆掉了**旧版 a2 自己装的** `com.a2.mihomo` unit(bootout + 删 plist)。自己的遗产自己收。 */
  "legacy_unit_removed",
]);
export type MihomoAction = z.infer<typeof MihomoActionSchema>;

/** `a2 mihomo enable|disable|restart` 的 result:收敛后的状态 + 本次真改了什么(空数组 = 本来就这样)。 */
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
//   * 归 a2 管(自管那份)→ 配置文件、整份重载、订阅激活全都可以;
//   * 不归 a2 管(别人托管的那份)→ 凡是"换配置文件"的动作一律 `mihomo_not_managed`。
//     这是「生命周期归原托管方」在代理面的投影。
//
// **注(2026-08-12)**:上面这条边界描述的是能力**本身**的语义,与它此刻开不开放是两件事 ——
// 会对 external-controller 发写请求的那一族当前整体停用(`capability/proxy.ts` 的
// `DISABLED_CAPABILITY_IDS`),留下的只有读。恢复时这条边界原样生效。

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
  /** a2 自管那份的配置文件路径(别人那份缺省 —— 那是别人的文件,内核不写)。 */
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

/**
 * a2 自管配置里的可调项(**只有这几项可调** —— 其余由内核渲染,手改会在下次收敛时被改回),
 * 外加 14 票的**托管模式**:落点同为 `<A2_HOME>/mihomo/settings.json`。
 *
 * 为什么模式住在这里而不是另起一份状态文件:它与端口/日志级别是同一类东西 ——
 * **人显式设过一次、之后每次启动照着办的设置**。多一份文件就多一处会漂的事实源。
 */
export const ProxySettingsSchema = z.object({
  /** 混合入站端口(HTTP + SOCKS 同一个;系统代理接管指向的就是它)。 */
  mixedPort: z.number().int().positive(),
  allowLan: z.boolean(),
  logLevel: z.enum(["silent", "error", "warning", "info", "debug"]),
  /** 写进配置文件的默认模式(运行时改 mode 走 `proxy.mode.set`,不落盘)。 */
  mode: ProxyModeSchema,
  /**
   * mihomo 托管模式(14 票)。**缺省 `off`** —— 而且这个缺省写在 schema 上,
   * 于是 14 票之前落盘的那份 settings.json(没有这个键)照样解析得动,不会因为"少一个键"
   * 被整份判为不合契约、把用户设过的端口一起丢掉。
   */
  managedMode: MihomoManagedModeSchema.default("off"),
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
    /** 盯的对象换了(比如自管那份的控制端点变了)。 */
    "target_changed",
    /** daemon 要停了。 */
    "watch_stopped",
  ]),
  controller: z.string().min(1),
  owner: MihomoOwnerSchema,
  detail: z.string().optional(),
  /** `instance_down` 必带 —— 「人类如何完成」与 status 故障态(guidance 态 C)同源:restart。 */
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

// MARK: - URL 分流面 result(url-router 施工 02 票,spec §3/§4)
//
// 五条能力三种 result:`status` 报现状、`decide` 报一个判断、`route` 报"从哪儿出去的",
// `takeover` / `restore` 共用一条(它们是同一件事的两个方向:把 handler 设成某个 bundle id)。

/**
 * 配置的**可外传视图** —— 与 `url-router/config.ts` 的 `RedactedUrlRouterConfig` 逐字段对应。
 *
 * `roxyAPIKey` 在这里只剩 `roxyAPIKeyConfigured` 一个布尔:spec §8 的那条纪律
 * (「只留本机文件,不入 git、不进快照推送、不进日志」)在契约层就把值挡住 ——
 * 报文里根本没有可以放它的字段,谁想漏也漏不出来。
 */
export const UrlRouterConfigViewSchema = z.object({
  fallbackBrowserBundleID: z.string().min(1),
  routedDomains: z.array(z.string()),
  roxyApplicationPath: z.string(),
  roxyProcessMatch: z.string(),
  roxyProfilePathMarker: z.string(),
  roxyProfileID: z.string(),
  roxyAPIHost: z.string().nullable(),
  roxyAPIOpenPath: z.string(),
  roxyAPITokenHeader: z.string(),
  roxyWorkspaceID: z.number().int().nullable(),
  roxyForceOpen: z.boolean(),
  roxyAPITimeoutSeconds: z.number(),
  roxyStartupAttempts: z.number().int(),
  roxyStartupDelaySeconds: z.number(),
  /** 设过 key 没有(**值永不外传**)。 */
  roxyAPIKeyConfigured: z.boolean(),
});
export type UrlRouterConfigView = z.infer<typeof UrlRouterConfigViewSchema>;

/**
 * 系统默认 handler 的现状。
 *
 * 三个字段都可能是 `null`,且 `null` 是**一句真话而不是缺省值**:LaunchServices 那份库里
 * 一台从没换过默认浏览器的机器根本没有对应条目。报 `null` + `undetermined` 说清"未能判定",
 * 好过猜一个 —— 猜错会让 `takeover` 的幂等判据多出一个错误答案。
 */
export const UrlRouterHandlerSchema = z.object({
  http: z.string().nullable(),
  https: z.string().nullable(),
  /** 两个 scheme **都**是目标才算是;有一个读不出来就是 `null`。 */
  matchesTarget: z.boolean().nullable(),
  /** 读不出来时说清为什么(如实说「未能判定」)。完整的悬空诊断归 05 票。 */
  undetermined: z.string().optional(),
});
export type UrlRouterHandler = z.infer<typeof UrlRouterHandlerSchema>;

/** `url-router.status` 的 result:配置健康 + handler 现状(只读,spec §3/§8)。 */
export const UrlRouterStatusResultSchema = z.object({
  /** 配置文件该在哪儿(在不在是另一回事,见 `configSource`)。 */
  configPath: z.string().min(1),
  /** 这份生效配置怎么来的:全缺省 / 文件合并 / 文件用不了已整份退回缺省。 */
  configSource: z.enum(["defaults", "file", "unusable"]),
  /** `configSource === "unusable"` 时说清是什么毛病(**绝不带文件原文片段**)。 */
  problem: z.string().optional(),
  config: UrlRouterConfigViewSchema,
  /** 接管的目标身份(`com.a2.panel`)—— agent 免猜。 */
  panelBundleID: z.string().min(1),
  handler: UrlRouterHandlerSchema,
});
export type UrlRouterStatusResult = z.infer<typeof UrlRouterStatusResultSchema>;

/** `url-router.decide` 的 result:一条 URL 的判决,**不执行**(CLI `route --dry-run` 的落点)。 */
export const UrlRouterDecideResultSchema = z.object({
  /** 脱敏后的 URL(query/fragment 换成 redacted)。原文永不回显。 */
  url: z.string().min(1),
  /** spec §3 词表:`fallback-browser` / `roxy-cdp:<port>` / `roxy-api` / `roxy-launcher` / `unsupported`。 */
  decision: z.string().min(1),
  /** 探到的目标 profile CDP 端口(没探到就没有这个字段 —— 绝不写 0 冒充"没有")。 */
  roxyDevToolsPort: z.number().int().positive().optional(),
});
export type UrlRouterDecideResult = z.infer<typeof UrlRouterDecideResultSchema>;

/** 真的从哪一级出去的(决策词说"该走哪儿",这个说"实际走的哪儿")。 */
export const UrlRouterActionSchema = z.enum([
  "cdp-new-tab",
  "roxy-api",
  "roxy-launcher",
  "fallback-browser",
]);
export type UrlRouterAction = z.infer<typeof UrlRouterActionSchema>;

/** `url-router.route` 的 result:决策 + 执行(spec §3)。 */
export const UrlRouterRouteResultSchema = z.object({
  url: z.string().min(1),
  decision: z.string().min(1),
  action: UrlRouterActionSchema,
  /** 交给谁:bundle id / .app 路径 / `127.0.0.1:<port>`。 */
  target: z.string().min(1),
  /**
   * 决策的那一级没走通、降下来了吗。**降级不是失败**(ok 照旧、退出码 0),
   * 但它必须在报文里看得见 —— 否则"每次都要多等两秒"这种事永远查不出原因。
   */
  fellBack: z.boolean(),
  /** 这一趟的步骤(已脱敏)。母本写日志文件的那些话进这儿 —— spec §8 不设独立 logPath。 */
  steps: z.array(z.string()),
});
export type UrlRouterRouteResult = z.infer<typeof UrlRouterRouteResultSchema>;

/** 能被接管的两个 scheme —— 只有这两个(spec §3/§5)。 */
export const UrlRouterSchemeSchema = z.enum(["http", "https"]);
export type UrlRouterScheme = z.infer<typeof UrlRouterSchemeSchema>;

/**
 * 一个 scheme 上系统 API 回来的原样错误(04 票)。
 *
 * **三个字段是 `NSError` 的三件套,原样序列化、不翻译、不归类**:壳是机械执行器,
 * 它没有资格判断"这个 domain/code 是用户取消还是别的什么" —— 那种判断一旦写进壳,
 * 就等于让壳替内核决定一次 dangerous 调用的收场。真值只有一份,在内核的映射表里。
 *
 * (spec §11 遗留项:用户取消时这三个字段的实际取值要在 06 票的真机弹框旅程里回填 ——
 *  在那之前**没有人编造它**,内核的映射靠壳自报的 `outcome`,不靠猜 domain/code。)
 */
export const UrlRouterExecutorErrorSchema = z.object({
  /** `NSError.domain` 原文。 */
  domain: z.string().min(1),
  /** `NSError.code` 原值(可能是负数)。 */
  code: z.number().int(),
  /** `localizedDescription` 原文。 */
  description: z.string().min(1),
});
export type UrlRouterExecutorError = z.infer<typeof UrlRouterExecutorErrorSchema>;

/** 单个 scheme 的执行结果:成了没有,没成带上原样错误。 */
export const UrlRouterSchemeReportSchema = z.object({
  ok: z.boolean(),
  /** `ok: false` 时的原样 NSError(`ok: true` 时**没有这个字段**)。 */
  error: UrlRouterExecutorErrorSchema.optional(),
});
export type UrlRouterSchemeReport = z.infer<typeof UrlRouterSchemeReportSchema>;

/**
 * 逐 scheme 的执行结果表。
 *
 * 两个成员**都是可选的**,这是真话而不是宽松:壳可能在解析目标 app 那一步就失败了
 * (一个系统调用都没发,于是一个 scheme 都没有结果),也可能第一个 scheme 就撞上错误。
 * 缺席 = 「这个 scheme 压根没轮到」,与 `{ok:false}`(轮到了、没成)是两件事。
 */
export const UrlRouterPerSchemeSchema = z.object({
  http: UrlRouterSchemeReportSchema.optional(),
  https: UrlRouterSchemeReportSchema.optional(),
});
export type UrlRouterPerScheme = z.infer<typeof UrlRouterPerSchemeSchema>;

/**
 * `url-router.takeover` / `url-router.restore` 的 result(04 票补齐执行那一半)。
 *
 * 两种成功收场,由 `outcome` 分辨:
 *   * `already` —— 当前 handler 已经是目标,**一个系统调用都没发、一个框都没弹**(spec §3 幂等判据);
 *   * `confirmed` —— 执行指令帧走完一个来回,两个 scheme 都成了。
 * 别的收场(拒绝 / 超时 / 半成 / 执行不了)一律走**失败包封**,不在这条 result 里 ——
 * 「成了」与「没成」不共用一个形状,agent 就不必先读 result 再判断它是不是其实失败了。
 *
 * **`handler` 是执行之后现读的一份**:LaunchServices 的登记可能比 completion 回调晚一步,
 * 所以它未必立刻就等于目标 —— 本次执行的直接结果以 `outcome` / `perScheme` 为准,
 * `handler` 说的是"内核此刻读到的系统现状"。两者都如实给,不替谁圆场。
 */
export const UrlRouterHandoffResultSchema = z.object({
  /** 要成为 http+https 默认 handler 的那个 bundle id。 */
  target: z.string().min(1),
  /** 当前 handler 已经是目标 —— 幂等直通,不弹框(spec §3「幂等判据」)。 */
  already: z.boolean(),
  handler: UrlRouterHandlerSchema,
  /** 这一次是怎么收场的(04 票新增;02 票的样本不带它,`already: true` 即等价)。 */
  outcome: z.enum(["already", "confirmed"]).optional(),
  /** 逐 scheme 的执行结果(`already` 那一路没有 —— 它什么都没执行)。 */
  perScheme: UrlRouterPerSchemeSchema.optional(),
});
export type UrlRouterHandoffResult = z.infer<typeof UrlRouterHandoffResultSchema>;

// MARK: - 执行指令帧与回执(url-router 施工 04 票,spec §6.3)
//
// 这一对是**内核 ↔ 机械执行器**之间的全部协议。它与确认器那一对(`ConfirmationRequest` /
// `ConfirmationResolveParams`)形状同构、纪律同源,但**语义完全不同**,值得写清楚:
//
//   * 确认器收到的是「有人要干这件事,你替人看一眼」——它的回答是**决定**;
//   * 执行器收到的是「去把这件事做了」——它的回答是**结果**。执行器**零判断**:
//     唯一合法反应是照帧上写的调系统 API,再把 completion 原样回传。它不许挑 scheme、
//     不许改 bundleID、不许自己决定要不要弹框(弹不弹是 OS 的事)。
//
// 于是壳里那条边界很好守:执行器的代码里**没有一个 if 是关于"该不该做"的**,只有"做完了没有"。

/** 执行指令帧的动作词表。目前只有一条 —— 白名单是有意的:壳只认得它认得的那几件事。 */
export const UrlRouterExecuteOpSchema = z.enum(["set-default-handler"]);
export type UrlRouterExecuteOp = z.infer<typeof UrlRouterExecuteOpSchema>;

/**
 * 内核 → 壳的**执行指令帧**(spec §6.3)。只推给注册了 `url-router-executor` 的连接。
 *
 * `id` 是 spec 那张表之外唯一多出来的字段,而它是必须的:同一条连接上可能有不止一次编排在途
 * (takeover 与 restore 撞在一起、两个 agent 同时发),没有 id 就没法说清"这条回执是哪条指令的"——
 * 与 `ConfirmationRequest.id` 同一个理由、同一种用法(回执带着它原样送回来)。
 */
export const UrlRouterExecuteCommandSchema = z.object({
  /** 这一次执行的 id;回执必须原样带回来(首个回话收场胜出)。 */
  id: z.string().min(1),
  op: UrlRouterExecuteOpSchema,
  /** 要设的那些 scheme(spec §5:http 与 https 各弹一次框是 OS 行为,如实等两次)。 */
  schemes: z.array(UrlRouterSchemeSchema).min(1),
  /** 要成为这些 scheme 默认 handler 的 bundle id。 */
  bundleID: z.string().min(1),
  /** 内核这一侧的等待窗(秒)。**壳不自己设第二个钟** —— 一件事只该有一个人计时。 */
  timeoutSeconds: z.number().int().positive(),
});
export type UrlRouterExecuteCommand = z.infer<typeof UrlRouterExecuteCommandSchema>;

/**
 * 壳自报的收场词。
 *
 * **本版的壳只会产出 `confirmed` 与 `error`**,这是如实记下的边界而不是遗漏:
 * 分辨"用户点了取消"要靠 completion 那个 NSError 的 domain/code,而那两个值要到 06 票的
 * 真机弹框旅程才拿得到(spec §11 遗留项)—— 在那之前**没有人编造它**。
 * `denied` / `timeout` 两个取值先立在契约里、内核侧的映射也已就位并有断言,
 * 06 回填之后壳只需在一处加一个判断,协议一个字都不用改。
 */
export const UrlRouterExecutionOutcomeSchema = z.enum([
  "confirmed",
  "denied",
  "timeout",
  "error",
]);
export type UrlRouterExecutionOutcome = z.infer<typeof UrlRouterExecutionOutcomeSchema>;

/** `url-router.executor.report` 的 params:壳 → 内核的回执。 */
export const UrlRouterExecutorReportParamsSchema = z.object({
  /** 对应指令帧的 `id`。 */
  execution: z.string().min(1),
  outcome: UrlRouterExecutionOutcomeSchema,
  perScheme: UrlRouterPerSchemeSchema,
  /** 一句话说明(如「目标 app 不存在」)。**不替代 perScheme 里的原样 NSError**。 */
  error: z.string().min(1).optional(),
});
export type UrlRouterExecutorReportParams = z.infer<typeof UrlRouterExecutorReportParamsSchema>;

/**
 * `url-router.executor.report` 的 result。`accepted` 恒 true ——
 * 回执没被采纳的情形一律走失败包封(`url_router_execution_unknown` / `role_not_registered`),
 * 与 `ConfirmationResolveResult.settled` 同一条口径。
 */
export const UrlRouterExecutorReportResultSchema = z.object({
  execution: z.string().min(1),
  accepted: z.literal(true),
});
export type UrlRouterExecutorReportResult = z.infer<typeof UrlRouterExecutorReportResultSchema>;

/**
 * 快照里的 `urlRouter` 节(url-router 施工 03 票,spec §6.2 的**最小集**)。
 *
 * 只有一个字段,而且**有意只有这一个**:壳拿它是为了在内核不可达的那一刻,把用户点的链接
 * 原样交给"最后已知的兜底浏览器"(03 研究票四条硬边界的第④条 ——「配置知识只来自内核推送快照,
 * 永不读内核文件」)。分流域名表、Roxy 那一族参数壳一个都用不上:壳不做决策,多给一个字段
 * 就是多给一次"壳自己判一下"的机会。
 *
 * **`roxyAPIKey` 在这里连字段都不存在**(spec §8:不进快照推送)—— 与 `UrlRouterConfigView`
 * 同一条纪律的更强形式:那边是"只剩一个布尔",这边是"整族参数都不来"。
 */
export const UrlRouterSnapshotSchema = z.object({
  /** 未命中分流时把 URL 交给谁;壳在内核不可达时也用它(生效配置里那份,已合并缺省)。 */
  fallbackBrowserBundleID: z.string().min(1),
});
export type UrlRouterSnapshot = z.infer<typeof UrlRouterSnapshotSchema>;

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
 * 长连接上可注册的角色。取值即契约,前两个**逐字取自 spec 与 ADR 0005/0008**:
 *   * `confirm-agent` —— 确认器:替人类出面呈现 dangerous 确认并安全回传决定;
 *   * `subscriber` —— 订阅者:只收状态投影,不参与仲裁;
 *   * `url-router-executor` —— **机械执行器**(url-router 施工 04 票):收内核下发的执行指令帧、
 *     调系统 API、把 completion 原样回传。**零判断**(ADR 0008 第 5 条修订的第②条受限例外)。
 *
 * 为什么它是**第三个角色**而不是复用 confirm-agent:两者的权限完全不同 ——
 * 确认器能替人做决定(`confirmations.resolve`),执行器只能回报自己执行的结果
 * (`url-router.executor.report`),它**没有任何批准 dangerous 调用的能力**。
 * 角色分开,这条边界才在协议层成立,而不是靠壳自觉。
 *
 * 一条连接可以多个角色都注册(菜单栏壳就是这样:既确认、又投影、还执行);重复注册同一角色是幂等的。
 */
export const ClientRoleSchema = z.enum(["confirm-agent", "subscriber", "url-router-executor"]);
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
   * 机械执行器进/离场(url-router 施工 04 票)。与确认器那两条同等重要:
   * 「执行器什么时候在」正是 takeover/restore 能不能走通的那条运行时事实,
   * 而它离场会让在途的执行指令**立即**按不可用收尾(在场 = 长连接)。
   */
  "executor_joined",
  "executor_left",
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
  /**
   * **装了一个插件**(11 票)。装载本身**零闸**(ADR 0011:同 UID 威胁模型下装载审批不新增任何防御,
   * 只给「agent 现场写插件」加摩擦),所以留痕就是这条路上唯一的可审计物 —— 它必须发得出去、写得进日志。
   * 同名再装(替换)也记这一条,`detail` 里写明替换了什么。
   */
  "plugin_added",
  /** 卸了一个插件:它的能力当场从注册表消失。 */
  "plugin_removed",
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

// MARK: - 插件宿主(11 票)
//
// 这一节定的是**两条完全不同的接口**,放在一起是为了让它们的分界一眼可见(ADR 0011 第一条):
//
//   ① **内核 → 插件**(`Plugin*` 那几个):exec 一次一调。内核经自带运行时(`BUN_BE_BUN`)把插件
//      拉起为子进程,`describe` 出清单、`call` 走 stdin/stdout JSON、**退出码即成败**。
//      这几份 schema 是**写给插件作者(多半是 agent)看的契约**:导出成 JSON Schema 之后,
//      agent 不必读本仓库的代码就能现场写一个插件。
//   ② **agent → 内核**(`PluginRecord` / `PluginListResult` / `PluginChangeResult`):
//      `a2 plugin add|list|remove` 的机读面,与别的子命令同一种包封。
//
// 一条不在 schema 里、但同样是契约的事实:**插件是进程外子进程,能力只经协议白名单**
// (ADR 0011 红线,旧「插件不得 import Host*」的等价物)。它的活体断言在 `test/cli-plugin.test.ts`:
// 插件回报的 pid ≠ 内核 pid、插件环境里一个 `A2_*` 都没有(内核不把自己的坐标递出去)。

/** 插件协议版本。插件在 `describe` 里自报,与内核对不上就拒装(不猜、不兼容旧形状)。 */
export const PLUGIN_PROTOCOL_VERSION = 1;

/**
 * 插件自报的一个工具。
 *
 * `parameters` 用的就是内置能力那套 `ParameterSpec`(**纯数据**,04 票为此有意不把 zod 塞进 manifest)——
 * 于是插件工具与内置能力在 `a2 capabilities list` 里长得一模一样,agent 不必分辨"这条是不是插件"。
 *
 * `dangerous` 是**声明**,不是判断:内核不猜一个工具危不危险,只照它说的办
 * (声明为真 → 调用时自动走三层仲裁)。声明为假的一律按 `normal` 登记而**不是** `safe` ——
 * 内核无从知道插件的工具是不是只读,把写当读会让状态变化不广播;反过来只是多发一条事件。
 */
export const PluginToolSpecSchema = z.object({
  name: z.string().min(1),
  summary: z.string().min(1),
  dangerous: z.boolean(),
  parameters: z.array(ParameterSpecSchema),
});
export type PluginToolSpec = z.infer<typeof PluginToolSpecSchema>;

/** 插件被 `describe` 调用时写到 stdout 的那一行 JSON。 */
export const PluginDescribeResultSchema = z.object({
  protocol: z.literal(PLUGIN_PROTOCOL_VERSION),
  /** 插件自报的名字(仅供人读与排错;**登记用的名字由 `a2 plugin add` 定**,免得两处打架)。 */
  name: z.string().min(1).optional(),
  /** 至少一个工具:一个工具都不提供的插件装了也没用,不如当场拒掉并给指引。 */
  tools: z.array(PluginToolSpecSchema).min(1),
});
export type PluginDescribeResult = z.infer<typeof PluginDescribeResultSchema>;

/** 内核写到插件 stdin 的那一行 JSON(`call` 时)。 */
export const PluginCallRequestSchema = z.object({
  tool: z.string().min(1),
  /** 已按 manifest 校验过的入参(参数按名取值)。缺省等价于空对象。 */
  input: z.record(z.string(), JsonValueSchema),
});
export type PluginCallRequest = z.infer<typeof PluginCallRequestSchema>;

/**
 * 插件 `call` 时写到 stdout 的那一行 JSON。**退出码与它必须一致**(退出码是判据,这一行是内容):
 * exit=0 配 `ok:true`,exit=3 配 `ok:false`。不一致时内核以退出码为准并把这条不一致写进 detail。
 */
export const PluginCallOutputSchema = z.union([
  z.object({ ok: z.literal(true), output: JsonValueSchema }),
  z.object({
    ok: z.literal(false),
    error: z.object({ message: z.string().min(1), detail: z.string().optional() }),
  }),
]);
export type PluginCallOutput = z.infer<typeof PluginCallOutputSchema>;

/**
 * 一条已登记的插件。**登记的是 add 那一刻的 describe 快照**:内核把工件复制进
 * `<A2_HOME>/plugins/`,此后只认那一份 —— 改了源文件不会偷偷生效,重新 `a2 plugin add` 才生效。
 * 好处是"内核此刻提供哪些能力"永远等于"最后一次 add 时看到的",不会因为有人编辑了源文件而漂。
 */
export const PluginRecordSchema = z.object({
  name: z.string().min(1),
  /** 登记区里那份工件的绝对路径(内核只拉起它)。 */
  artifact: z.string().min(1),
  /** add 时那个源文件的绝对路径(只作记账:改它不影响已登记的工件)。 */
  source: z.string().min(1),
  addedAt: z.string().min(1),
  tools: z.array(PluginToolSpecSchema),
  /** 派生出的能力 id(`plugin.<插件名>.<工具名>`)。机读面直接给,省得客户端自己拼命名规则。 */
  capabilities: z.array(z.string().min(1)),
});
export type PluginRecord = z.infer<typeof PluginRecordSchema>;

/** `plugin.list` 的 result。`directory` 是登记区(agent 免猜)。 */
export const PluginListResultSchema = z.object({
  directory: z.string().min(1),
  plugins: z.array(PluginRecordSchema),
});
export type PluginListResult = z.infer<typeof PluginListResultSchema>;

/** 装载面的三种变化。`replaced` = 同名再装(id 不变、工件换掉),与订阅的 upsert 同一种语义。 */
export const PluginActionSchema = z.enum(["added", "replaced", "removed"]);
export type PluginAction = z.infer<typeof PluginActionSchema>;

/** `plugin.add` / `plugin.remove` 的 result:变化后的那条记录 + 本次真的进出了哪些能力。 */
export const PluginChangeResultSchema = z.object({
  action: PluginActionSchema,
  plugin: PluginRecordSchema,
  /** 本次新登记的能力(remove 时为空)。 */
  added: z.array(CapabilityDescriptorSchema),
  /** 本次注销的能力 id(add 时只有"替换掉的那批"会非空)。 */
  removed: z.array(z.string().min(1)),
});
export type PluginChangeResult = z.infer<typeof PluginChangeResultSchema>;

/**
 * 「**能力全集变了**」事件(11 票新增的第七族)。与 `capability` 事件是两件事:
 * 那条说"有人改了状态",这条说"**能调的东西本身变了**"。
 *
 * 载荷里既有增量(`added` / `removed`)也有**变化后的全集**(`capabilities`)。带全集是有意的:
 * 快照里的 `capabilities` 就是这张表,客户端收到本事件后**整份替换**即可,不必自己做加减法 ——
 * 与 `arbitration` 事件"整份推"同一种处置(它们都只有几十个标量,增量记账不值那个复杂度)。
 */
export const CapabilitySetEventSchema = z.object({
  action: PluginActionSchema,
  /** 引起这次变化的插件名。 */
  plugin: z.string().min(1),
  added: z.array(CapabilityDescriptorSchema),
  removed: z.array(z.string().min(1)),
  /** 变化后的能力全集(与 `KernelSnapshot.capabilities` 同一形状、同一顺序)。 */
  capabilities: z.array(CapabilityDescriptorSchema),
});
export type CapabilitySetEvent = z.infer<typeof CapabilitySetEventSchema>;

/** `plugin.add` 的 params。`path` 必须是**绝对路径**(CLI 侧按自己的 cwd 展开后再发)。 */
export const PluginAddParamsSchema = z.object({
  path: z.string().min(1),
  /** 覆写登记名(缺省取文件名去扩展名)。取值受限:`[a-z0-9][a-z0-9_-]*`。 */
  name: z.string().min(1).optional(),
});

/** `plugin.remove` 的 params。 */
export const PluginRemoveParamsSchema = z.object({
  plugin: z.string().min(1),
});

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
 * 为什么快照就是这几样:客户端要投影的东西全在内核的**进程内状态**里,取它们不发一次网络请求、
 * 不读一次外部进程 —— 快照必须是廉价且瞬时一致的,否则"注册即快照"会变成一次慢启动。
 * (代理的实时模式/节点不在此列:那要问 external-controller。壳按需调 `proxy.status` 能力,
 * 此后靠 `capability` 事件跟进变化 —— 仍然零轮询。)
 *
 * **`urlRouter` 是第六节,也是唯一一节不来自进程内状态的**(03 票):它的事实源是磁盘上那份
 * `<A2_HOME>/url-router.json`,每次建全量快照时**现读**(不设文件监视 —— 与"注册即快照"同一条
 * 机制,读的时刻就是发的时刻)。这没有破上面那条"廉价"的规矩:一次本地小文件读,既不出网也不起进程;
 * 而它换来的是壳在内核不可达时**仍知道兜底浏览器是谁**(03 四条硬边界的第④条)。
 * 读的时机在**注册之前**(见 `daemon/router.ts` 的 `roles.register`),于是"快照是这条连接的第一帧"
 * 那条保证不受影响。
 */
export const KernelSnapshotSchema = z.object({
  status: StatusResultSchema,
  /**
   * 能力全集。**11 票起这张表在运行期会变**(装/卸插件),变化随 `capability-set` 事件整份推一次 ——
   * 客户端拿到就替换,不必自己做加减法。
   */
  capabilities: z.array(CapabilityDescriptorSchema),
  arbitration: ArbitrationStateSchema,
  /** 存活监督的当下观测 + 最近事件(07 票的形状原样复用)。 */
  supervision: ProxySupervisionResultSchema,
  /** 最近若干条审计事件(全量在 `arbitration.log` 里)。 */
  audit: z.array(AuditEventSchema),
  /** URL 分流:壳降级兜底要用的那**一个**事实(03 票,见 `UrlRouterSnapshotSchema` 头注)。 */
  urlRouter: UrlRouterSnapshotSchema,
});
export type KernelSnapshot = z.infer<typeof KernelSnapshotSchema>;

/**
 * 增量推送的事件族(按 `kind` 判别)。**推送对象各不相同**,这是协议的一部分:
 *   * `confirmation` —— **只推给 confirm-agent**(带 input);
 *   * `confirmation-pending` —— **只推给发起那次调用的那条连接**(告诉它"我转给人了,最多等这么久");
 *   * `url-router-execute` —— **只推给 url-router-executor**(带"去改系统状态"的指令);
 *   * 其余 —— 推给全体已注册连接(确认器 + 订阅者 + 执行器)。
 *
 * 11 票加了第七族 `capability-set`(能力全集变了)。它与 `capability` 一字之差却是两件事:
 * 后者说"有人改了状态",前者说"**能调的东西本身变了**"。
 * url-router 施工 04 票加了第八族 `url-router-execute`(执行指令帧)。
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
  z.object({
    kind: z.literal("capability-set"),
    at: z.string().min(1),
    capabilities: CapabilitySetEventSchema,
  }),
  z.object({
    /**
     * **执行指令帧**(url-router 施工 04 票,spec §6.3)——**只推给 `url-router-executor`**。
     *
     * 它与 `confirmation` 是仅有的两条**按角色**定向的推送,理由也同源:
     * 那一条带着人类要核对的入参,这一条带着"去改系统状态"的指令 —— 都不该发给不相干的订阅者。
     * (`confirmation-pending` 也是定向的,但那是**按连接**定向 —— 只发给发起那次调用的人,又是另一回事。)
     */
    kind: z.literal("url-router-execute"),
    at: z.string().min(1),
    command: UrlRouterExecuteCommandSchema,
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
