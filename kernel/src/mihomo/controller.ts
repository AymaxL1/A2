// mihomo external-controller 的客户端 —— 内核与一个"可能不是我的" mihomo 之间**唯一的**接触面。
//
// 边界写死在这里(06 票立、07 票加写面时原样保留):
//   * 目标地址必须先过 `loopbackTarget()`(非回环不发字节);
//   * 一律带超时,探不通就是探不通,不重试、不升级手段、不去猜对方在哪;
//   * **端点白名单是封闭的**:下面 `Route` 里列的就是全部,没有别的地方拼路径。
//
// **红线在动词上**:本文件里没有 `/restart`、没有 `/upgrade`、没有 `DELETE`——进程生死永远归原托管方。
// 写面分两档,由调用方(`src/proxy/endpoint.ts`)按「这份归不归 a2 管」决定发不发:
//   * `PATCH /configs` —— 改运行参数(mode)。**收编档也可以**:它改的是对方自己那份配置里的一个开关,
//     不换文件、不动进程,这就是票面说的「写面到配置为止」。
//   * `PUT /proxies/<组>` —— 选节点。同上:选节点是运行时状态,不碰配置文件也不碰进程。
//   * `PUT /configs {path}` —— **从路径整份重载**。这一条**只对 a2 自管那份发**:它的语义是
//     「把配置整个换成我这份」,对别人的实例等于抢配置,与「生死归原托管方」同源的边界。

import type { MihomoCapability } from "../contract/wire.ts";
import { parseVersion } from "./pin.ts";

/** 探一次的上限。本机回环上的一次 GET 一般是个位数毫秒,给到 1.5s 已经很宽。 */
export const CONTROLLER_TIMEOUT_MS = 1500;

/**
 * 测速那一条要另给上限:它在**内核里**真的去连测试 URL,耗时由 `timeout` 参数决定,
 * 拿探针的 1.5s 去卡它必然误判。上限 = 调用方给的 timeout 再加一点点往返余量。
 */
const DELAY_OVERHEAD_MS = 2000;

/** 端点白名单 —— 本文件之外没有任何一处拼 mihomo 的路径。 */
const Route = {
  version: "/version",
  configs: "/configs",
  proxies: "/proxies",
} as const;

export interface ControllerProbe {
  /** `/version` 应答了(能力位 `rest_api` 的判据)。 */
  reachable: boolean;
  version?: string;
  /** `/version` 的 `meta` 为真 = mihomo 系内核。 */
  meta: boolean;
  /** `GET /configs` 读得到。 */
  configsReadable: boolean;
  /** 探不通时的人类可读原因(进 error.detail)。 */
  detail?: string;
}

/** 与一个 external-controller 说话所需的全部信息(地址恒回环,secret 每次现读)。 */
export interface ControllerTarget {
  target: string;
  secret?: string;
}

export function probeCapabilities(probe: ControllerProbe): MihomoCapability[] {
  const capabilities: MihomoCapability[] = [];
  if (probe.reachable) capabilities.push("rest_api");
  if (probe.meta) capabilities.push("meta_core");
  if (probe.configsReadable) capabilities.push("configs_read");
  return capabilities;
}

/** 探一个 external-controller。**永不抛** —— 探不通是一种结果,不是异常。 */
export async function probeController(
  target: string,
  secret: string | undefined,
  timeoutMs: number = CONTROLLER_TIMEOUT_MS,
): Promise<ControllerProbe> {
  const version = await getJson({ target, ...(secret ? { secret } : {}) }, Route.version, timeoutMs);
  if (!version.ok) {
    return { reachable: false, meta: false, configsReadable: false, detail: version.detail };
  }

  const body = version.body as { version?: unknown; meta?: unknown };
  const parsed = typeof body.version === "string" ? parseVersion(body.version) : undefined;
  const configs = await getJson({ target, ...(secret ? { secret } : {}) }, Route.configs, timeoutMs);
  return {
    reachable: true,
    ...(parsed ? { version: parsed } : {}),
    meta: body.meta === true,
    configsReadable: configs.ok,
  };
}

// MARK: - 读面

