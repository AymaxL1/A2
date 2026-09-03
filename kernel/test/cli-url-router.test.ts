// CLI 缝(最高缝):`a2 url-router …`(施工 02 票)。
//
// 这一份验的是**从 argv 到浏览器之间那条完整的路**:argv 改写 → 域别名匹配 → UDS → 注册表仲裁
// → 能力 handler → 执行侧 → `open`。中间任何一环接错,断言就该红。
//
// 红线:`open` / `ps` / `lsof` / `defaults` 全打在 `support/fake-url-router/` 的行为假件上
// (harness 默认把这四个指到一执行就失败的兜底假件,谁忘了注入谁当场红)——
// **门禁永远不会在跑测试的人脸上弹出一个浏览器窗口,也永远不会去读真进程表**。
//
// 这里还有一条别处替不了的断言:交给 `open` 的必须是 **URL 原文、且是独立 argv**。
// 脱敏那份是给报文看的,真开给用户的必须是他点的那一条;而 URL 从不拼进任何字符串、不经 shell,
// 注入面为零 —— 这两件事只有在最外面这条缝上才验得到。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { normalizeUrlRouterArgs } from "../src/cli/url-router.ts";
import {
  KernelSnapshotSchema,
  UrlRouterDecideResultSchema,
  UrlRouterRouteResultSchema,
  UrlRouterStatusResultSchema,
} from "../src/contract/wire.ts";
import { connectFakeClient, type FakeClient } from "./support/fake-client.ts";
import {
  cleanupHome,
  makeHome,
  parseJsonStdout,
  runCli,
  startDaemon,
  stopDaemon,
  type DaemonHandle,
} from "./support/harness.ts";

const FAKES = path.resolve(import.meta.dir, "support/fake-url-router");

let home: string;
let daemon: DaemonHandle | undefined;
let openLog: string;
let clients: FakeClient[] = [];

beforeEach(async () => {
  home = await makeHome();
  openLog = path.join(home, "open.log");
  daemon = undefined;
  clients = [];
});

afterEach(async () => {
  for (const client of clients) await client.close();
  if (daemon) await stopDaemon(daemon);
  await cleanupHome(home);
});

/** 连一个假的"壳"(长连接客户端)并登记进 teardown —— 03 票的快照节与转发路都靠它验。 */
async function fakeShell(name = "fake-panel"): Promise<FakeClient> {
  const client = await connectFakeClient({ socketPath: daemon!.socketPath, name });
  clients.push(client);
  return client;
}

/** 写一份配置文件到 `<A2_HOME>/url-router.json`(内容原样,坏 JSON 也照写)。 */
async function writeConfig(text: string): Promise<void> {
  await writeFile(path.join(home, "url-router.json"), text, "utf8");
}

/** 注入行为假件:`open` 只记 argv 不开东西,`ps` 吐空表(= 本机没跑 Roxy)。 */
function sandboxEnv(overrides: Record<string, string> = {}): Record<string, string> {
  return {
    A2_URL_ROUTER_OPEN: path.join(FAKES, "open"),
    A2_URL_ROUTER_PS: path.join(FAKES, "ps"),
    A2_URL_ROUTER_LSOF: path.join(FAKES, "ps"),
    A2_URL_ROUTER_DEFAULTS: path.join(FAKES, "defaults"),
    A2_URL_ROUTER_OPEN_LOG: openLog,
    ...overrides,
  };
}

async function boot(overrides: Record<string, string> = {}): Promise<Record<string, string>> {
  const env = sandboxEnv(overrides);
  daemon = await startDaemon(home, env);
  return env;
}

/** 假 `open` 记下的那几趟 argv(每趟一组,以 `--` 分隔)。 */
async function openedArgv(): Promise<string[][]> {
  const text = await readFile(openLog, "utf8").catch(() => "");
  const runs: string[][] = [];
  let current: string[] = [];
  for (const line of text.split("\n")) {
    if (line === "--") {
      runs.push(current);
      current = [];
      continue;
    }
    if (line !== "") current.push(line);
  }
  return runs;
}

// MARK: - argv 改写(纯函数,不起 daemon)

