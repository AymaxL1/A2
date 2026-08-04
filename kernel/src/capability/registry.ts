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
 */
export class CapabilityFailedError extends Error {
  constructor(
    message: string,
    readonly detail?: string,
  ) {
    super(message);
    this.name = "CapabilityFailedError";
  }
}

/**
 * 仲裁上下文。`confirmerPresent` 是**运行时事实**(08 票:确认器长连接在场即 true,断线即 false),
 * 04 票恒 false —— 内核此时还没有任何确认通道,dangerous 一律走第①层默拒。
 */
export interface ArbitrationContext {
  confirmerPresent: boolean;
  /** 只用于把展开后的路径写进 guidance.context(agent 免猜)。 */
  paths: KernelPaths;
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

    if (capability.descriptor.risk === "dangerous" && !context.confirmerPresent) {
      return opFailure(confirmationUnavailableError(capability.descriptor, context.paths));
    }

    try {
      return opSuccess(await capability.handler(input));
    } catch (error) {
      if (error instanceof CapabilityFailedError) {
        return opFailure({
          code: ErrorCode.capabilityFailed,
          message: error.message,
          ...(error.detail === undefined ? {} : { detail: error.detail }),
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

/**
 * dangerous + 无确认器 = **默拒**(ADR 0005 第 4 条第①层),报文自带「人类如何完成」(第②层)。
 *
 * 这条报文的形状对 08 票是**稳定契约**:届时确认器在场会走带外确认,不在场时仍然原样返回这一条。
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