/** `GET /configs` 里我们认得的那几项(其余原样忽略 —— 内核新增字段不该让客户端炸)。 */
export interface RemoteConfigs {
  mode: string;
  mixedPort?: number;
  allowLan?: boolean;
  logLevel?: string;
}

/**
 * 一个可切换分组。**判据是条目带 `all` 数组**(而不是看 `type`):
 * Selector/URLTest/Fallback/LoadBalance 都带 `all`,裸节点不带 —— 这样内核新增组类型时不必改代码。
 */
export interface ProxyGroupFact {
  name: string;
  type: string;
  now?: string;
  all: string[];
}

export async function readConfigs(endpoint: ControllerTarget): Promise<RemoteConfigs> {
  const body = (await getJsonOrThrow(endpoint, Route.configs)) as Record<string, unknown>;
  const mode = typeof body["mode"] === "string" ? body["mode"] : undefined;
  if (mode === undefined) throw new ControllerError(`GET ${Route.configs} 的应答里没有 mode 字段。`);
  const mixedPort = body["mixed-port"];
  const allowLan = body["allow-lan"];
  const logLevel = body["log-level"];
  return {
    mode,
    ...(typeof mixedPort === "number" ? { mixedPort } : {}),
    ...(typeof allowLan === "boolean" ? { allowLan } : {}),
    ...(typeof logLevel === "string" ? { logLevel } : {}),
  };
}

/**
 * 全部可切换分组,**按名排序**(确定性输出是逐字节断言与人类 diff 得以成立的前提)。
 */
export async function readGroups(endpoint: ControllerTarget): Promise<ProxyGroupFact[]> {
  const body = (await getJsonOrThrow(endpoint, Route.proxies)) as { proxies?: unknown };
  const proxies = body.proxies;
  if (typeof proxies !== "object" || proxies === null) {
    throw new ControllerError(`GET ${Route.proxies} 的应答里没有 proxies 字段。`);
  }
  const groups: ProxyGroupFact[] = [];
  for (const name of Object.keys(proxies as Record<string, unknown>).sort()) {
    const entry = (proxies as Record<string, unknown>)[name];
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as Record<string, unknown>;
    if (!Array.isArray(record["all"])) continue;
    const all = (record["all"] as unknown[]).filter((item): item is string => typeof item === "string");
    const now = typeof record["now"] === "string" && record["now"].length > 0 ? record["now"] : undefined;
    groups.push({
      name,
      type: typeof record["type"] === "string" ? record["type"] : "Unknown",
      ...(now ? { now } : {}),
      all,
    });
  }
  return groups;
}

/**
 * 当前节点(best-effort):按名排序后**第一个** `now` 非空的组。
 * 没有"当前节点"这个概念的一等公民字段,这是旧实现的口径,原样保留。
 */
export async function readCurrentNode(endpoint: ControllerTarget): Promise<string | undefined> {
  for (const group of await readGroups(endpoint)) {
    if (group.now) return group.now;
  }
  return undefined;
}

/**
 * 按组测速:`GET /group/<组>/delay?url=&timeout=`。
 *
 * **返回的是「该组每个候选节点」的结果,以候选清单为准逐个对齐** —— delay map 里缺席的节点
 * 就是超时(`delayMs` 缺省 + `timeout: true`),**绝不臆造 0**。一次测速 = 两次往返(先取候选,再取延迟)。
 */
export async function testGroupDelay(
  endpoint: ControllerTarget,
  group: string,
  url: string,
  timeoutMs: number,
): Promise<{ node: string; delayMs?: number; timeout: boolean }[]> {
  const groups = await readGroups(endpoint);
  const found = groups.find((candidate) => candidate.name === group);
  if (!found) throw new ControllerError(unknownGroupDetail(group, groups));

  const route =
    `/group/${encodePathSegment(group)}/delay` +
    `?url=${encodeQueryValue(url)}&timeout=${timeoutMs}`;
  const body = (await getJsonOrThrow(endpoint, route, timeoutMs + DELAY_OVERHEAD_MS)) as Record<
    string,
    unknown
  >;
  return found.all.map((node) => {
    const delay = body[node];
    return typeof delay === "number" && Number.isFinite(delay)
      ? { node, delayMs: delay, timeout: false }
      : { node, timeout: true };
  });
}

// MARK: - 写面

