// URL 分流的**决策核心** —— 一条 URL 该交给谁。移植自母本 `ClaudeURLRouter.swift::Router.decision(for:)`。
//
// 这一层是**纯函数**,这是有意的:决策需要的运行期事实(Roxy 有没有在跑、CDP 端口是哪个)
// 一律以参数注入,探测本身在别处(02 票的执行侧:`ps` / `lsof` / CDP 校验)。于是
// 「命中哪条域名、降到第几级」这件全产品最容易悄悄错掉的事,可以在函数缝上把边界写全,
// 不必先造出一台跑着的 Roxy 才测得到。
//
// 域名两分的判据只有一条,且**两边都归一**(母本语义):host 与配置里的域名各自小写、去掉前后点号后,
// 相等或以 `.<域名>` 结尾即命中。写死这条的原因:`claude.ai.evil.com` 必须**不**命中 `claude.ai` ——
// 用裸 `includes` 或 `endsWith(domain)`(少那个点)都会把钓鱼域名送进登录着账号的 profile。

import { hasRoxyAPIConfig, type UrlRouterConfig } from "./config.ts";

/**
 * 决策的五值(spec §3 的 `decide` 输出词表)。分支用 `kind`,上报用 `decisionWord`。
 *
 * `unsupported` 与 `fallback-browser` 有意分成两条:执行侧对它俩的动作**碰巧相同**
 * (都交兜底浏览器,母本亦然),但「这不是个 http(s) URL」与「这是条不该进 Roxy 的网页」
 * 是两件事,报文里必须分得开 —— 否则 `--dry-run` 说不清它到底看懂了什么。
 */
export type RouteDecision =
  | { kind: "fallback-browser" }
  | { kind: "roxy-cdp"; port: number }
  | { kind: "roxy-api" }
  | { kind: "roxy-launcher" }
  | { kind: "unsupported" };

/** 决策的线上写法(spec §3 词表逐字):`roxy-cdp` 带端口,其余就是 `kind` 本身。 */
export function decisionWord(decision: RouteDecision): string {
  return decision.kind === "roxy-cdp" ? `roxy-cdp:${decision.port}` : decision.kind;
}

/** 能被分流的 scheme —— 只有这两个。`URL.protocol` 自带冒号且已小写。 */
const ROUTABLE_PROTOCOLS = new Set(["http:", "https:"]);

export interface DecisionInputs {
  /** 用户点的那条 URL 的**原文**(壳原样转发过来的字符串,内核不预处理)。 */
  url: string;
  config: UrlRouterConfig;
  /**
   * 探测出来的、确实属于目标 profile 的 CDP 端口;没探到(或没探)填 `null`。
   *
   * 这是本函数唯一的运行期输入,**必须显式给**:写 `null` 是一句声明("这次没有可用的 CDP"),
   * 而可选参数会让"忘了探测"与"探测过、没有"长得一模一样。
   */
  roxyDevToolsPort: number | null;
}

/**
 * 决策。顺序即母本:先看 scheme,再看域名,命中后按 CDP → API → launcher 三级降级。
 *
 * URL 解析不动就是 `unsupported`:壳转发的是系统给的任意字符串,内核不猜它想说什么。
 */
export function decide(inputs: DecisionInputs): RouteDecision {
  const url = parseURL(inputs.url);
  if (!url || !ROUTABLE_PROTOCOLS.has(url.protocol)) return { kind: "unsupported" };
  if (!isRoutedHost(url.hostname, inputs.config.routedDomains)) return { kind: "fallback-browser" };
  if (inputs.roxyDevToolsPort !== null) return { kind: "roxy-cdp", port: inputs.roxyDevToolsPort };
  if (hasRoxyAPIConfig(inputs.config)) return { kind: "roxy-api" };
  return { kind: "roxy-launcher" };
}

/** 解析不动就当没有(不抛):这条字符串来自系统事件,不是内核自己拼的。 */
export function parseURL(raw: string): URL | undefined {
  try {
    return new URL(raw);
  } catch {
    return undefined;
  }
}

/**
 * host 归一:小写 + 去掉**前后所有点号**。
 *
 * 后一半不是洁癖:`http://claude.ai./x` 是合法 URL(尾点 = 绝对域名),`URL.hostname` 会原样留着那个点,
 * 不去掉就与 `claude.ai` 匹不上 —— 一个尾点就能绕过整张分流表。
 */
export function normalizeHost(host: string): string {
  return host.toLowerCase().replace(/^\.+/, "").replace(/\.+$/, "");
}

/**
 * 域名两分:host 等于某条 routedDomain,或是它的子域名(`.<domain>` 后缀)。
 *
 * 空 host / 空域名一律不命中 —— 否则一条手滑写进配置的 `""` 会把**所有** URL 送进 Roxy。
 */
export function isRoutedHost(host: string, routedDomains: readonly string[]): boolean {
  const normalized = normalizeHost(host);
  if (normalized.length === 0) return false;
  return routedDomains.some((domain) => {
    const target = normalizeHost(domain);
    if (target.length === 0) return false;
    return normalized === target || normalized.endsWith(`.${target}`);
  });
}
