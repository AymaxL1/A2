// mihomo external-controller 的**只读**探针。
//
// 本文件是内核与一个"可能不是我的" mihomo 之间唯一的接触面,所以它的边界写死在这里:
//   * **只发 GET**,只发 `/version` 与 `/configs` 两条 —— 没有任何一条会改对方的状态;
//   * 目标地址必须先过 `loopbackTarget()`(非回环不发字节);
//   * 一律带超时,探不通就是探不通,不重试、不升级手段、不去猜对方在哪。
//
// 07 票要长的写面(`PATCH /configs` 改 mode、`PUT /proxies/<组>` 选节点)会加在这一层,
// 但**收编档的写面到配置为止**:进程生死永远归原托管方,内核不碰 `/restart`、不碰 `/upgrade`。

import type { MihomoCapability } from "../contract/wire.ts";
import { parseVersion } from "./pin.ts";

/** 探一次的上限。本机回环上的一次 GET 一般是个位数毫秒,给到 1.5s 已经很宽。 */
export const CONTROLLER_TIMEOUT_MS = 1500;

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
  const version = await getJson(target, "/version", secret, timeoutMs);
  if (!version.ok) {
    return { reachable: false, meta: false, configsReadable: false, detail: version.detail };
  }

  const body = version.body as { version?: unknown; meta?: unknown };
  const parsed = typeof body.version === "string" ? parseVersion(body.version) : undefined;
  const configs = await getJson(target, "/configs", secret, timeoutMs);
  return {
    reachable: true,
    ...(parsed ? { version: parsed } : {}),
    meta: body.meta === true,
    configsReadable: configs.ok,
  };
}

type JsonResult = { ok: true; body: unknown } | { ok: false; detail: string };

async function getJson(
  target: string,
  route: string,
  secret: string | undefined,
  timeoutMs: number,
): Promise<JsonResult> {
  const url = `http://${target}${route}`;
  try {
    const response = await fetch(url, {
      method: "GET",
      headers: secret ? { Authorization: `Bearer ${secret}` } : {},
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) {
      return {
        ok: false,
        detail:
          response.status === 401
            ? `GET ${url} 返回 401 —— external-controller 的 secret 不对(或没配)。`
            : `GET ${url} 返回 HTTP ${response.status}。`,
      };
    }
    return { ok: true, body: await response.json() };
  } catch (error) {
    return { ok: false, detail: `GET ${url} 失败:${String(error)}` };
  }
}
