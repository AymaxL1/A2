// URL 分流能力组(url-router 施工 02 票,spec §3 那张表)—— 五条,风险三档齐:
//
//   * `url-router.status`   safe      配置健康 + 系统 handler 现状(只读)
//   * `url-router.decide`   safe      一条 URL 的判决,**不执行**(CLI `route --dry-run` 的落点)
//   * `url-router.route`    normal    决策 + 执行(可逆写:开标签页/拉起 app,不动任何系统状态)
//   * `url-router.takeover` dangerous 把 com.a2.panel 设成 http+https 默认 handler
//   * `url-router.restore`  dangerous 设回兜底浏览器(`--to` 可显式覆写)
//
// 风险怎么定的:`route` 是 normal 而不是 safe —— 它真的会让机器上多出一个窗口;但它**不改系统状态**
// (关掉标签页就没了),所以也不是 dangerous。`takeover` / `restore` 改的是**全系统的默认浏览器**,
// 影响面越出 a2 自己,且用户下次点任何链接都会撞上 —— 这是 dangerous 的教科书形状。
//
// dangerous 的仲裁**这里一个字都不用写**:`registry.invoke` 里那三层(无确认器默拒 → 拒绝即指引 →
// 带外确认)对 risk 分档自动生效,声明对了就够了。
//
// **04 票的边界**:takeover/restore 在本票只落**契约与幂等判据** —— 先读 handler,已是目标就
// `already: true` 直通(spec §3 的幂等口径:不弹框);否则返回 `url_router_executor_unwired`。
// 真正的执行器(壳的机械执行器 + 执行指令帧)归 04 票。

