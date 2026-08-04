// 域子命令面:`a2 proxy on` / `a2 proxy mode --mode global` / `a2 proxy ping --group PROXY`。
//
// 它**不是第二条通路**,只是同一条能力调用的另一种 argv 写法:
//   `a2 proxy on` ⇢ 解析 cliAlias ⇢ `capabilities.call proxy.system.enable` ⇢ 同一个 `registry.invoke`。
// 所以仲裁、校验、dangerous 默拒全都原样发生(有一条"两种写法 result 完全相同"的断言把这件事钉住)。
//
// 解析规则(沿旧 `aa` 的口径):
//   * **最长别名优先** —— `proxy subscription add` 与 `proxy subscription` 都登记时,前者胜出;
//   * 剩下的 token 必须是 `--参数名 值`,值按 manifest 声明的类型强转;
//   * 转不动(`--timeout inf`)或不认识的旗标 → **用法错(退出码 1)**,不是校验错(6)——
//     那一档说的是"这条命令行不成立",还没轮到内核看参数。
//
// 为什么每条命令要先 `capabilities.list` 走一趟 daemon:manifest 是内核说了算的
// (11 票起插件也会往里加能力),客户端**不许**自己存一份别名表 —— 存了就一定漂。

import { callKernel } from "../client/kernel-client.ts";
import {
  CapabilityCallResultSchema,
  CapabilityListResultSchema,
  Op,
  type CapabilityDescriptor,
  type JsonValue,
  type ParameterSpec,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { outcomeFromEnvelope, type CommandOutcome } from "./outcome.ts";
import { DOMAIN_USAGE, domainUsageOutcome, helpOutcome, USAGE } from "./usage.ts";

/**
 * 跑一条域子命令。`domain` 是第一个 token(如 `proxy`、`arbitration`),`args` 是它后面的全部 token。
 * 本函数**对域名无知**:它只认 manifest 里的 `cliAlias`,新域只需在 `main.ts` 放行 + 在
 * `DOMAIN_USAGE` 登记一段帮助,解析逻辑一行不改。
 */
export async function domainCommand(
  domain: string,
  args: string[],
  paths: KernelPaths,
): Promise<CommandOutcome> {
  if (args[0] === "help" || args[0] === "-h" || args[0] === "--help") {
    return helpOutcome(DOMAIN_USAGE[domain] ?? USAGE);
  }

  const listed = await callKernel(paths, Op.capabilitiesList);
  if (!listed.ok) {
    // daemon 不可达之类:原样透传(退出码由 error.code 定,与别的命令同口径)。
    return outcomeFromEnvelope(listed, "capabilities.list", CapabilityListResultSchema, () => "");
  }
  const parsed = CapabilityListResultSchema.safeParse(listed.result);
  if (!parsed.success) {
    return outcomeFromEnvelope(listed, "capabilities.list", CapabilityListResultSchema, () => "");
  }

  const tokens = [domain, ...args];
  const matched = matchAlias(parsed.data.capabilities, tokens);
  if (!matched) {
    return domainUsageOutcome(
      domain,
      args.length === 0
        ? `${domain} 需要一个动作。`
        : `未知的 ${domain} 动作:${args.join(" ")}`,
      aliasHints(parsed.data.capabilities, domain),
    );
  }

  const input = parseFlags(matched.descriptor, matched.rest);
  if ("error" in input) {
    return domainUsageOutcome(domain, input.error, aliasHints(parsed.data.capabilities, domain));
  }

  const params: Record<string, JsonValue> =
    Object.keys(input.values).length === 0
      ? { capability: matched.descriptor.id }
      : { capability: matched.descriptor.id, input: input.values };
  return outcomeFromEnvelope(
    await callKernel(paths, Op.capabilitiesCall, params),
    "capabilities.call",
    CapabilityCallResultSchema,
    // 与 `a2 capabilities call` **同一个渲染器**:两种写法的输出必须一模一样。
    ({ output }) => JSON.stringify(output, null, 2),
  );
}

interface AliasMatch {
  descriptor: CapabilityDescriptor;
  rest: string[];
}

/** 最长别名优先:`["proxy","subscription","add"]` 胜过 `["proxy","subscription"]`。 */
function matchAlias(
  capabilities: CapabilityDescriptor[],
  tokens: string[],
): AliasMatch | undefined {
  let best: AliasMatch | undefined;
  let bestLength = 0;
  for (const descriptor of capabilities) {
    const alias = descriptor.cliAlias;
    if (!alias || alias.length > tokens.length) continue;
    if (!alias.every((token, index) => token === tokens[index])) continue;
    if (alias.length <= bestLength) continue;
    best = { descriptor, rest: tokens.slice(alias.length) };
    bestLength = alias.length;
  }
  return best;
}

/** 这个域下有哪些写法(用法错时原样列给人看)。 */
function aliasHints(capabilities: CapabilityDescriptor[], domain: string): string[] {
  return capabilities
    .filter((descriptor) => descriptor.cliAlias?.[0] === domain)
    .map((descriptor) => {
      const required = descriptor.parameters
        .filter((spec) => spec.required)
        .map((spec) => ` --${spec.name} <${spec.type}>`)
        .join("");
      return `a2 ${(descriptor.cliAlias as string[]).join(" ")}${required}   # ${descriptor.id} [${descriptor.risk}]`;
    })
    .sort();
}

type ParsedFlags = { values: Record<string, JsonValue> } | { error: string };

/** `--名字 值` → 按 manifest 声明的类型强转。**不认识的旗标一律报错**,绝不静默忽略。 */
function parseFlags(descriptor: CapabilityDescriptor, rest: string[]): ParsedFlags {
  const byName = new Map(descriptor.parameters.map((spec) => [spec.name, spec]));
  const values: Record<string, JsonValue> = {};

  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index] as string;
    if (!token.startsWith("--")) {
      return {
        error: `多余的参数:${token}(域子命令的入参一律写成 --名字 值)`,
      };
    }
    const name = token.slice(2);
    const spec = byName.get(name);
    if (!spec) {
      return {
        error:
          `${descriptor.id} 没有名叫 ${name} 的参数。可用参数:` +
          (descriptor.parameters.length === 0
            ? "(无)"
            : descriptor.parameters.map((item) => `--${item.name}`).join(" ")),
      };
    }

    const next = rest[index + 1];
    // boolean 允许裸旗标(`--allowLan` 即 true);别的类型必须带值,且值不能是另一个旗标。
    if (spec.type === "boolean" && (next === undefined || next.startsWith("--"))) {
      values[name] = true;
      continue;
    }
    if (next === undefined || next.startsWith("--")) {
      return { error: `--${name} 后面缺少值(声明类型 ${spec.type})` };
    }
    const coerced = coerce(spec, next);
    if ("error" in coerced) return coerced;
    values[name] = coerced.value;
    index += 1;
  }
  return { values };
}

