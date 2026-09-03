// URL 分流的**执行侧**(施工 02 票)——「决策说该去哪儿」之后,真把 URL 送过去的那一半。
//
// 移植自母本 `ClaudeURLRouter.swift` 的执行族(`findRoxyDevToolsPort` / `roxyMainPIDs` /
// `listeningPorts` / `devToolsPortMatchesProfile` / `openInExistingRoxy` / `openViaRoxyAPI` /
// `openURL` / `sanitize`),形状逐条对齐,三处**有意不同**,都在各自的函数上写了理由:
//   1. 打开浏览器不走 `NSWorkspace`(内核是无 GUI 的 bin),走 `/usr/bin/open`(02 研究票结论 3);
//   2. 母本的 `open` 失败只写一行日志就算了,这里**抛结构化错误** —— CLI/agent 必须知道"没打开";
//   3. 不写独立日志文件(spec §8:不设 logPath),步骤记进 result 的 `steps`,**过 `sanitizeUrlForLog`**。
//
// **一切外部世界都经 `UrlRouterPorts`**(进程、HTTP、时钟):单测全用假件,不真开浏览器、
// 不真 `ps` 依赖 Roxy 在跑、不出回环外网络。生产实现 `createUrlRouterPorts()` 里那四个程序的路径
// 可经环境变量覆写 —— 与 `A2_NETWORKSETUP` 同一种用途(在别的平台上跑一遍 macOS 代码路径、
// 让 CLI 测试指向行为假件)。

import { cdpNewTabEndpoint } from "./cdp.ts";
import { hasRoxyAPIConfig, type UrlRouterConfig } from "./config.ts";
import { decide, decisionWord, parseURL, type RouteDecision } from "./decide.ts";

// MARK: - 外部世界的四个口

/** 四个外部程序的落点。全部**绝对路径**:PATH 上放一个同名文件不该改变内核的行为。 */
export interface UrlRouterBinaries {
  /** 进程全表(认 Roxy 主进程)。 */
  ps: string;
  /** 某个 pid 的 LISTEN 端口(找 CDP)。 */
  lsof: string;
  /** 把 URL 交给某个 app。 */
  open: string;
  /** 读 LaunchServices 里登记的默认 handler(只读,见 `handler.ts`)。 */
  defaults: string;
}

export const DEFAULT_URL_ROUTER_BINARIES: UrlRouterBinaries = {
  ps: "/bin/ps",
  lsof: "/usr/sbin/lsof",
  open: "/usr/bin/open",
  defaults: "/usr/bin/defaults",
};

/** 覆写用的环境变量名(仅测试与诊断用,与 `A2_NETWORKSETUP` 同一档)。 */
export const BINARY_ENV: Record<keyof UrlRouterBinaries, string> = {
  ps: "A2_URL_ROUTER_PS",
  lsof: "A2_URL_ROUTER_LSOF",
  open: "A2_URL_ROUTER_OPEN",
  defaults: "A2_URL_ROUTER_DEFAULTS",
};

/** 跑完一条命令得到的三样(判断只需要这三样)。 */
export interface CommandResult {
  /** 起不来 / 被超时打断记 `-1` —— 与"跑了、非零退出"分得开。 */
  exitCode: number;
  stdout: string;
  stderr: string;
}

/**
 * 执行侧与外部世界之间**唯一的缝**。三件事各一个方法,外加那张程序路径表。
 *
 * 为什么连 `sleep` 都要注入:Roxy API 那条路上有一个「开完 profile 等它露出 CDP 端口」的重试循环,
 * 不注入时钟,测那条循环就得真等好几秒 —— 于是没人会去测它,而它恰恰是最容易写错的一段。
 */
export interface UrlRouterPorts {
  readonly bin: UrlRouterBinaries;
  /** 跑一条命令到退出(**绝不经 shell**:URL 永远是独立 argv,无注入面)。 */
  run(cmd: readonly string[], timeoutMs: number): Promise<CommandResult>;
  /** 发一次 HTTP(回环 CDP 与用户配置的 Roxy API,别处一个字节都不发)。 */
  fetch(url: string, init?: RequestInit): Promise<Response>;
  sleep(ms: number): Promise<void>;
}