import {
  ErrorCode,
  payload,
  type JsonValue,
  type UrlRouterHandler,
  type UrlRouterStatusResult,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import {
  loadUrlRouterConfig,
  redactUrlRouterConfig,
  urlRouterConfigPath,
  type UrlRouterConfig,
  type UrlRouterConfigLoad,
} from "../url-router/config.ts";
import { decisionWord } from "../url-router/decide.ts";
import {
  createUrlRouterPorts,
  decideRoute,
  routeUrl,
  sanitizeUrlForLog,
  UrlRouterOpenError,
  type UrlRouterPorts,
} from "../url-router/execute.ts";
import {
  A2_PANEL_BUNDLE_ID,
  createDefaultHandlerReader,
  readHandlerSnapshot,
  type DefaultHandlerReader,
  type HandlerSnapshot,
} from "../url-router/handler.ts";
import { CapabilityFailedError, type Capability } from "./registry.ts";

/**
 * URL 分流能力的运行上下文(由 daemon runtime 注入,handler 闭包持有)。
 *
 * 两个可选口就是**全部的外部世界**:`ports`(进程/HTTP/时钟)与 `handlers`(系统默认 handler 的只读读取)。
 * 测试注入纯假件 —— 于是"三级降级"这条最容易悄悄错掉的链能在函数缝上验全,
 * 而不必先造出一台跑着的 Roxy、也永远不会在跑测试时真弹出一个浏览器窗口。
 */
export interface UrlRouterContext {
  paths: KernelPaths;
  env: Record<string, string | undefined>;
  ports?: UrlRouterPorts;
  handlers?: DefaultHandlerReader;
}

/** 五条能力。登记顺序即 `capabilities list` 里的出场顺序(与 spec §3 的表同序)。 */
export function urlRouterCapabilities(context: UrlRouterContext): Capability[] {
  return [status(context), decide(context), route(context), takeover(context), restore(context)];
}

/** URL 参数的声明(`decide` 与 `route` 共用一份,免得两处说法不一致)。 */
const URL_PARAMETER = {
  name: "url",
  type: "string",
  required: true,
  description: "要分流的 URL(原样传入,内核不预处理;非 http(s) 会判为 unsupported 并交兜底浏览器)",
} as const;

// MARK: - status

function status(context: UrlRouterContext): Capability {
  return {
    descriptor: {
      id: "url-router.status",
      risk: "safe",
      summary:
        "报告 URL 分流的现状:配置从哪儿来、有没有毛病(脱敏后的生效配置),以及系统此刻的 http/https 默认 handler(只读)",
      parameters: [],
      cliAlias: ["url-router", "status"],
    },
    handler: async () => payload(await statusResult(context)),
  };
}

async function statusResult(context: UrlRouterContext): Promise<UrlRouterStatusResult> {
  const load = await loadUrlRouterConfig(context.paths);
  const snapshot = await readHandlerSnapshot(handlerReader(context), A2_PANEL_BUNDLE_ID);
  return {
    configPath: urlRouterConfigPath(context.paths),
    configSource: load.source,
    ...(load.problem === undefined ? {} : { problem: load.problem }),
    config: redactUrlRouterConfig(load.config),
    panelBundleID: A2_PANEL_BUNDLE_ID,
    handler: handlerView(snapshot),
  };
}

/**
 * handler 快照 → 报文。读不出来时**必须说清为什么**,而不是丢一个光秃秃的 `null`:
 * 「没有登记项」在一台从没换过默认浏览器的机器上是**常态**,不是故障,agent 该据此闭嘴而不是报警。
 */
function handlerView(snapshot: HandlerSnapshot): UrlRouterHandler {
  const missing = snapshot.http === null || snapshot.https === null;
  return {
    http: snapshot.http,
    https: snapshot.https,
    matchesTarget: snapshot.matchesTarget,
    ...(missing
      ? {
          undetermined:
            "LaunchServices 里没有读到这个 scheme 的登记项 —— 多半意味着默认 handler 仍是系统出厂的那个" +
            "(从没换过就不会有条目)。内核不猜,如实报未能判定;悬空 handler 的完整诊断归 05 票。",
        }
      : {}),
  };
}

// MARK: - decide / route

function decide(context: UrlRouterContext): Capability {
  return {
    descriptor: {
      id: "url-router.decide",
      risk: "safe",
      summary:
        "对一条 URL 只出决策不执行:fallback-browser / roxy-cdp:<port> / roxy-api / roxy-launcher / unsupported(只读;CLI 写法 url-router route <url> --dry-run)",
      parameters: [URL_PARAMETER],
      cliAlias: ["url-router", "decide"],
    },
    handler: async (input) => {
      const url = requiredUrl(input);
      const config = await effectiveConfig(context);
      const decision = await decideRoute(ports(context), config, url);
      return payload({
        url: sanitizeUrlForLog(url),
        decision: decisionWord(decision),
        ...(decision.kind === "roxy-cdp" ? { roxyDevToolsPort: decision.port } : {}),
      });
    },
  };
}

function route(context: UrlRouterContext): Capability {
  return {
    descriptor: {
      id: "url-router.route",
      risk: "normal",
      summary:
        "决策并打开:命中分流域名的进 Roxy 指定 profile(CDP → API → launcher 三级降级),其余交兜底浏览器(可逆写,不改任何系统状态)",
      parameters: [URL_PARAMETER],
      cliAlias: ["url-router", "route"],
    },
    handler: async (input) => {
      const url = requiredUrl(input);
      const config = await effectiveConfig(context);
      try {
        return payload(await routeUrl({ ports: ports(context), config, url }));
      } catch (error) {
        if (!(error instanceof UrlRouterOpenError)) throw error;
        throw new CapabilityFailedError(error.message, error.detail, {
          code: ErrorCode.urlRouterOpenFailed,
          guidance: {
            summary:
              "决策没问题,是最后一步没能把链接交出去 —— 多半是那个 app 不在(bundle id 写错了,或被删了)。",
            steps: [
              { description: "看当前生效配置里那两个目标", command: "a2 url-router status --json" },
              {
                description: "只判不开,确认决策本身对不对",
                command: "a2 url-router route <url> --dry-run --json",
              },
              {
                description: `改配置里的目标(兜底浏览器 / Roxy 的 .app 路径)`,
                command: `编辑 ${urlRouterConfigPath(context.paths)}`,
              },
            ],
            context: { target: error.target },
          },
        });
      }
    },
  };
}

// MARK: - takeover / restore(本票:契约 + 幂等判据)

function takeover(context: UrlRouterContext): Capability {
  return {
    descriptor: {
      id: "url-router.takeover",
      risk: "dangerous",
      summary:
        `把 ${A2_PANEL_BUNDLE_ID} 设为 http+https 的系统默认 handler(dangerous:改的是全系统的默认浏览器)。` +
        "已经是了就幂等直通、不弹框",
      parameters: [],
      cliAlias: ["url-router", "takeover"],
    },
    handler: async () => await handoff(context, A2_PANEL_BUNDLE_ID, "takeover"),
  };
}

function restore(context: UrlRouterContext): Capability {
  return {
    descriptor: {
      id: "url-router.restore",
      risk: "dangerous",
      summary:
        "把系统默认 handler 设回兜底浏览器(dangerous:同上)。缺省取配置里的 fallbackBrowserBundleID;已经是了就幂等直通",
      parameters: [
        {
          name: "to",
          type: "string",
          required: false,
          description:
            "显式覆写还原目标的 bundle id(可选;缺省取配置里的 fallbackBrowserBundleID —— **永不查系统默认**,那会递归)",
        },
      ],
      cliAlias: ["url-router", "restore"],
    },
    handler: async (input) => {
      const override = input["to"];
      if (override !== undefined && override !== null) {
        if (typeof override !== "string" || override.trim().length === 0) {
          throw new CapabilityFailedError(
            "--to 需要一个非空的 bundle id。",
            `收到 ${JSON.stringify(override)}。`,
            { code: ErrorCode.invalidParams },
          );
        }
      }
      const target =
        typeof override === "string" && override.trim().length > 0
          ? override.trim()
          : (await effectiveConfig(context)).fallbackBrowserBundleID;
      return await handoff(context, target, "restore");
    },
  };
}

/**
 * takeover 与 restore 的**同一条身子**:它们只在"目标是谁"上不同。
 *
 * 顺序是安全语义的一部分:**先读现状再说别的**。已经是目标 → `already: true` 收工
 * (spec §3 的幂等判据:不弹框、不下发任何指令);读不出来 → 按"不是"处理,fail-closed ——
 * 猜"大概已经是了"会让一次真正需要确认的接管被静默跳过。
 */
async function handoff(
  context: UrlRouterContext,
  target: string,
  action: "takeover" | "restore",
): Promise<JsonValue> {
  const snapshot = await readHandlerSnapshot(handlerReader(context), target);
  if (snapshot.matchesTarget === true) {
    return payload({ target, already: true, handler: handlerView(snapshot) });
  }
  throw new CapabilityFailedError(
    `url-router.${action} 的执行器在本版内核里还没接线,已拒绝执行(什么都没改)。`,
    "改默认 handler 只有一条合法路径:内核经 UDS 下发执行指令帧,由 A2 Panel 调 " +
      "`setDefaultApplication(at:toOpenURLsWithScheme:)`,系统弹框即确认器(spec §5/§6.3)。" +
      "那条链归施工 04 票 —— 在它接上之前,内核宁可如实说「没做」,也不走任何替代路径。",
    {
      code: ErrorCode.urlRouterExecutorUnwired,
      guidance: {
        summary:
          "本版内核只能判断「是不是已经是目标了」。要真的改,眼下请在系统设置里手选,或等执行器接线(04 票)。",
        steps: [
          { description: "先看清此刻的 handler 现状", command: "a2 url-router status --json" },
          {
            description:
              action === "takeover"
                ? "在「系统设置 → 桌面与程序坞 → 默认网页浏览器」里手选 A2 Panel"
                : `在「系统设置 → 桌面与程序坞 → 默认网页浏览器」里手选目标浏览器(${target})`,
          },
        ],
        context: {
          capability: `url-router.${action}`,
          target,
          http: snapshot.http ?? "(未能判定)",
          https: snapshot.https ?? "(未能判定)",
        },
      },
    },
  );
}

// MARK: - 共用

function ports(context: UrlRouterContext): UrlRouterPorts {
  return context.ports ?? createUrlRouterPorts(context.env);
}

function handlerReader(context: UrlRouterContext): DefaultHandlerReader {
  return context.handlers ?? createDefaultHandlerReader(ports(context));
}

/**
 * 生效配置。**配置用不了不是这几条能力的错误路径**:`loadUrlRouterConfig` 已经整份退回缺省,
 * 于是没配过、配歪了的机器照样能分流(缺省域名表本身就是产品意图)。
 * 「配歪了」这件事由 `url-router.status` 指名道姓地说,不在每条命令上重复报警。
 */
async function effectiveConfig(context: UrlRouterContext): Promise<UrlRouterConfig> {
  const load: UrlRouterConfigLoad = await loadUrlRouterConfig(context.paths);
  return load.config;
}

/** 走到 handler 说明校验已过(必填 + 类型都对),这里只是取值。 */
function requiredUrl(input: Record<string, JsonValue>): string {
  return input["url"] as string;
}