test("argv 改写:位置参数 URL → --url;`--dry-run` 换的是**能力**(route → decide)", () => {
  expect(normalizeUrlRouterArgs(["route", "https://claude.ai/x"])).toEqual([
    "route",
    "--url",
    "https://claude.ai/x",
  ]);
  expect(normalizeUrlRouterArgs(["route", "https://claude.ai/x", "--dry-run"])).toEqual([
    "decide",
    "--url",
    "https://claude.ai/x",
  ]);
  // 旗标写在前面也算数(人不会总按文档的顺序敲)。
  expect(normalizeUrlRouterArgs(["route", "--dry-run", "https://claude.ai/x"])).toEqual([
    "decide",
    "--url",
    "https://claude.ai/x",
  ]);
});

test("argv 改写:幂等 —— 已经写成能力原名 + `--url` 的调用过一遍这里一个字都不变", () => {
  expect(normalizeUrlRouterArgs(["decide", "--url", "https://claude.ai/x"])).toEqual([
    "decide",
    "--url",
    "https://claude.ai/x",
  ]);
  // 别的动作原样透传(status / takeover / restore 本来就是 `--名字 值` 那一套)。
  expect(normalizeUrlRouterArgs(["status"])).toEqual(["status"]);
  expect(normalizeUrlRouterArgs(["restore", "--to", "com.apple.Safari"])).toEqual([
    "restore",
    "--to",
    "com.apple.Safari",
  ]);
  expect(normalizeUrlRouterArgs([])).toEqual([]);
});

test("argv 改写:多给的位置参数**不吃掉**,原样传下去让通用解析器报用法错", () => {
  expect(normalizeUrlRouterArgs(["route", "https://a.example", "https://b.example"])).toEqual([
    "route",
    "--url",
    "https://a.example",
    "https://b.example",
  ]);
});

test("argv 改写:长得像位置参数的 `--url` 值不会被再包一层", () => {
  expect(normalizeUrlRouterArgs(["route", "--url", "https://claude.ai/x", "--dry-run"])).toEqual([
    "decide",
    "--url",
    "https://claude.ai/x",
  ]);
});

// MARK: - 帮助与用法错(不经 daemon)

test("`a2 url-router --help` 给的是这个域自己的用法,含五条写法与决策词表", async () => {
  const result = await runCli(["url-router", "--help", "--json"], { home });

  expect(result.exitCode).toBe(0);
  const usage = parseJsonStdout(result).result.usage as string;
  expect(usage).toContain("a2 [--json] url-router route <url> --dry-run");
  expect(usage).toContain("roxy-cdp:<port>");
  expect(usage).toContain("takeover");
});

// MARK: - 经 daemon 的能力面

test("capabilities list 里五条都在,风险档逐条对上(dangerous 那两条尤其)", async () => {
  await boot();

  const listed = parseJsonStdout(await runCli(["capabilities", "list", "--json"], { home }));
  const byId = new Map(
    (listed.result.capabilities as { id: string; risk: string }[]).map((c) => [c.id, c.risk]),
  );

  expect(byId.get("url-router.status")).toBe("safe");
  expect(byId.get("url-router.decide")).toBe("safe");
  expect(byId.get("url-router.route")).toBe("normal");
  expect(byId.get("url-router.takeover")).toBe("dangerous");
  expect(byId.get("url-router.restore")).toBe("dangerous");
});

test("`url-router status`:没有配置文件就报全缺省,handler 读不出来如实说未能判定", async () => {
  const env = await boot();

  const result = await runCli(["url-router", "status", "--json"], { home, env });

  expect(result.exitCode).toBe(0);
  const parsed = UrlRouterStatusResultSchema.parse(parseJsonStdout(result).result.output);
  expect(parsed.configSource).toBe("defaults");
  expect(parsed.handler.matchesTarget).toBeNull();
  expect(parsed.panelBundleID).toBe("com.a2.panel");
});

test("`url-router route <url> --dry-run`:只判不开 —— 一趟 open 都没发生", async () => {
  const env = await boot();

  const result = await runCli(
    ["url-router", "route", "https://example.com/a?t=1#f", "--dry-run", "--json"],
    { home, env },
  );

  expect(result.exitCode).toBe(0);
  const parsed = UrlRouterDecideResultSchema.parse(parseJsonStdout(result).result.output);
  expect(parsed.decision).toBe("fallback-browser");
  expect(parsed.url).toBe("https://example.com/a?redacted#redacted");
  expect(await openedArgv()).toEqual([]);
});

