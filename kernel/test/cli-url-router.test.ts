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
import {
  EXECUTION_TIMEOUT_ENV,
  LAUNCH_WAIT_ENV,
} from "../src/daemon/url-router-executor.ts";
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

test("`url-router takeover`:没有执行器在场 → 拉一把壳、等不到就 confirmation_unavailable(退出码 2)", async () => {
  // 拉起等待窗压到 50ms:这条路真实要等 10 秒,而它等的东西(壳注册上来)在门禁里永远不会发生。
  const env = await boot({ [LAUNCH_WAIT_ENV]: "50" });

  const result = await runCli(["url-router", "takeover", "--json"], { home, env });

  expect(result.exitCode).toBe(2);
  const envelope = parseJsonStdout(result);
  expect(envelope.ok).toBe(false);
  // **不造新码**:确认换了个地方(系统弹框),但"没人能替你确认"对 agent 意味着什么一个字没变。
  expect(envelope.error.code).toBe("confirmation_unavailable");
  // 拒绝即指引:既给装壳那条路,也给不装壳也能干成的那条(系统设置里手选)。
  expect(JSON.stringify(envelope.error.guidance)).toContain("系统设置");

  // 04 票起这条路上**确实会 `open -b com.a2.panel`**(拉壳是用户显式变更里的一步,
  // 不违「永不隐式拉起」——那条管的是查询)。除此之外一趟 open 都不该有:URL 一个都没开。
  expect(await openedArgv()).toEqual([["-b", "com.a2.panel"]]);
});

test("`url-router takeover`:`open -b` 非零退出 = 壳没装,如实报出来(不发明第二套探测)", async () => {
  const env = await boot({ A2_URL_ROUTER_OPEN_EXIT: "1", [LAUNCH_WAIT_ENV]: "50" });

  const result = await runCli(["url-router", "takeover", "--json"], { home, env });

  expect(result.exitCode).toBe(2);
  const envelope = parseJsonStdout(result);
  expect(envelope.error.code).toBe("confirmation_unavailable");
  expect(envelope.error.message).toContain("com.a2.panel");
  // 报文里带着 `open` 自己的退出码 —— 判据就是它,没有别的探测。
  expect(envelope.error.detail).toContain("退出码 1");
});

test("`url-router restore --to …`:os-dialog 档**不经 confirm-agent 仲裁**,参数照旧先校验", async () => {
  const env = await boot({ [LAUNCH_WAIT_ENV]: "50" });

  // 02 票时这条命令会先撞上 dangerous 默拒(exit 2),因为它走 confirm-agent 那三层。
  // 04 票起 takeover/restore 标了 `confirmation: "os-dialog"` —— 那三层**按设计跳过**
  // (它们的确认由系统弹框承载,叠一层就是双确认),于是空白串 `--to` 由 handler 如实拒掉。
  // **这不是把闸拆了**:它们照样是 dangerous,照样一步都改不动系统状态而不经 OS 弹框;
  // 别的 dangerous 能力的默拒行为一个字都没变(下一条断言正是冲它去的)。
  const result = await runCli(["url-router", "restore", "--to", "   ", "--json"], { home, env });

  expect(result.exitCode).toBe(6);
  expect(parseJsonStdout(result).error.code).toBe("invalid_params");
  // 参数就没过,当然一趟 open 都没有(连拉壳都没轮到)。
  expect(await openedArgv()).toEqual([]);
});

test("**别的 dangerous 能力一个字都没变**:代理面照旧无确认器即 fail-closed 默拒(退出码 2)", async () => {
  const env = await boot();

  // 同一个内核、同一条缝,只是换一条**没标 os-dialog** 的 dangerous 能力。
  // 04 票那条岔路若不小心开给了全体 dangerous,这一条会当场红。
  const result = await runCli(["capabilities", "call", "demo.wipe", "--json"], { home, env });

  expect(result.exitCode).toBe(2);
  expect(parseJsonStdout(result).error.code).toBe("confirmation_unavailable");
});

// MARK: - 执行指令帧的整条链(04 票,spec §5/§6.3)
//
// 这一族是本票唯一验得到「argv → UDS → 仲裁岔路 → 编排 → 推送 → 壳 → 回执 → 报文」全程的地方。
// 假壳站在真壳的位置上,但它手里**没有系统 API** —— 于是门禁永远不会真改这台机器的默认浏览器。

/** 连一个假的**机械执行器**(注册 url-router-executor 角色,照剧本回执行结果)。 */
async function fakeExecutor(executeBehavior: "confirmed" | "denied" | "partial" | "ignore") {
  const client = await connectFakeClient({
    socketPath: daemon!.socketPath,
    name: "fake-executor",
    executeBehavior,
  });
  clients.push(client);
  await client.register("url-router-executor");
  return client;
}

test("takeover 全程:执行器在场 → 下发指令帧 → 回执 confirmed → ok(且**没有拉壳**,它已经在了)", async () => {
  const env = await boot();
  const executor = await fakeExecutor("confirmed");

  const result = await runCli(["url-router", "takeover", "--json"], { home, env });

  expect(result.exitCode).toBe(0);
  const output = parseJsonStdout(result).result.output;
  expect(output.target).toBe("com.a2.panel");
  expect(output.already).toBe(false);
  expect(output.outcome).toBe("confirmed");
  expect(output.perScheme).toEqual({ http: { ok: true }, https: { ok: true } });

  // 指令确实落到了执行器手上,而且**只回了一次**。
  expect(executor.executed).toHaveLength(1);
  const command = executor.events("url-router-execute")[0]?.command;
  expect(command).toMatchObject({
    op: "set-default-handler",
    schemes: ["http", "https"],
    bundleID: "com.a2.panel",
    timeoutSeconds: 120,
  });
  // 执行器已经在场 → **一趟 `open` 都没有**(拉壳只发生在它不在的时候)。
  expect(await openedArgv()).toEqual([]);
});

