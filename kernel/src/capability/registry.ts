// 能力注册表 —— **唯一调用面**(ADR 0004 在新架构下的等价物)。
//
// 这里是内核里唯一一处"能力被执行"的地方,所以也是唯一一处仲裁点:
// 参数校验、风险分档、dangerous 默拒全在 `invoke()` 里,任何入口(CLI、裸 UDS 直连、将来的壳与插件)
// 都必须从这道门过。绕过 CLI 不等于绕过仲裁 —— 这条有专门的裸 UDS 断言把守。
//
// 铁律:**invoke 永不抛**。业务失败、校验失败、被拒,全部变成一个带 code 的 `OpOutcome`。

import {
  ErrorCode,
  opFailure,
  opSuccess,
  type CapabilityDescriptor,
  type Guidance,
  type JsonValue,
  type OpOutcome,
  type ParameterSpec,
  type WireError,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";

/** 能力的入参:按名取值的 JSON 对象(缺省等价于空对象)。 */
export type CapabilityInput = Record<string, JsonValue>;

/** 能力实现。返回值即 `output`;业务失败请抛 `CapabilityFailedError`(别抛别的)。 */
export type CapabilityHandler = (input: CapabilityInput) => JsonValue | Promise<JsonValue>;

/** 能力 = manifest + 实现。 */
export interface Capability {
  descriptor: CapabilityDescriptor;
  handler: CapabilityHandler;
}

/**
 * 「能力执行了,但业务上失败了」—— 与"没执行成"(校验失败/被拒)分开,退出码 5 而非 6。
 * agent 据此判断"参数没错、路走通了,是这件事本身没成",不必重试同一条命令。
 *
 * **07 票加的两样**(可选,不带即与 04 票行为逐字相同):
 *   * `code` —— 换一个已登记的 `ErrorCode`(如 `mihomo_unreachable`),让 agent 能按细因分支;
 *     退出码仍由 `exitCodeForErrorCode` 统一裁,能力自己决定不了自己的退出码。
 *   * `guidance` —— 「拒绝即指引」不该只属于仲裁层:代理域的失败大多有一条人类可执行的下一步
 *     (「把你自己的 mihomo 拉起来」「先 a2 mihomo install」),不带上就等于让 agent 猜。
 */
export class CapabilityFailedError extends Error {
  readonly code: ErrorCode;
  readonly detail?: string;
  readonly guidance?: Guidance;

  constructor(
    message: string,
    detail?: string,
    options: { code?: ErrorCode; guidance?: Guidance } = {},
  ) {
    super(message);
    this.name = "CapabilityFailedError";
    this.code = options.code ?? ErrorCode.capabilityFailed;
    if (detail !== undefined) this.detail = detail;
    if (options.guidance !== undefined) this.guidance = options.guidance;
  }
}

/**
 * 仲裁上下文 —— 注册表与「谁能替人做决定」之间**唯一的缝**(08 票把 04 票留的那个布尔缝长成了它)。
 *
 * 三个成员对应 ADR 0005 修订后第 4 条的三层,顺序即安全语义:
 *   * `confirmerPresent()` —— **运行时事实**:注册了 confirm-agent 角色的长连接数 > 0。
 *     「在场 = 长连接」,所以它每次现问,绝不缓存。
 *   * `refuseWithoutConfirmer()` —— 第①层 fail-closed 默拒的报文(顺带留痕)。
 *   * `confirm()` —— 第③层带外确认。放行返回 `undefined`;三种拒绝各返回一条 `WireError`。
 *
 * 注册表**只认这三件事**:它不知道确认器是菜单栏壳还是别的什么,也不知道确认是怎么送到人眼前的。
 */
export interface ArbitrationContext {
  confirmerPresent(): boolean;
  refuseWithoutConfirmer(descriptor: CapabilityDescriptor): WireError;
  confirm(
    descriptor: CapabilityDescriptor,
    input: CapabilityInput,
  ): Promise<WireError | undefined>;
}

export class DuplicateCapabilityError extends Error {
  constructor(readonly id: string) {
    super(`能力 id 重复登记:${id}`);
    this.name = "DuplicateCapabilityError";
  }
}

export class CapabilityRegistry {
  readonly #ordered: Capability[];
  readonly #byId: Map<string, Capability>;

  /** 重复 id 直接抛(启动即失败)—— 静默后者覆盖前者是旧实现的债,不继承。 */
  constructor(capabilities: Capability[]) {
    this.#ordered = [...capabilities];
    this.#byId = new Map();
    for (const capability of this.#ordered) {
      const id = capability.descriptor.id;
      if (this.#byId.has(id)) throw new DuplicateCapabilityError(id);
      this.#byId.set(id, capability);
    }
  }

  /** 全量 manifest,顺序 = 登记顺序。 */
  list(): CapabilityDescriptor[] {
    return this.#ordered.map((capability) => capability.descriptor);
  }

  /**
   * **运行期**登记(11 票:`a2 plugin add` 让能力全集在运行期变化)。
   *
   * 与构造器那条「重复 id 直接抛」的分别是有意的,不是两套标准:
   *   * 构造器登记的是**内核自己的**能力,重复只可能是内核代码写错了 —— 启动即失败最省事;
   *   * 这里登记的是**外来的**能力(agent 现场写的插件),重复是一种**可预期的输入**,
   *     必须变成一条带指引的结构化错误交回去,而不是掀翻正在跑的 daemon。
   *
   * **全或无**:一个插件的多个工具里只要有一个 id 撞了,整批都不登记(半装的插件比没装更难排错)。
   */
  register(capabilities: Capability[]): WireError | undefined {
    for (const capability of capabilities) {
      const id = capability.descriptor.id;
      if (this.#byId.has(id)) {
        return {
          code: ErrorCode.invalidParams,
          message: `能力 id 已被占用:${id}`,
          detail: "同名工具已经登记过了。插件的能力 id 形如 `plugin.<插件名>.<工具名>`,换个插件名即可避开。",
          guidance: {
            summary: "换一个插件名再装,或先卸掉占着这个 id 的那个插件。",
            steps: [
              { description: "看看现在都装了什么", command: "a2 plugin list --json" },
              { description: "换个名字装", command: "a2 plugin add <路径> --name <别的名字>" },
            ],
            context: { capability: id },
          },
        };
      }
    }
    for (const capability of capabilities) {
      this.#ordered.push(capability);
      this.#byId.set(capability.descriptor.id, capability);
    }
    return undefined;
  }

  /** 运行期注销(`a2 plugin remove`)。返回真的被摘掉的那批 manifest;不认识的 id 静默略过。 */
  unregister(ids: string[]): CapabilityDescriptor[] {
    const removed: CapabilityDescriptor[] = [];
    for (const id of ids) {
      const capability = this.#byId.get(id);
      if (!capability) continue;
      this.#byId.delete(id);
      const index = this.#ordered.indexOf(capability);
      if (index >= 0) this.#ordered.splice(index, 1);
      removed.push(capability.descriptor);
    }
    return removed;
  }

  describe(id: string): CapabilityDescriptor | undefined {
    return this.#byId.get(id)?.descriptor;
  }

  /** 未知能力 → 带指引的失败(拒绝即指引:先告诉他去哪儿看全集)。 */
  unknownCapabilityError(id: string): WireError {
    return {
      code: ErrorCode.unknownCapability,
      message: `未知能力:${id}`,
      detail: `本版内核已登记的能力:${this.list().map((d) => d.id).join("、")}`,
      guidance: {
        summary: "先列出本内核实际提供的能力,再按 id 调用。",
        steps: [
          { description: "列出全部能力(含风险档与参数)", command: "a2 capabilities list --json" },
        ],
      },
    };
  }

  /**
   * 调用一个能力。四步,顺序即安全语义:
   *   ①认得这个 id 吗 → ②参数合不合声明 → ③这一档准不准调(dangerous 仲裁)→ ④执行。
   * ③ 在 ④ 之前:被拒时 handler **一次都不会被碰到**(有"响应里绝不含 handler 产物"的反证断言)。
   *
   * 第③步内部又是三层(ADR 0005 修订后第 4 条),这里是它在代码里的全貌:
   * 没有确认器就默拒;有确认器就把这次调用交出去等一个带外的决定;拒绝与超时各有各的报文。
   */
  async invoke(
    id: string,
    input: CapabilityInput,
    context: ArbitrationContext,
  ): Promise<OpOutcome> {
    const capability = this.#byId.get(id);
    if (!capability) return opFailure(this.unknownCapabilityError(id));

    const invalid = validateInput(capability.descriptor, input);
    if (invalid) return opFailure(invalid);

    if (capability.descriptor.risk === "dangerous") {
      // 第①层:一个确认器都没有 → fail-closed。**先问再等**,顺序不能反 ——
      // 反了就成了"先把请求挂起、再发现没人能确认",那正是 spec 拒绝的"超时猜谜"。
      if (!context.confirmerPresent()) {
        return opFailure(context.refuseWithoutConfirmer(capability.descriptor));
      }
      // 第③层:带外确认。放行才往下走;拒绝/超时/在途降级各自带一条报文回去。
      const refusal = await context.confirm(capability.descriptor, input);
      if (refusal) return opFailure(refusal);
    }

    try {
      return opSuccess(await capability.handler(input));
    } catch (error) {
      if (error instanceof CapabilityFailedError) {
        return opFailure({
          code: error.code,
          message: error.message,
          ...(error.detail === undefined ? {} : { detail: error.detail }),
          ...(error.guidance === undefined ? {} : { guidance: error.guidance }),
        });
      }
      return opFailure({
        code: ErrorCode.internalError,
        message: `能力 ${id} 执行时抛出了未预期的错误。`,
        detail: String(error),
      });
    }
  }
}

// MARK: - 仲裁三层各自的拒绝报文
//
// 三条放在一起,是为了让「三层仲裁」在代码里也能一眼读全:没人能确认 / 有人不同意 / 有人但没人应答。
// 三条**都必带 guidance**(第②层「拒绝即指引」是无条件的),契约上由 `ConfirmationErrorSchema` 强制。

/**
 * dangerous + 无确认器 = **默拒**(ADR 0005 第 4 条第①层),报文自带「人类如何完成」(第②层)。
 *
 * 这条报文的形状对 08 票是**稳定契约,已兑现:一字未改**。08 票新增的是 `confirmation_denied` /
 * `confirmation_timeout`,并把**在途降级**(挂起中确认器全断)也归到本条 —— 对发起方而言,
 * 「一个确认器都没有」与「刚才有、现在没了」是同一件事:此刻没人能替你确认。
 * 指引里的 `open -a "A2 Panel"` 指向 10 票才交付的壳 —— 与 `a2 service install`(05 票)同一种处置:
 * 指引说的是**这条路怎么走通**,不是"现在就能走通"。
 */
export function confirmationUnavailableError(
  descriptor: CapabilityDescriptor,
  paths: KernelPaths,
): WireError {
  return {
    code: ErrorCode.confirmationUnavailable,
    message: `${descriptor.id} 是 dangerous 能力,当前没有确认器在场,已按 fail-closed 拒绝执行。`,
    detail:
      "内核永不接受经 AI agent 之手的确认(`--yes` 类旁路永禁,TTY 也不构成人类证明)," +
      "确认必须由带外的确认器完成。",
    guidance: {
      summary: "dangerous 能力需要确认器在场,当前没有任何确认器连接。",
      steps: [
        {
          description: "在 Mac 上启动菜单栏壳并保持它运行,它会注册为确认器",
          command: 'open -a "A2 Panel"',
        },
        { description: "回到菜单栏图标,在弹出的确认框里亲自点「允许」" },
      ],
      context: {
        capability: descriptor.id,
        risk: descriptor.risk,
        home: paths.home,
        socketPath: paths.socketPath,
      },
    },
  };
}

/**
 * dangerous + 确认器**明确点了拒绝** = 第③层的一种收场。
 *
 * 与默拒的分别值得写下来:默拒说的是"这条路此刻走不通",而这一条说的是**"人看过了,他不同意"** ——
 * agent 收到它就该停手并把理由转告,而不是去想办法把确认器弄起来(那是默拒的指引)。
 */
export function confirmationDeniedError(
  descriptor: CapabilityDescriptor,
  paths: KernelPaths,
  reason?: string,
): WireError {
  return {
    code: ErrorCode.confirmationDenied,
    message: `${descriptor.id} 的确认被拒绝,未执行。`,
    detail:
      (reason ? `拒绝理由:${reason}。` : "确认器未给出理由。") +
      "决定由带外的确认器做出,内核不复议、也不提供任何旁路。",
    guidance: {
      summary: "这次 dangerous 调用被人类拒绝了 —— 请把这条原样转告用户,由用户决定要不要再来一次。",
      steps: [
        { description: "确认这确实是用户想做的事(核对下面 context 里的能力与参数)" },
        {
          description: "如果确实要做,请由用户重新发起,并在确认器上亲自点「允许」",
          command: `a2 capabilities describe ${descriptor.id} --json`,
        },
      ],
      context: {
        capability: descriptor.id,
        risk: descriptor.risk,
        home: paths.home,
        socketPath: paths.socketPath,
        ...(reason === undefined ? {} : { reason }),
      },
    },
  };
}

/**
 * dangerous + 确认器在场、请求也送到了,但**没人在窗口内做决定** = 第③层的另一种收场。
 *
 * 超时即拒绝(fail-closed):内核绝不因为"没人反对"就放行 —— 沉默不是同意。
 */
export function confirmationTimeoutError(
  descriptor: CapabilityDescriptor,
  paths: KernelPaths,
  timeoutMs: number,
): WireError {
  return {
    code: ErrorCode.confirmationTimeout,
    message: `${descriptor.id} 等待确认超时(${timeoutMs}ms),按 fail-closed 拒绝执行。`,
    detail: "确认请求已送达确认器,但在超时窗口内没有人做决定。沉默不构成同意。",
    guidance: {
      summary: "确认器在场但没人应答 —— 请用户到确认器上处理,然后重新发起这次调用。",
      steps: [
        { description: "回到菜单栏图标,看有没有一个待处理的确认框(可能被别的窗口挡住了)" },
        {
          description: "处理完之后重新发起这次调用",
          command: `a2 capabilities describe ${descriptor.id} --json`,
        },
      ],
      context: {
        capability: descriptor.id,
        risk: descriptor.risk,
        timeoutMs: String(timeoutMs),
        home: paths.home,
        socketPath: paths.socketPath,
      },
    },
  };
}

/**
 * 按 manifest 校验入参。只拒三类:缺必填、类型不符、取值不在 allowedValues 内。
 * **多余字段一律放行**(有意):老客户端多带一个字段不该被毙,能力自己看不懂就当没有。
 *
 * **`null` 与缺省同义**(有意,成文于此):`{"target": null}` 与不写 `target` 走同一条路 ——
 * 可选参数按缺省处理、必填参数报 `missing_parameter`。理由:JSON 世界里"我没有这个值"常常就写成 `null`
 * (很多语言的序列化器会把 `undefined`/`nil` 字段照写成 `null`),把它判成 `type_mismatch`
 * 等于逼客户端在拼请求前先删字段。代价是 manifest 无法表达"这个参数可以显式取 null"——
 * 三档参数类型词汇表(string/number/boolean/object/array)本来也没有 null,不构成损失。
 */
function validateInput(
  descriptor: CapabilityDescriptor,
  input: CapabilityInput,
): WireError | undefined {
  for (const spec of descriptor.parameters) {
    const value = input[spec.name];
    if (value === undefined || value === null) {
      if (!spec.required) continue;
      return parameterError(
        ErrorCode.missingParameter,
        `缺少必填参数:${spec.name}`,
        descriptor,
        spec,
      );
    }

    if (!typeMatches(spec.type, value)) {
      return parameterError(
        ErrorCode.typeMismatch,
        `参数 ${spec.name} 的类型应为 ${spec.type},实际是 ${typeNameOf(value)}`,
        descriptor,
        spec,
      );
    }

    if (spec.allowedValues && typeof value === "string" && !spec.allowedValues.includes(value)) {
      return parameterError(
        ErrorCode.invalidParams,
        `参数 ${spec.name} 的取值必须是:${spec.allowedValues.join("、")}(收到 ${JSON.stringify(value)})`,
        descriptor,
        spec,
      );
    }
  }
  return undefined;
}

/** 参数类问题一律附「去看这条能力的 manifest」—— agent 自纠所需的下一步,不用翻文档。 */
function parameterError(
  code: ErrorCode,
  message: string,
  descriptor: CapabilityDescriptor,
  spec: ParameterSpec,
): WireError {
  return {
    code,
    message,
    detail: `参数声明:${spec.name}: ${spec.type}${spec.required ? "(必填)" : "(可选)"} —— ${spec.description}`,
    guidance: {
      summary: "按能力 manifest 修正参数后重试。",
      steps: [
        {
          description: "查看该能力的完整参数声明",
          command: `a2 capabilities describe ${descriptor.id} --json`,
        },
      ],
      context: { capability: descriptor.id, parameter: spec.name },
    },
  };
}

function typeMatches(type: ParameterSpec["type"], value: JsonValue): boolean {
  switch (type) {
    case "string":
      return typeof value === "string";
    case "number":
      // NaN/Infinity 进不了 JSON,但别的客户端可能塞进来 —— 非有限数当类型不符,别让能力去接盘。
      return typeof value === "number" && Number.isFinite(value);
    case "boolean":
      return typeof value === "boolean";
    case "array":
      return Array.isArray(value);
    case "object":
      return typeof value === "object" && value !== null && !Array.isArray(value);
  }
}

function typeNameOf(value: JsonValue): string {
  if (Array.isArray(value)) return "array";
  if (value === null) return "null";
  return typeof value;
}