type Coerced = { value: JsonValue } | { error: string };

function coerce(spec: ParameterSpec, raw: string): Coerced {
  switch (spec.type) {
    case "string":
      return { value: raw };
    case "number": {
      const value = Number(raw);
      // **有限数才算数**:`inf` / `nan` / `1e400` 在这里就被挡下(它们进了内核只会变成挂死或崩)。
      if (!Number.isFinite(value)) {
        return { error: `--${spec.name} 需要一个有限数字,收到 ${JSON.stringify(raw)}` };
      }
      return { value };
    }
    case "boolean": {
      if (raw === "true") return { value: true };
      if (raw === "false") return { value: false };
      return { error: `--${spec.name} 需要 true 或 false,收到 ${JSON.stringify(raw)}` };
    }
    case "object":
    case "array": {
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch (error) {
        return { error: `--${spec.name} 需要一段合法 JSON(${spec.type}):${String(error)}` };
      }
      const isArray = Array.isArray(parsed);
      if (spec.type === "array" && !isArray) return { error: `--${spec.name} 需要一个 JSON 数组` };
      if (spec.type === "object" && (isArray || typeof parsed !== "object" || parsed === null)) {
        return { error: `--${spec.name} 需要一个 JSON 对象` };
      }
      return { value: parsed as JsonValue };
    }
  }
}