/**
 * 改运行参数。**真核约定 PATCH 才是「改运行参数」**,`PUT /configs` 是「从路径重载」——
 * 动词错会误触发整份重载,所以这两条在本文件里是两个各自具名的函数,调用方不可能拼错。
 */
export async function patchConfigs(
  endpoint: ControllerTarget,
  patch: Record<string, string | number | boolean>,
): Promise<void> {
  await sendExpectingSuccess(endpoint, "PATCH", Route.configs, patch);
}

/** 选节点:`PUT /proxies/<组>` body `{"name": <节点>}`。 */
export async function selectNode(
  endpoint: ControllerTarget,
  group: string,
  node: string,
): Promise<void> {
  await sendExpectingSuccess(endpoint, "PUT", `${Route.proxies}/${encodePathSegment(group)}`, {
    name: node,
  });
}

/**
 * 从路径整份重载:`PUT /configs` body `{"path": <绝对路径>}`。
 * **只对 a2 自管那份发**(边界见文件头)。
 */
export async function reloadConfig(endpoint: ControllerTarget, configPath: string): Promise<void> {
  await sendExpectingSuccess(endpoint, "PUT", Route.configs, { path: configPath });
}

// MARK: - 传输

/** 控制面这一层的失败。上层翻成带 code 的 `WireError`,原始细节原样带出。 */
export class ControllerError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ControllerError";
  }
}

type JsonResult = { ok: true; body: unknown } | { ok: false; detail: string };

async function getJson(
  endpoint: ControllerTarget,
  route: string,
  timeoutMs: number,
): Promise<JsonResult> {
  const url = `http://${endpoint.target}${route}`;
  try {
    const response = await fetch(url, {
      method: "GET",
      headers: authHeaders(endpoint),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) return { ok: false, detail: statusDetail("GET", url, response.status) };
    return { ok: true, body: await response.json() };
  } catch (error) {
    return { ok: false, detail: `GET ${url} 失败:${String(error)}` };
  }
}

async function getJsonOrThrow(
  endpoint: ControllerTarget,
  route: string,
  timeoutMs: number = CONTROLLER_TIMEOUT_MS,
): Promise<unknown> {
  const result = await getJson(endpoint, route, timeoutMs);
  if (!result.ok) throw new ControllerError(result.detail);
  return result.body;
}

/** 写请求。mihomo 写成功惯例回 204,所以判据是 2xx 而不是 200。 */
async function sendExpectingSuccess(
  endpoint: ControllerTarget,
  method: "PATCH" | "PUT",
  route: string,
  body: Record<string, unknown>,
): Promise<void> {
  const url = `http://${endpoint.target}${route}`;
  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: { ...authHeaders(endpoint), "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(CONTROLLER_TIMEOUT_MS),
    });
  } catch (error) {
    throw new ControllerError(`${method} ${url} 失败:${String(error)}`);
  }
  if (response.status < 200 || response.status >= 300) {
    const text = await response.text().catch(() => "");
    throw new ControllerError(
      `${statusDetail(method, url, response.status)}${text.trim() ? ` 应答:${text.trim()}` : ""}`,
    );
  }
}

function authHeaders(endpoint: ControllerTarget): Record<string, string> {
  return endpoint.secret ? { Authorization: `Bearer ${endpoint.secret}` } : {};
}

function statusDetail(method: string, url: string, status: number): string {
  return status === 401
    ? `${method} ${url} 返回 401 —— external-controller 的 secret 不对(或没配)。`
    : `${method} ${url} 返回 HTTP ${status}。`;
}

function unknownGroupDetail(group: string, groups: ProxyGroupFact[]): string {
  const names = groups.map((candidate) => candidate.name);
  return names.length === 0
    ? `内核里一个可切换分组都没有,组 ${JSON.stringify(group)} 无从谈起(当前配置可能没有 proxy-groups)。`
    : `内核里没有名叫 ${JSON.stringify(group)} 的分组。现有分组:${names.join("、")}`;
}

/** 路径段编码:组名/节点名可能含 `/`、`#`、空格,必须逐段转义(不能整条 URL 一把梭)。 */
function encodePathSegment(value: string): string {
  return encodeURIComponent(value);
}

function encodeQueryValue(value: string): string {
  return encodeURIComponent(value);
}