test("`url-router route <url>`:没命中 → `open -b <兜底浏览器> <url 原文>`,URL 是独立 argv", async () => {
  const env = await boot();
  // query 里有空格与 `&`,fragment 里有中文 —— 拼进 shell 会当场散架,独立 argv 则毫发无伤。
  const url = "https://example.com/a?q=hello world&x=1#片段";

  const result = await runCli(["url-router", "route", url, "--json"], { home, env });

  expect(result.exitCode).toBe(0);
  const parsed = UrlRouterRouteResultSchema.parse(parseJsonStdout(result).result.output);
  expect(parsed.action).toBe("fallback-browser");
  expect(parsed.fellBack).toBe(false);
  // 交给 open 的是**原文**;报文里那份才是脱敏的。
  expect(await openedArgv()).toEqual([["-b", "com.apple.Safari", url]]);
  expect(parsed.url).toBe("https://example.com/a?redacted#redacted");
  expect(result.stdout).not.toContain("hello world");
});

test("`url-router route <url>`:命中分流域名 + Roxy 没跑 + API 没配 → 拉起 Roxy 的 .app", async () => {
  const env = await boot();

  const result = await runCli(["url-router", "route", "https://claude.ai/chat", "--json"], {
    home,
    env,
  });

  expect(result.exitCode).toBe(0);
  const parsed = UrlRouterRouteResultSchema.parse(parseJsonStdout(result).result.output);
  expect(parsed.decision).toBe("roxy-launcher");
  expect(parsed.action).toBe("roxy-launcher");
  expect(await openedArgv()).toEqual([
    ["-a", "/Applications/RoxyBrowser.app", "https://claude.ai/chat"],
  ]);
});

test("`url-router route`:open 非零退出 → url_router_open_failed,退出码 5(而不是报「打开了」)", async () => {
  const env = await boot({ A2_URL_ROUTER_OPEN_EXIT: "1" });

  const result = await runCli(["url-router", "route", "https://example.com/a", "--json"], {
    home,
    env,
  });

  expect(result.exitCode).toBe(5);
  const envelope = parseJsonStdout(result);
  expect(envelope.ok).toBe(false);
  expect(envelope.error.code).toBe("url_router_open_failed");
  expect(envelope.error.guidance).toBeTruthy();
});

test("`url-router takeover`:dangerous 档,无确认器在场即 fail-closed 默拒(退出码 2)", async () => {
  const env = await boot();

  const result = await runCli(["url-router", "takeover", "--json"], { home, env });

  expect(result.exitCode).toBe(2);
  const envelope = parseJsonStdout(result);
  expect(envelope.error.code).toBe("confirmation_unavailable");
  // 被拒时 handler **一次都没被碰到**:一趟 open、一次 defaults 都没有发生。
  expect(await openedArgv()).toEqual([]);
});

test("`url-router restore --to …`:dangerous 的仲裁**排在 handler 之前** —— 参数怎么写都先被默拒", async () => {
  const env = await boot();

  // `--to` 写成空白串:这是 handler 会拒的参数(单测里验过 invalid_params)。
  // 但经这条缝进来时,**handler 根本不会被碰到** —— 无确认器在场,dangerous 先默拒。
  // 这个顺序是安全语义的一部分:参数合不合法轮不到一条被拒的调用去操心。
  const result = await runCli(["url-router", "restore", "--to", "   ", "--json"], { home, env });

  expect(result.exitCode).toBe(2);
  expect(parseJsonStdout(result).error.code).toBe("confirmation_unavailable");
});

test("两种写法同一条路:`url-router route <url> --dry-run` ≡ `capabilities call url-router.decide`", async () => {
  const env = await boot();
  const url = "https://claude.ai/chat?x=1";

  const viaDomain = parseJsonStdout(
    await runCli(["url-router", "route", url, "--dry-run", "--json"], { home, env }),
  );
  const viaCapability = parseJsonStdout(
    await runCli(
      ["capabilities", "call", "url-router.decide", "--input", JSON.stringify({ url }), "--json"],
      { home, env },
    ),
  );

  expect(viaDomain.result.output).toEqual(viaCapability.result.output);
});