/** 生产实现。程序路径按 `BINARY_ENV` 覆写,缺省是上面那张绝对路径表。 */
export function createUrlRouterPorts(
  env: Record<string, string | undefined> = process.env,
): UrlRouterPorts {
  const bin = { ...DEFAULT_URL_ROUTER_BINARIES };
  for (const key of Object.keys(bin) as (keyof UrlRouterBinaries)[]) {
    const override = env[BINARY_ENV[key]]?.trim();
    if (override) bin[key] = override;
  }
  return {
    bin,
    run: runCommand,
    fetch: (url, init) => fetch(url, init),
    sleep: (ms) => Bun.sleep(ms),
  };
}

async function runCommand(cmd: readonly string[], timeoutMs: number): Promise<CommandResult> {
  let proc;
  try {
    proc = Bun.spawn({ cmd: [...cmd], stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  } catch (error) {
    // 程序不在(别的平台、被删了)不是异常路径的"崩",是一条**事实**:这条探测什么都没查到。
    return { exitCode: -1, stdout: "", stderr: String(error) };
  }
  const timer = setTimeout(() => proc.kill(), timeoutMs);
  try {
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    await proc.exited;
    return { exitCode: proc.exitCode ?? -1, stdout, stderr };
  } catch (error) {
    return { exitCode: -1, stdout: "", stderr: String(error) };
  } finally {
    clearTimeout(timer);
  }
}

// MARK: - 时间预算(数值逐条对着母本)

/** `/json/version` 与 `/json/list` 的探测超时(母本 `httpText(timeout: 0.8)`)。 */
export const CDP_PROBE_TIMEOUT_MS = 800;
/** `PUT /json/new` 的上限(母本 `semaphore.wait(.now() + 2.0)`)。 */
export const CDP_NEW_TAB_TIMEOUT_MS = 2000;
/** Roxy API 在配置的超时之上再留的缓冲(母本 `timeout + 0.5`)。 */
export const ROXY_API_TIMEOUT_BUFFER_MS = 500;
/**
 * `ps` / `lsof` / `open` 各自的上限。**母本没有这一条**:它是个点一下就退的小程序,
 * 卡住了顶多是这一次点击没反应。内核是常驻的 —— 一条卡死的 `lsof` 会把这条能力永远挂在那儿,
 * 所以这里必须有个头。取 5s:02 研究票实测 ps 15.6ms / lsof 21.3ms,慢两个数量级都还够。
 */
export const PROCESS_TIMEOUT_MS = 5000;

/**
 * 配置里那三个数在**使用侧**的钳制(01 票注释里说好的:校验只到类型,值域在用的地方兜)。
 *
 * 下限逐字照母本(`max(1, attempts)` / `max(0.05, delay)`);
 * **上限是母本没有的**,理由同 `PROCESS_TIMEOUT_MS`:`roxyStartupAttempts: 1000000000` 或
 * `roxyAPITimeoutSeconds: 1e300` 在一个点一下就退的小程序里只是"这次点击白等了",
 * 在常驻内核里是"这条能力再也不返回了"。而且 `AbortSignal.timeout` 收不下 1e300,不钳制会当场抛。
 */
export const STARTUP_ATTEMPTS_RANGE = { min: 1, max: 100 } as const;
export const STARTUP_DELAY_SECONDS_RANGE = { min: 0.05, max: 5 } as const;
export const API_TIMEOUT_SECONDS_RANGE = { min: 0.1, max: 120 } as const;

function clamp(value: number, range: { min: number; max: number }): number {
  if (!Number.isFinite(value)) return range.min;
  return Math.min(range.max, Math.max(range.min, value));
}

// MARK: - 日志脱敏(母本 `sanitize`)

/**
 * 能进日志/报文的那份 URL:**query 与 fragment 一律换成 `redacted`**,其余原样。
 *
 * 母本的语义逐字保留(有值才换,没有就不凭空加一个)。一处**收得比母本紧**:解析不动的字符串
 * 不回显原文 —— 那是系统事件送进来的任意字符串,母本会把它原样写进自己的日志文件,
 * 而这里的产物要进机读报文,不该替一段来路不明的文本做转发。
 */
export function sanitizeUrlForLog(raw: string): string {
  const url = parseURL(raw);
  if (!url) return "(解析不动的 URL,已隐去原文)";
  if (url.search !== "") url.search = "redacted";
  if (url.hash !== "") url.hash = "redacted";
  return url.toString();
}

// MARK: - 探测:哪个端口是目标 profile 的 CDP

/**
 * `ps` 全表里认 Roxy 主进程(母本 `roxyMainPIDs`)。三个条件缺一不可:
 *   * 命令行含 `roxyProcessMatch`(是 Roxy 的可执行文件);
 *   * 命令行含 `roxyProfilePathMarker + roxyProfileID`(**是这一个 profile**,不是随便哪个);
 *   * 命令行**不含** `/Helpers/` —— Chromium 系的渲染/GPU 子进程命令行里也带着 profile 路径,
 *     认上它们等于拿一堆没有 CDP 的 pid 去问 `lsof`。
 */
export async function roxyMainPIDs(
  ports: UrlRouterPorts,
  config: UrlRouterConfig,
): Promise<number[]> {
  const result = await ports.run(
    [ports.bin.ps, "axww", "-o", "pid=,command="],
    PROCESS_TIMEOUT_MS,
  );
  const profileMarker = `${config.roxyProfilePathMarker}${config.roxyProfileID}`;
  const pids: number[] = [];
  for (const line of result.stdout.split("\n")) {
    if (!line.includes(config.roxyProcessMatch)) continue;
    if (!line.includes(profileMarker)) continue;
    if (line.includes("/Helpers/")) continue;
    const pid = Number.parseInt(line.trim().split(/\s+/)[0] ?? "", 10);
    if (Number.isInteger(pid) && pid > 0) pids.push(pid);
  }
  return pids;
}

/** 该 pid 正在听的**回环**端口(母本 `listeningPorts`;非回环的地址不是我们要找的 CDP)。 */
export async function listeningPorts(ports: UrlRouterPorts, pid: number): Promise<number[]> {
  const result = await ports.run(
    [ports.bin.lsof, "-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN"],
    PROCESS_TIMEOUT_MS,
  );
  const found: number[] = [];
  for (const match of result.stdout.matchAll(/127\.0\.0\.1:(\d+)/g)) {
    const port = Number.parseInt(match[1] as string, 10);
    if (Number.isInteger(port) && port > 0) found.push(port);
  }
  return found;
}

/**
 * 这个端口上的 CDP 是不是**目标 profile 的**(母本 `devToolsPortMatchesProfile`)。两问缺一不可:
 *   * `/json/version` 的正文含 `Chrome/` —— 确认这端口后面确实是个 CDP,而不是碰巧在听的别的东西;
 *   * `/json/list` 的正文含 `dashboard.html?id=<profileID>` —— 确认是**这一个** profile。
 *
 * 第二问是安全判据不是洁癖:Roxy 可以同时开着好几个 profile,各有各的 CDP;认错一个,
 * 链接就会开进另一个账号的窗口里。
 */
export async function devToolsPortMatchesProfile(
  ports: UrlRouterPorts,
  config: UrlRouterConfig,
  port: number,
): Promise<boolean> {
  const version = await httpText(ports, `http://127.0.0.1:${port}/json/version`);
  if (version === undefined || !version.includes("Chrome/")) return false;
  const list = await httpText(ports, `http://127.0.0.1:${port}/json/list`);
  if (list === undefined) return false;
  return list.includes(`dashboard.html?id=${config.roxyProfileID}`);
}

/** 2xx 才算数,别的(含超时、连接被拒)一律当作"问不到"(母本 `httpText`)。 */
async function httpText(ports: UrlRouterPorts, url: string): Promise<string | undefined> {
  try {
    const response = await ports.fetch(url, { signal: AbortSignal.timeout(CDP_PROBE_TIMEOUT_MS) });
    if (!response.ok) return undefined;
    return await response.text();
  } catch {
    return undefined;
  }
}

/**
 * 目标 profile 的 CDP 端口,没有就是 `null`(母本 `findRoxyDevToolsPort`)。
 *
 * 端口**去重后升序**再逐个校验,与母本一致:一个确定的顺序意味着同一台机器上的同一种局面
 * 每次都挑中同一个端口 —— 否则"有时开到 A 窗口有时开到 B 窗口"这种事没人排查得了。
 */
export async function findRoxyDevToolsPort(
  ports: UrlRouterPorts,
  config: UrlRouterConfig,
): Promise<number | null> {
  const pids = await roxyMainPIDs(ports, config);
  const candidates: number[] = [];
  for (const pid of pids) candidates.push(...(await listeningPorts(ports, pid)));
  for (const port of [...new Set(candidates)].sort((a, b) => a - b)) {
    if (await devToolsPortMatchesProfile(ports, config, port)) return port;
  }
  return null;
}

// MARK: - 三级降级各自的执行

/** 在已经跑着的 Roxy 上开一个标签页(母本 `openInExistingRoxy`)。端点编码见 `cdp.ts` 的 `#` 坑。 */
export async function openInExistingRoxy(
  ports: UrlRouterPorts,
  port: number,
  url: string,
): Promise<boolean> {
  try {
    const response = await ports.fetch(cdpNewTabEndpoint(port, url), {
      method: "PUT",
      signal: AbortSignal.timeout(CDP_NEW_TAB_TIMEOUT_MS),
    });
    return response.ok;
  } catch {
    return false;
  }
}

/** Roxy API 应答里那个端口(母本 `roxyAPIPort(from:)`):`code` 非 0 即失败,否则按 http→driver→ws 取。 */
export function roxyAPIPortFrom(body: unknown, note: (line: string) => void): number | undefined {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return undefined;
  const json = body as Record<string, unknown>;
  const code = json["code"];
  if (typeof code === "number" && code !== 0) {
    note(`roxy-api-code code=${code} msg=${String(json["msg"] ?? "").slice(0, 160)}`);
    return undefined;
  }
  const data = json["data"];
  if (data === null || typeof data !== "object" || Array.isArray(data)) return undefined;
  for (const key of ["http", "driver", "ws"]) {
    const value = (data as Record<string, unknown>)[key];
    if (typeof value !== "string") continue;
    const port = extractPort(value);
    if (port !== undefined) return port;
  }
  return undefined;
}

/** 从 `http://127.0.0.1:50325` 或裸 `127.0.0.1:50325` 里取端口(母本 `extractPort`)。 */
export function extractPort(endpoint: string): number | undefined {
  try {
    const parsed = new URL(endpoint);
    if (parsed.port !== "") {
      const port = Number.parseInt(parsed.port, 10);
      if (Number.isInteger(port) && port > 0) return port;
    }
  } catch {
    // 不是完整 URL(`127.0.0.1:50325` 这种)——落到下面那条正则,与母本同一顺序。
  }
  const match = /:(\d+)/.exec(endpoint);
  if (!match) return undefined;
  const port = Number.parseInt(match[1] as string, 10);
  return Number.isInteger(port) && port > 0 ? port : undefined;
}

/**
 * 经 Roxy 本地 API 把 profile 开起来,再在它的 CDP 上开标签页(母本 `openViaRoxyAPI`)。
 *
 * **`roxyAPIKey` 只进请求头,一个字都不进报文/日志** —— 这条纪律在本函数里的落点:
 * 失败时说的是「API 没成」,绝不回显请求(请求头里就是那把钥匙)。
 *
 * 返回**标签页真开在了哪个端口**(没成是 `null`)—— 母本只返回成没成,而报文要说得出
 * 「经 API 拉起的 profile,标签页开在 127.0.0.1:<port>」,那是排查时唯一有用的那个数。
 */
export async function openViaRoxyAPI(
  ports: UrlRouterPorts,
  config: UrlRouterConfig,
  url: string,
  note: (line: string) => void,
): Promise<number | null> {
  if (!hasRoxyAPIConfig(config)) return null;
  // 三件套齐备由 `hasRoxyAPIConfig` 保证,这里只做母本那步"去掉首尾斜杠 + 补上路径的前导斜杠"。
  const host = (config.roxyAPIHost ?? "").replace(/^\/+/, "").replace(/\/+$/, "");
  const apiPath = config.roxyAPIOpenPath.startsWith("/")
    ? config.roxyAPIOpenPath
    : `/${config.roxyAPIOpenPath}`;
  const timeoutMs =
    clamp(config.roxyAPITimeoutSeconds, API_TIMEOUT_SECONDS_RANGE) * 1000 +
    ROXY_API_TIMEOUT_BUFFER_MS;

  let port: number | undefined;
  try {
    const response = await ports.fetch(`${host}${apiPath}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // 唯一一处碰到 key 的地方,且只在请求头里。
        [config.roxyAPITokenHeader]: config.roxyAPIKey as string,
      },
      body: JSON.stringify({
        workspaceId: config.roxyWorkspaceID,
        dirId: config.roxyProfileID,
        forceOpen: config.roxyForceOpen,
      }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) {
      note(`roxy-api-http-failed status=${response.status}`);
      return null;
    }
    port = roxyAPIPortFrom(await response.json().catch(() => undefined), note);
  } catch {
    note("roxy-api-error(请求没发出去或超时了)");
    return null;
  }
  if (port === undefined) return null;

  // profile 刚开起来,CDP 端口未必立刻就在听 —— 母本在这里重试,逐次间隔。
  const attempts = Math.trunc(clamp(config.roxyStartupAttempts, STARTUP_ATTEMPTS_RANGE));
  const delayMs = clamp(config.roxyStartupDelaySeconds, STARTUP_DELAY_SECONDS_RANGE) * 1000;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (await openInExistingRoxy(ports, port, url)) return port;
    // 最后一次失败之后不再等(母本会多睡一次)——那一觉睡完只是返回失败,纯白等。
    if (attempt < attempts - 1) await ports.sleep(delayMs);
  }
  note(`roxy-api-cdp-未就绪 attempts=${attempts}`);
  return null;
}

// MARK: - 把 URL 交出去

/** `open` 没能把 URL 交出去。**母本只写一行日志**,这里抛 —— agent 必须知道"链接没打开"。 */
export class UrlRouterOpenError extends Error {
  constructor(
    /** 交给谁(bundle id 或 .app 路径)。 */
    readonly target: string,
    readonly detail: string,
  ) {
    super(`没能把链接交给 ${target}。`);
    this.name = "UrlRouterOpenError";
  }
}

/**
 * `open -b <bundleid> <url>` / `open -a <path> <url>`(02 研究票结论 3:语义对齐母本
 * `NSWorkspace.open(activates: true)`,`open` 默认前置目标 app)。
 *
 * **URL 是独立 argv**,不拼进任何字符串、不经 shell —— 分流面收的是系统送来的任意字符串,
 * 这是它唯一一次接触"执行"的机会,注入面必须在这里归零。
 */
async function openWith(
  ports: UrlRouterPorts,
  selector: "-b" | "-a",
  target: string,
  url: string,
): Promise<void> {
  const result = await ports.run([ports.bin.open, selector, target, url], PROCESS_TIMEOUT_MS);
  if (result.exitCode === 0) return;
  throw new UrlRouterOpenError(
    target,
    `${ports.bin.open} ${selector} 退出码 ${result.exitCode}${
      result.stderr.trim() ? `:${result.stderr.trim().slice(0, 300)}` : ""
    }`,
  );
}

// MARK: - route:决策 + 执行 + 降级

/** 最终真的走了哪一步(决策词说的是"该走哪儿",这个说的是"实际从哪儿出去的")。 */
export type RouteAction = "cdp-new-tab" | "roxy-api" | "roxy-launcher" | "fallback-browser";

export interface RouteExecution {
  /** 脱敏后的 URL(query/fragment 已换成 redacted)。 */
  url: string;
  /** 决策词(spec §3 词表,`roxy-cdp:<port>` 带端口)。 */
  decision: string;
  action: RouteAction;
  /** 交给谁:bundle id / .app 路径 / `127.0.0.1:<port>`。 */
  target: string;
  /** 决策的那一级没走通、降下来了吗(母本 `route()` 里那两条 falling back)。 */
  fellBack: boolean;
  /** 这一趟的步骤(已脱敏)。母本写进日志文件的那些话,这里进报文 —— spec §8 不设独立 logPath。 */
  steps: string[];
}

export interface RouteInputs {
  ports: UrlRouterPorts;
  config: UrlRouterConfig;
  /** 用户点的那条 URL 的原文。 */
  url: string;
  /** 已经探过就把结果传进来(`decide` 与 `route` 同一趟调用时省一次 ps/lsof);没传就现探。 */
  decision?: RouteDecision;
}

/** 只决策不执行(能力 `url-router.decide` 与 CLI `route --dry-run` 的落点)。 */
export async function decideRoute(
  ports: UrlRouterPorts,
  config: UrlRouterConfig,
  url: string,
): Promise<RouteDecision> {
  // 端口探测只在**命中分流域名**时才有意义 —— 决策纯函数会先看 scheme 与域名。
  // 但纯函数需要端口作为入参,于是先做一次"不探端口"的决策,只有它落到 Roxy 侧才真去探。
  const withoutPort = decide({ url, config, roxyDevToolsPort: null });
  if (withoutPort.kind !== "roxy-api" && withoutPort.kind !== "roxy-launcher") return withoutPort;
  const port = await findRoxyDevToolsPort(ports, config);
  return decide({ url, config, roxyDevToolsPort: port });
}

/**
 * 决策 + 执行,含母本 `route()` 的降级链:
 *   * `roxy-cdp` 开标签页失败 → 降到 launcher(拉起 .app);
 *   * `roxy-api` 没成 → 同样降到 launcher;
 *   * `fallback-browser` 与 `unsupported` 都交兜底浏览器(母本亦然:动作相同,但报文里分得开)。
 *
 * **降级不是错误**:降下来照样是 ok,`fellBack` 与 `steps` 把发生过什么如实说清。
 * 只有最后那步 `open` 也失败才抛 `UrlRouterOpenError` —— 那才是"链接没打开"。
 */
export async function routeUrl(inputs: RouteInputs): Promise<RouteExecution> {
  const { ports, config, url } = inputs;
  const safeUrl = sanitizeUrlForLog(url);
  const steps: string[] = [];
  const note = (line: string) => steps.push(line);

  const decision = inputs.decision ?? (await decideRoute(ports, config, url));
  const word = decisionWord(decision);
  note(`decision=${word} url=${safeUrl}`);

  const done = (action: RouteAction, target: string, fellBack: boolean): RouteExecution => ({
    url: safeUrl,
    decision: word,
    action,
    target,
    fellBack,
    steps,
  });

  switch (decision.kind) {
    case "fallback-browser":
    case "unsupported": {
      await openWith(ports, "-b", config.fallbackBrowserBundleID, url);
      return done("fallback-browser", config.fallbackBrowserBundleID, false);
    }
    case "roxy-cdp": {
      if (await openInExistingRoxy(ports, decision.port, url)) {
        return done("cdp-new-tab", `127.0.0.1:${decision.port}`, false);
      }
      note(`cdp-failed port=${decision.port},降到 roxy launcher`);
      await openWith(ports, "-a", config.roxyApplicationPath, url);
      return done("roxy-launcher", config.roxyApplicationPath, true);
    }
    case "roxy-api": {
      const port = await openViaRoxyAPI(ports, config, url, note);
      if (port !== null) return done("roxy-api", `127.0.0.1:${port}`, false);
      note("roxy-api-failed,降到 roxy launcher");
      await openWith(ports, "-a", config.roxyApplicationPath, url);
      return done("roxy-launcher", config.roxyApplicationPath, true);
    }
    case "roxy-launcher": {
      await openWith(ports, "-a", config.roxyApplicationPath, url);
      return done("roxy-launcher", config.roxyApplicationPath, false);
    }
  }
}