test("takeover:用户点取消 → confirmation_denied(退出码 2),报文说清是人不同意", async () => {
  const env = await boot();
  await fakeExecutor("denied");

  const result = await runCli(["url-router", "takeover", "--json"], { home, env });

  expect(result.exitCode).toBe(2);
  const envelope = parseJsonStdout(result);
  expect(envelope.error.code).toBe("confirmation_denied");
  expect(envelope.error.detail).toContain("取消");
  expect(envelope.error.guidance).toBeTruthy();
});

test("takeover:一个 scheme 成一个没成 → url_router_partial_takeover(5)+ 补齐命令", async () => {
  const env = await boot();
  await fakeExecutor("partial");

  const result = await runCli(["url-router", "takeover", "--json"], { home, env });

  expect(result.exitCode).toBe(5);
  const envelope = parseJsonStdout(result);
  expect(envelope.error.code).toBe("url_router_partial_takeover");
  expect(envelope.error.guidance.context.succeeded).toBe("http");
  expect(envelope.error.guidance.context.failed).toBe("https");
});

test("takeover:执行器在场却一个字都不回 → 等满窗口即 confirmation_timeout(3),沉默不是成功", async () => {
  // 120s 的窗压到 300ms:验的是"等满了会怎么样",不是"能不能等 120 秒"。
  const env = await boot({ [EXECUTION_TIMEOUT_ENV]: "300" });
  await fakeExecutor("ignore");

  const result = await runCli(["url-router", "takeover", "--json"], { home, env });

  expect(result.exitCode).toBe(3);
  const envelope = parseJsonStdout(result);
  expect(envelope.error.code).toBe("confirmation_timeout");
  // 「稍后核实」——用户晚点才点也算数,所以指引不是"再发一次"。
  expect(
    envelope.error.guidance.steps.some(
      (step: { command?: string }) => step.command === "a2 url-router status --json",
    ),
  ).toBe(true);
});

test("执行指令帧**只推给执行器**:确认器/订阅者一帧都收不到(与 confirmation 同一条纪律)", async () => {
  const env = await boot({ [EXECUTION_TIMEOUT_ENV]: "300" });
  const subscriber = await fakeShell("fake-subscriber");
  await subscriber.register("subscriber");
  const confirmer = await fakeShell("fake-confirmer");
  await confirmer.register("confirm-agent");
  const executor = await fakeExecutor("confirmed");

  await runCli(["url-router", "takeover", "--json"], { home, env });

  expect(executor.events("url-router-execute")).toHaveLength(1);
  expect(subscriber.events("url-router-execute")).toHaveLength(0);
  expect(confirmer.events("url-router-execute")).toHaveLength(0);
});

test("没注册执行器角色就想回执行结果 → role_not_registered(角色是连接的属性,不是自称)", async () => {
  await boot();
  const impostor = await fakeShell("fake-impostor");
  // 注册的是**确认器**:能替人做决定,但没有回报执行结果的资格 —— 两把锁是分开的。
  await impostor.register("confirm-agent");

  const response = await impostor.request("url-router.executor.report", {
    execution: "随便编一个 id",
    outcome: "confirmed",
    perScheme: { http: { ok: true }, https: { ok: true } },
  });

  expect(response.ok).toBe(false);
  expect(response.error.code).toBe("role_not_registered");
});

test("执行器回一条内核没在等的回执 → url_router_execution_unknown(退出码 6)", async () => {
  await boot();
  const executor = await fakeExecutor("ignore");

  const response = await executor.request("url-router.executor.report", {
    execution: "从来没有过的 id",
    outcome: "confirmed",
    perScheme: {},
  });

  expect(response.ok).toBe(false);
  expect(response.error.code).toBe("url_router_execution_unknown");
  expect(response.error.guidance).toBeTruthy();
});

test("执行器角色的进出**照样留痕**(执行器什么时候在,是接管能不能走通的运行时事实)", async () => {
  await boot();
  const subscriber = await fakeShell("fake-subscriber");
  await subscriber.register("subscriber");

  const executor = await fakeExecutor("confirmed");
  await subscriber.waitForEvent(
    (event) => event.kind === "audit" && event.audit.action === "executor_joined",
  );

  await executor.close();
  await subscriber.waitForEvent(
    (event) => event.kind === "audit" && event.audit.action === "executor_left",
  );
});

test("`capabilities list`:确认模式标记进机读面 —— os-dialog **恰好**是 takeover/restore 两条", async () => {
  const env = await boot();

  const listed = parseJsonStdout(
    await runCli(["capabilities", "list", "--json"], { home, env }),
  ).result.capabilities as { id: string; risk: string; confirmation?: string }[];

  const osDialog = listed.filter((entry) => entry.confirmation === "os-dialog").map((entry) => entry.id);
  expect(osDialog.sort()).toEqual(["url-router.restore", "url-router.takeover"]);

  // 反面:别的 dangerous 能力 manifest 上**根本没有这个字段**(缺省即 confirm-agent)。
  const otherDangerous = listed.filter(
    (entry) => entry.risk === "dangerous" && !entry.id.startsWith("url-router."),
  );
  expect(otherDangerous.length).toBeGreaterThan(0);
  for (const entry of otherDangerous) expect(entry.confirmation).toBeUndefined();
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