// MARK: - 快照的 urlRouter 节 + 壳那条转发路(03 票,spec §6.1/§6.2)
//
// 这一族验的是**壳降级兜底的唯一知识来源**:内核推来的快照。四条硬边界的第④条
// (「配置知识只来自内核推送快照,永不读内核文件」)只有在这里成立,壳那侧才配不读 `~/.a2`。

test("03 注册即快照:带 urlRouter 节,没有配置文件时给缺省兜底浏览器", async () => {
  await boot();
  const shell = await fakeShell();

  const registered = await shell.register("confirm-agent");

  expect(KernelSnapshotSchema.safeParse(registered.snapshot).success).toBe(true);
  expect(registered.snapshot.urlRouter).toEqual({ fallbackBrowserBundleID: "com.apple.Safari" });
  // **这一节只有一个字段**:分流域名表与 Roxy 那一族(含敏感的 roxyAPIKey)一个都不来 ——
  // 壳不做决策,多给一个字段就是多给一次"壳自己判一下"的机会(spec §6.2 的最小集)。
  expect(Object.keys(registered.snapshot.urlRouter)).toEqual(["fallbackBrowserBundleID"]);
  // 现读磁盘没有破掉「快照是这条连接的第一帧」:第一帧仍是注册响应,不是推送。
  expect(shell.arrivals[0]).toBe("response");
}, 20000);

test("03 快照的 urlRouter 节是**现读**的:daemon 起来之后才写的配置照样算数", async () => {
  await boot();
  // daemon 已经在跑了才写配置 —— 没有文件监视,也不该有缓存:下一次建全量快照时现读。
  await writeConfig(JSON.stringify({ fallbackBrowserBundleID: "com.google.Chrome" }));

  const registered = await (await fakeShell()).register("subscriber");

  expect(registered.snapshot.urlRouter.fallbackBrowserBundleID).toBe("com.google.Chrome");
}, 20000);

test("03 配置文件坏了:快照照样给一个非空兜底身份(整份退回缺省,壳永远拿得到)", async () => {
  await boot();
  await writeConfig("{ 这不是 JSON");

  const registered = await (await fakeShell()).register("subscriber");

  // 「配歪了」这件事由 `url-router.status` 指名道姓地说;快照这一节的职责只有一个 ——
  // 让壳在内核不可达时手里有个打得开的兜底(所以它宁可是缺省,也不能是空)。
  expect(registered.snapshot.urlRouter.fallbackBrowserBundleID).toBe("com.apple.Safari");
  const status = parseJsonStdout(await runCli(["url-router", "status", "--json"], { home }));
  expect(status.result.output.configSource).toBe("unusable");
}, 20000);

test("03 壳那条转发路:经 UDS `capabilities.call url-router.route` 开的是 URL 原文", async () => {
  const env = await boot();
  const shell = await fakeShell();
  await shell.register("confirm-agent");
  const url = "https://example.com/a?q=hello world&x=1#片段";

  // 壳与 CLI 走**同一条能力面**(spec §6.1「转发零新帧」):这里发的就是壳会发的那一条报文。
  const response = await shell.request("capabilities.call", {
    capability: "url-router.route",
    input: { url },
  });

  expect(response.ok).toBe(true);
  expect(UrlRouterRouteResultSchema.safeParse(response.result.output).success).toBe(true);
  expect(response.result.output.action).toBe("fallback-browser");
  // 交给 open 的是原文、且是独立 argv(壳原样转发,内核原样交出去,中间没有人改写)。
  expect(await openedArgv()).toEqual([["-b", "com.apple.Safari", url]]);
  // 报文里那份是脱敏的:壳的日志纪律再松,也拿不到 query/fragment 的原文。
  expect(response.result.output.url).toBe("https://example.com/a?redacted#redacted");
}, 20000);

test("未知动作:报用法错(退出码 1)并把这个域现有的写法列出来", async () => {
  await boot();

  const result = await runCli(["url-router", "冲鸭", "--json"], { home });

  expect(result.exitCode).toBe(1);
  const envelope = parseJsonStdout(result);
  expect(envelope.error.code).toBe("usage");
  expect(envelope.error.detail ?? envelope.error.message).toContain("url-router");
});
