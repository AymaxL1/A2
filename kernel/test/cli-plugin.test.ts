// CLI 缝:插件宿主(11 票)—— `a2 plugin add|list|remove` 与「插件工具经统一调用面被调用」。
//
// 被测的是**北极星那条路**:agent 现场写一个零依赖单文件 `.ts` → 装上 → 立刻经 CLI 调用。
// 所以这里的插件全是测试**当场写出来的文件**(不是仓库里的固定装置):要验的正是"现场写的东西能不能用"。
//
// 断言全在外部可观察面上:stdout 的那条 JSON 包封、退出码、审计日志、推给长连接的事件、
// 以及插件自己回报的进程事实(pid / 环境变量)—— 最后这一条是「插件在进程外、能力只经协议白名单」
// 这条红线(ADR 0011)的活体证据,也是 10 票交接单点名要 11 票立的那条结构断言的新载体。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, readdirSync, realpathSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { BUILTIN_CAPABILITIES } from "../src/capability/builtin.ts";
import { pluginCommand, pluginEnv } from "../src/plugin/protocol.ts";
import { CAPABILITY_NAMESPACE } from "../src/plugin/store.ts";
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

let home: string;
let workspace: string;
let daemon: DaemonHandle | undefined;
let clients: FakeClient[] = [];

beforeEach(async () => {
  home = await makeHome();
  // agent 写插件的地方**不是** A2_HOME:登记区是内核自己的,源文件在别处 ——
  // 「add 会把工件复制进登记区」这件事只有在两者分开时才验得出来。
  workspace = path.join(home, "..", path.basename(home).replace("a2t-", "a2w-"));
  await mkdir(workspace, { recursive: true });
  daemon = undefined;
  clients = [];
});

afterEach(async () => {
  for (const client of clients) await client.close();
  if (daemon) await stopDaemon(daemon);
  await cleanupHome(home);
  await cleanupHome(workspace);
});

async function fakeClient(options: { behavior?: "approve" | "deny" | "ignore" } = {}) {
  const client = await connectFakeClient({ socketPath: daemon!.socketPath, ...options });
  clients.push(client);
  return client;
}

/** 现场写一个插件文件,返回它的绝对路径。 */
async function writePlugin(name: string, source: string): Promise<string> {
  const file = path.join(workspace, `${name}.ts`);
  await writeFile(file, source, "utf8");
  return file;
}

const registryDir = () => path.join(home, "plugins");

// MARK: - 现场写的插件们
//
// 每一份都短到能一眼读完 —— 它们同时是「插件协议长什么样」的活体样例(`a2 plugin --help` 里印的是同一套)。

/**
 * 主样例:一个 normal 工具 + 一个 dangerous 工具。
 * `greet` 顺带回报三件**只有子进程才知道**的事实:自己的 pid、拿到的 `A2_*` 环境变量、cwd。
 */
const HELLO = `
const TOOLS = [
  { name: "greet", summary: "打个招呼", dangerous: false,
    parameters: [
      { name: "who", type: "string", required: true, description: "跟谁打招呼" },
      { name: "loud", type: "boolean", required: false, description: "要不要喊" },
    ] },
  { name: "wipe", summary: "假装擦掉点什么(dangerous 声明)", dangerous: true,
    parameters: [{ name: "target", type: "string", required: false, description: "假想目标" }] },
];
const mode = process.argv[2];
if (mode === "describe") {
  console.log(JSON.stringify({ protocol: 1, name: "hello", tools: TOOLS }));
  process.exit(0);
}
if (mode === "call") {
  const req = JSON.parse(await Bun.stdin.text());
  if (req.tool === "greet") {
    console.error("这一行是 stderr —— 它绝不该出现在 stdout 上");
    console.log(JSON.stringify({ ok: true, output: {
      hello: req.input.who,
      loud: req.input.loud === true,
      pid: process.pid,
      a2env: Object.keys(process.env).filter((k) => k.startsWith("A2_")),
      cwd: process.cwd(),
    } }));
    process.exit(0);
  }
  if (req.tool === "wipe") {
    console.log(JSON.stringify({ ok: true, output: { wiped: true, target: req.input.target ?? null } }));
    process.exit(0);
  }
  console.log(JSON.stringify({ ok: false, error: { message: "未知工具" } }));
  process.exit(4);
}
process.exit(2);
`;

/** 四种失败收场各一个工具(退出码词表的活体样本)。 */
const MISBEHAVING = `
const TOOLS = ["fail", "crash", "lost", "slow"].map((name) => ({
  name, summary: name + " 的收场", dangerous: false, parameters: [],
}));
const mode = process.argv[2];
if (mode === "describe") {
  console.log(JSON.stringify({ protocol: 1, tools: TOOLS }));
  process.exit(0);
}
if (mode === "call") {
  const req = JSON.parse(await Bun.stdin.text());
  if (req.tool === "fail") {
    console.log(JSON.stringify({ ok: false, error: { message: "这件事没办成", detail: "插件自己给的细节" } }));
    process.exit(3);
  }
  if (req.tool === "crash") { throw new Error("插件里有个没接住的异常"); }
  if (req.tool === "lost") {
    console.log(JSON.stringify({ ok: false, error: { message: "我没有这个工具" } }));
    process.exit(4);
  }
  if (req.tool === "slow") { await Bun.sleep(30000); process.exit(0); }
}
process.exit(2);
`;

/** 二级插件:用来验命名空间(两个插件可以有同名工具)。 */
const OTHER = `
const mode = process.argv[2];
if (mode === "describe") {
  console.log(JSON.stringify({ protocol: 1, tools: [
    { name: "greet", summary: "另一个插件的同名工具", dangerous: false, parameters: [] },
  ] }));
  process.exit(0);
}
if (mode === "call") {
  console.log(JSON.stringify({ ok: true, output: { from: "other" } }));
  process.exit(0);
}
process.exit(2);
`;

async function addHello(extra: string[] = []) {
  const file = await writePlugin("hello", HELLO);
  return await runCli(["plugin", "add", file, ...extra, "--json"], { home });
}

async function capabilityIds(): Promise<string[]> {
  const body = parseJsonStdout(await runCli(["capabilities", "list", "--json"], { home }));
  return (body.result.capabilities as { id: string }[]).map((capability) => capability.id);
}

async function auditActions(): Promise<string[]> {
  const raw = await readFile(path.join(home, "log", "arbitration.log"), "utf8");
  return raw
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line).action as string);
}

// MARK: - describe 约定

test("add:现场写的零依赖单文件 .ts 当场登记生效,describe 的清单原样成为 manifest", async () => {
  daemon = await startDaemon(home);

  const added = await addHello();

  expect(added.exitCode).toBe(0);
  const body = parseJsonStdout(added);
  expect(body.ok).toBe(true);
  expect(body.result.action).toBe("added");
  // 工件被**复制进登记区**:源文件从此与内核无关(改它不会偷偷生效)。
  expect(body.result.plugin.artifact).toBe(path.join(registryDir(), "hello.ts"));
  expect(body.result.plugin.source).toBe(path.join(workspace, "hello.ts"));
  expect(existsSync(body.result.plugin.artifact)).toBe(true);

  // dangerous 声明 → dangerous 档;没声明 → normal(**不是 safe**:内核无从知道插件工具是不是只读)。
  const descriptors = body.result.added as { id: string; risk: string; parameters: unknown[] }[];
  expect(descriptors.map((d) => d.id)).toEqual(["plugin.hello.greet", "plugin.hello.wipe"]);
  expect(descriptors.map((d) => d.risk)).toEqual(["normal", "dangerous"]);
  // 参数声明**逐字**进 manifest(ParameterSpec 是纯数据,插件与内置能力用的是同一套)。
  expect(descriptors[0]!.parameters).toEqual([
    { name: "who", type: "string", required: true, description: "跟谁打招呼" },
    { name: "loud", type: "boolean", required: false, description: "要不要喊" },
  ]);
});

test("统一暴露:插件工具与内置能力在同一张 capabilities 表上,describe 也答得出", async () => {
  daemon = await startDaemon(home);
  await addHello();

  const ids = await capabilityIds();
  expect(ids).toContain("demo.echo"); // 内置的位置没被插件挤掉
  expect(ids).toContain("plugin.hello.greet");
  // 插件排在最后:装插件不会让既有能力的顺序变(agent 的 diff 才稳)。
  expect(ids.slice(-2)).toEqual(["plugin.hello.greet", "plugin.hello.wipe"]);

  const described = parseJsonStdout(
    await runCli(["capabilities", "describe", "plugin.hello.wipe", "--json"], { home }),
  );
  expect(described.result.descriptor.risk).toBe("dangerous");
  expect(described.result.descriptor.summary).toBe("假装擦掉点什么(dangerous 声明)");
});

test("describe 输出不是合法 JSON:结构化错误 + 指引,且**一个字节都不登记**", async () => {
  daemon = await startDaemon(home);
  const file = await writePlugin("broken", `
    if (process.argv[2] === "describe") { console.log("这不是 JSON"); process.exit(0); }
    process.exit(2);
  `);

  const result = await runCli(["plugin", "add", file, "--json"], { home });

  expect(result.exitCode).toBe(6); // 插件说的话不合协议 = 协议错档
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("plugin_protocol_error");
  expect(body.error.guidance.steps.some((s: any) => s.command === "a2 plugin --help")).toBe(true);
  // 没登记:清单空、登记区里连暂存文件都没留下(失败即清场)。
  expect(parseJsonStdout(await runCli(["plugin", "list", "--json"], { home })).result.plugins).toEqual([]);
  expect(readdirSync(registryDir()).filter((name) => name.startsWith(".staging"))).toEqual([]);
  expect(await capabilityIds()).not.toContain("plugin.broken.anything");
});

test("describe 缺字段(一个工具都没有)→ 拒装,报文里指着协议形状说话", async () => {
  daemon = await startDaemon(home);
  const file = await writePlugin("hollow", `
    if (process.argv[2] === "describe") {
      console.log(JSON.stringify({ protocol: 1, tools: [] }));
      process.exit(0);
    }
    process.exit(2);
  `);

  const result = await runCli(["plugin", "add", file, "--json"], { home });

  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("plugin_protocol_error");
  expect(body.error.message).toContain("不符合插件协议");
});

test("describe 超时:插件被杀,报文是 plugin_timeout(fail-closed,不等不猜)", async () => {
  // 超时窗口注入给 **daemon**:插件子进程是它起的。
  daemon = await startDaemon(home, { A2_PLUGIN_TIMEOUT_MS: "400" });
  const file = await writePlugin("sleepy", `
    if (process.argv[2] === "describe") { await Bun.sleep(30000); }
    process.exit(0);
  `);

  const result = await runCli(["plugin", "add", file, "--json"], { home });

  expect(result.exitCode).toBe(5); // 事没办成(**不是 3** —— 3 的语义是「人没点」,见 exit-codes.ts)
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("plugin_timeout");
  expect(body.error.message).toContain("400ms");
});

// MARK: - call 约定与退出码语义

test("call:参数 stdin 进、结果 stdout 出;插件写 stderr 不污染机读面", async () => {
  daemon = await startDaemon(home);
  await addHello();

  const result = await runCli(
    ["capabilities", "call", "plugin.hello.greet", "--input", '{"who":"a2","loud":true}', "--json"],
    { home },
  );

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result); // stdout 能一次 parse = 没被 stderr 掺进来
  expect(body.result.capability).toBe("plugin.hello.greet");
  expect(body.result.output.hello).toBe("a2");
  expect(body.result.output.loud).toBe(true);
});

test("退出码语义固定:3 业务失败 / 1 未捕获异常 / 4 未知工具,各映射各的错误码", async () => {
  daemon = await startDaemon(home);
  const file = await writePlugin("bad", MISBEHAVING);
  expect((await runCli(["plugin", "add", file, "--json"], { home })).exitCode).toBe(0);

  // 3:执行了、业务上失败了 —— 与内置能力的业务失败同一档(退出码 5),插件自己的话原样传回。
  const failed = await runCli(["capabilities", "call", "plugin.bad.fail", "--json"], { home });
  expect(failed.exitCode).toBe(5);
  const failedBody = parseJsonStdout(failed);
  expect(failedBody.error.code).toBe("capability_failed");
  expect(failedBody.error.message).toBe("这件事没办成");
  expect(failedBody.error.detail).toBe("插件自己给的细节");

  // 1(Bun 的未捕获异常):没跑成;栈在 stderr 里,内核把它收进 detail。
  const crashed = await runCli(["capabilities", "call", "plugin.bad.crash", "--json"], { home });
  expect(crashed.exitCode).toBe(5);
  const crashedBody = parseJsonStdout(crashed);
  expect(crashedBody.error.code).toBe("plugin_failed");
  expect(crashedBody.error.detail).toContain("插件里有个没接住的异常");

  // 4:清单说有、实现说没有 —— 要改的是插件,所以归协议错。
  const lost = await runCli(["capabilities", "call", "plugin.bad.lost", "--json"], { home });
  expect(lost.exitCode).toBe(6);
  expect(parseJsonStdout(lost).error.code).toBe("plugin_protocol_error");
});

test("call 超时:插件被杀,agent 拿到 plugin_timeout 而不是永远等下去", async () => {
  daemon = await startDaemon(home, { A2_PLUGIN_TIMEOUT_MS: "400" });
  const file = await writePlugin("bad", MISBEHAVING);
  await runCli(["plugin", "add", file, "--json"], { home });

  const result = await runCli(["capabilities", "call", "plugin.bad.slow", "--json"], { home });

  expect(result.exitCode).toBe(5);
  expect(parseJsonStdout(result).error.code).toBe("plugin_timeout");
});

test("参数校验仍归内核:缺必填参数时报 missing_parameter(插件不必自己校验)", async () => {
  daemon = await startDaemon(home);
  await addHello();

  const result = await runCli(["capabilities", "call", "plugin.hello.greet", "--json"], { home });

  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("missing_parameter");
  // 指引指向的是**能力面**的自纠命令 —— 插件工具在这一层与内置能力没有区别。
  expect(body.error.guidance.steps[0].command).toBe("a2 capabilities describe plugin.hello.greet --json");
});

// MARK: - 装载零闸 + 审计 + 能力全集增量

test("装载零闸:一个确认器都没有时 add 照样成功,但审计留痕跑不掉", async () => {
  daemon = await startDaemon(home);

  // 同一时刻、同一台内核:dangerous **调用**被默拒,而**装载**畅通无阻 —— 这就是 ADR 0011 那条裁决。
  const denied = await runCli(["capabilities", "call", "demo.wipe", "--json"], { home });
  expect(denied.exitCode).toBe(2);

  const added = await addHello();
  expect(added.exitCode).toBe(0);

  expect(await auditActions()).toContain("plugin_added");
  const arbitration = parseJsonStdout(await runCli(["arbitration", "status", "--json"], { home }));
  const events = arbitration.result.output.events as { action: string; detail?: string }[];
  const record = events.find((event) => event.action === "plugin_added");
  expect(record).toBeDefined();
  expect(record!.detail).toContain("plugin.hello.greet");
});

test("能力全集变了要推增量:订阅者收到 capability-set 事件(带全集,拿到就整份替换)", async () => {
  daemon = await startDaemon(home);
  const subscriber = await fakeClient();
  const snapshot = await subscriber.register("subscriber");
  const before = (snapshot.snapshot.capabilities as { id: string }[]).map((c) => c.id);
  expect(before).not.toContain("plugin.hello.greet");

  await addHello();

  const event = await subscriber.waitForEvent((e) => e.kind === "capability-set");
  expect(event.capabilities.action).toBe("added");
  expect(event.capabilities.plugin).toBe("hello");
  expect((event.capabilities.added as { id: string }[]).map((c) => c.id)).toEqual([
    "plugin.hello.greet",
    "plugin.hello.wipe",
  ]);
  expect(event.capabilities.removed).toEqual([]);
  // 全集 = 变化后的整张表(客户端不必自己做加减法)。
  const full = (event.capabilities.capabilities as { id: string }[]).map((c) => c.id);
  expect(full).toEqual([...before, "plugin.hello.greet", "plugin.hello.wipe"]);

  // 同一次变化也落审计:两条事件各答各的("谁装的" vs "现在能调什么")。
  const audit = await subscriber.waitForEvent(
    (e) => e.kind === "audit" && e.audit.action === "plugin_added",
  );
  expect(audit.audit.detail).toContain("装载零闸");

  // 卸载走同一条路,方向相反。
  await runCli(["plugin", "remove", "hello", "--json"], { home });
  const removedEvent = await subscriber.waitForEvent(
    (e) => e.kind === "capability-set" && e.capabilities.action === "removed",
  );
  expect(removedEvent.capabilities.removed).toEqual(["plugin.hello.greet", "plugin.hello.wipe"]);
  expect((removedEvent.capabilities.capabilities as { id: string }[]).map((c) => c.id)).toEqual(before);
});

// MARK: - 仲裁只在调用层(插件工具与内置能力同一条路)

test("dangerous 插件工具 · 无确认器:默拒 + 指引,插件一次都没被拉起", async () => {
  daemon = await startDaemon(home);
  // 「没被拉起」这件事要**直接**证:插件一被执行就在盘上落一个标记文件,断言那个文件不存在。
  // (11 票时是间接证的 —— "响应里没有 handler 的产物"。那只说明产物没回来,不说明进程没起:
  //  一个有副作用的 dangerous 工具完全可能"跑了、把事做了、结果被内核丢掉"。)
  const marker = path.join(workspace, "wipe-was-executed");
  const file = await writePlugin("tracer", `
    const MARKER = ${JSON.stringify(marker)};
    if (process.argv[2] === "describe") {
      console.log(JSON.stringify({ protocol: 1, tools: [
        { name: "wipe", summary: "一被执行就留下痕迹", dangerous: true, parameters: [] },
      ] }));
      process.exit(0);
    }
    if (process.argv[2] === "call") {
      await Bun.write(MARKER, "executed\\n");
      console.log(JSON.stringify({ ok: true, output: { wiped: true } }));
      process.exit(0);
    }
    process.exit(2);
  `);
  expect((await runCli(["plugin", "add", file, "--json"], { home })).exitCode).toBe(0);
  expect(existsSync(marker)).toBe(false); // describe 那一趟不该碰它

  const result = await runCli(["capabilities", "call", "plugin.tracer.wipe", "--json"], { home });

  expect(result.exitCode).toBe(2);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("confirmation_unavailable");
  expect(body.error.guidance.summary.length).toBeGreaterThan(0);
  // 直接判据:插件的 call 分支一次都没跑过。
  expect(existsSync(marker)).toBe(false);
  expect(JSON.stringify(body)).not.toContain("wiped");
});

test("dangerous 插件工具 · 确认器批准:带外确认后照常执行,产物来自插件子进程", async () => {
  daemon = await startDaemon(home);
  await addHello();
  const confirmer = await fakeClient({ behavior: "approve" });
  await confirmer.register("confirm-agent");

  const result = await runCli(
    ["capabilities", "call", "plugin.hello.wipe", "--input", '{"target":"沙盒"}', "--json"],
    { home },
  );

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.output).toEqual({ wiped: true, target: "沙盒" });
  expect(confirmer.resolved).toHaveLength(1);
  // 确认器看到的是**真实入参**(防社工话术那条,插件工具一视同仁)。
  const request = confirmer.events("confirmation")[0];
  expect(request.request.capability).toBe("plugin.hello.wipe");
  expect(request.request.input).toEqual({ target: "沙盒" });
  expect(request.request.descriptor.risk).toBe("dangerous");
});

// MARK: - list / remove / 替换 / 重启

test("list 机读:登记区、工件、装载时刻、工具清单与派生出的能力 id", async () => {
  daemon = await startDaemon(home);
  await addHello();

  const body = parseJsonStdout(await runCli(["plugin", "list", "--json"], { home }));

  expect(body.result.directory).toBe(registryDir());
  expect(body.result.plugins).toHaveLength(1);
  const record = body.result.plugins[0];
  expect(record.name).toBe("hello");
  expect(record.capabilities).toEqual(["plugin.hello.greet", "plugin.hello.wipe"]);
  expect(record.tools.map((tool: any) => tool.dangerous)).toEqual([false, true]);
});

test("remove:能力当场消失、工件被删,再调就是 unknown_capability", async () => {
  daemon = await startDaemon(home);
  await addHello();
  const artifact = path.join(registryDir(), "hello.ts");

  const removed = await runCli(["plugin", "remove", "hello", "--json"], { home });

  expect(removed.exitCode).toBe(0);
  const body = parseJsonStdout(removed);
  expect(body.result.action).toBe("removed");
  expect(body.result.removed).toEqual(["plugin.hello.greet", "plugin.hello.wipe"]);
  expect(existsSync(artifact)).toBe(false);
  expect(await capabilityIds()).not.toContain("plugin.hello.greet");

  const called = await runCli(["capabilities", "call", "plugin.hello.greet", "--json"], { home });
  expect(called.exitCode).toBe(6);
  expect(parseJsonStdout(called).error.code).toBe("unknown_capability");
});

test("remove 不认识的名字:unknown_plugin + 指引(不是静默成功)", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(["plugin", "remove", "nobody", "--json"], { home });

  expect(result.exitCode).toBe(6);
  expect(parseJsonStdout(result).error.code).toBe("unknown_plugin");
});

test("同名再 add = 替换:旧能力注销、新能力上岗(id 不变的那部分照常可调)", async () => {
  daemon = await startDaemon(home);
  await addHello();

  const replacement = await writePlugin("hello", `
    if (process.argv[2] === "describe") {
      console.log(JSON.stringify({ protocol: 1, tools: [
        { name: "greet", summary: "换了个实现", dangerous: false, parameters: [] },
      ] }));
      process.exit(0);
    }
    if (process.argv[2] === "call") {
      console.log(JSON.stringify({ ok: true, output: { version: 2 } }));
      process.exit(0);
    }
    process.exit(2);
  `);
  const result = await runCli(["plugin", "add", replacement, "--json"], { home });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.action).toBe("replaced");
  expect(body.result.removed).toEqual(["plugin.hello.greet", "plugin.hello.wipe"]);
  const ids = await capabilityIds();
  expect(ids).toContain("plugin.hello.greet");
  expect(ids).not.toContain("plugin.hello.wipe"); // 新清单里没有它了
  const called = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.hello.greet", "--json"], { home }),
  );
  expect(called.result.output).toEqual({ version: 2 });
});

test("重启 daemon:插件仍在(登记的是工件与清单,不是内存里的东西)", async () => {
  daemon = await startDaemon(home);
  await addHello();
  await stopDaemon(daemon);

  daemon = await startDaemon(home);

  expect(await capabilityIds()).toContain("plugin.hello.greet");
  const called = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.hello.greet", "--input", '{"who":"重启后"}', "--json"], {
      home,
    }),
  );
  expect(called.result.output.hello).toBe("重启后");
});

test("命名空间:两个插件可以有同名工具,能力 id 靠插件名分开", async () => {
  daemon = await startDaemon(home);
  await addHello();
  const other = await writePlugin("other", OTHER);

  expect((await runCli(["plugin", "add", other, "--json"], { home })).exitCode).toBe(0);

  const ids = await capabilityIds();
  expect(ids).toContain("plugin.hello.greet");
  expect(ids).toContain("plugin.other.greet");
  const called = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.other.greet", "--json"], { home }),
  );
  expect(called.result.output).toEqual({ from: "other" });
});

test("--name 覆写登记名;非法名字当场拒绝(它要拼进能力 id)", async () => {
  daemon = await startDaemon(home);
  const file = await writePlugin("hello", HELLO);

  const named = await runCli(["plugin", "add", file, "--name", "greeter", "--json"], { home });
  expect(named.exitCode).toBe(0);
  expect(await capabilityIds()).toContain("plugin.greeter.greet");

  const bad = await runCli(["plugin", "add", file, "--name", "Bad Name!", "--json"], { home });
  expect(bad.exitCode).toBe(5);
  expect(parseJsonStdout(bad).error.code).toBe("plugin_load_failed");
});

test("装不上的两种输入各有各的指引:路径不存在 / 扩展名不收(指向目录插件那条路)", async () => {
  daemon = await startDaemon(home);

  const missing = await runCli(["plugin", "add", path.join(workspace, "nope.ts"), "--json"], { home });
  expect(missing.exitCode).toBe(5);
  expect(parseJsonStdout(missing).error.code).toBe("plugin_load_failed");

  // 单文件只收 .ts / .js;带依赖的东西请交**目录**(12 票的装载期流水线)。
  const wrongExtension = path.join(workspace, "notes.txt");
  await writeFile(wrongExtension, "我不是插件\n", "utf8");
  const rejected = await runCli(["plugin", "add", wrongExtension, "--json"], { home });
  expect(rejected.exitCode).toBe(5);
  const body = parseJsonStdout(rejected);
  expect(body.error.message).toContain(".ts");
  expect(body.error.detail).toContain("目录");
  // 指引现在要把**两种形态**都说清楚(11 票时只有单文件那一种)。
  expect(body.error.guidance.summary).toContain("目录");
});

// MARK: - 11 票 CR 尾款
//
// 下面这批断言都不是"新功能",而是**11 票交付时漏掉的账**:并发、孙进程、输出上限、登记区卫生、
// 清单伪造。每一条都对应一条能把内核弄坏的具体走法,所以每一条都从"怎么弄坏它"写起。

test("尾款 a:两次 add 并发,注册表与清单不许分叉(重启后两个插件都还在)", async () => {
  daemon = await startDaemon(home);
  const first = await writePlugin("hello", HELLO);
  const second = await writePlugin("other", OTHER);

  // 同时打两枪。11 票时 add 的"读清单"在头、"写清单"在尾,中间隔着一次 describe ——
  // 后写的那份是基于**它进门时读到的**清单算的,于是先写的那条记录被覆盖没了:
  // 注册表里有两个插件,清单里只有一个,重启就少一个。
  const [a, b] = await Promise.all([
    runCli(["plugin", "add", first, "--json"], { home }),
    runCli(["plugin", "add", second, "--json"], { home }),
  ]);
  expect([a.exitCode, b.exitCode]).toEqual([0, 0]);

  const listed = parseJsonStdout(await runCli(["plugin", "list", "--json"], { home }));
  expect((listed.result.plugins as { name: string }[]).map((p) => p.name).sort()).toEqual([
    "hello",
    "other",
  ]);

  // 判据落在**重启之后**:清单是唯一能跨重启的记账,分叉了这里就会少一个。
  await stopDaemon(daemon);
  daemon = await startDaemon(home);
  const ids = await capabilityIds();
  expect(ids).toContain("plugin.hello.greet");
  expect(ids).toContain("plugin.other.greet");
});

test("尾款 b:插件派生的孙进程攥着 stdout 不放 —— 内核照样在超时窗口内收场,不挂死", async () => {
  daemon = await startDaemon(home, { A2_PLUGIN_TIMEOUT_MS: "800" });
  // 插件自己**立刻退出**,但它 spawn 的孙进程继承了同一条 stdout 并睡着 —— 于是那根 pipe
  // 永远没有 EOF。11 票时内核在"读 stdout 到底"上等着,超时杀掉直接子进程也救不回来:
  // 杀完接着等,调用永远不返回。修法是**读流与超时赛跑**(见 plugin/spawn.ts)。
  const file = await writePlugin("grandchild", `
    const mode = process.argv[2];
    if (mode === "describe") {
      console.log(JSON.stringify({ protocol: 1, tools: [
        { name: "leak", summary: "派生一个攥着 stdout 的孙进程", dangerous: false, parameters: [] },
      ] }));
      process.exit(0);
    }
    if (mode === "call") {
      Bun.spawn({ cmd: ["/bin/sleep", "5"], stdout: "inherit", stderr: "inherit" });
      console.log(JSON.stringify({ ok: true, output: { spawned: true } }));
      process.exit(0);
    }
    process.exit(2);
  `);
  expect((await runCli(["plugin", "add", file, "--json"], { home })).exitCode).toBe(0);

  const started = Date.now();
  const result = await runCli(["capabilities", "call", "plugin.grandchild.leak", "--json"], { home });
  const elapsed = Date.now() - started;

  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("plugin_timeout");
  // 诚实的账:内核杀得掉直接子进程,杀不掉它的子孙(没有进程组的口子)——
  // 所以指引里得写明"派生的进程请自己收尾",而不是吹"不留孤儿"。
  expect(JSON.stringify(body.error.guidance)).toContain("杀不掉它的子孙");
  // 关键判据:**回来了**,而且远早于孙进程自己睡醒的时刻。
  expect(elapsed).toBeLessThan(4_000);
});

test("尾款 c:stdout 撞 4MiB 上限 → 结构化错误 + 杀掉;工具数也有 sanity 上限", async () => {
  daemon = await startDaemon(home, { A2_PLUGIN_TIMEOUT_MS: "20000" });

  const flood = await writePlugin("flood", `
    if (process.argv[2] === "describe") {
      // 一行 JSON 是协议;这个插件打算往那条唯一的机读面上倒 6MiB。
      // (逐块 await:直接 write 完就 exit 会把还没落进管道的部分丢掉,那样测的就不是上限了。)
      const chunk = "x".repeat(1024 * 1024);
      for (let i = 0; i < 6; i += 1) await Bun.write(Bun.stdout, chunk);
      process.exit(0);
    }
    process.exit(2);
  `);
  const flooded = await runCli(["plugin", "add", flood, "--json"], { home });
  expect(flooded.exitCode).toBe(6);
  const floodBody = parseJsonStdout(flooded);
  expect(floodBody.error.code).toBe("plugin_protocol_error");
  expect(floodBody.error.message).toContain("4MiB");
  expect(JSON.stringify(floodBody.error.guidance)).toContain("回一个路径");

  const many = await writePlugin("many", `
    if (process.argv[2] === "describe") {
      const tools = Array.from({ length: 500 }, (_, i) => ({
        name: "t" + i, summary: "工具 " + i, dangerous: false, parameters: [],
      }));
      console.log(JSON.stringify({ protocol: 1, tools }));
      process.exit(0);
    }
    process.exit(2);
  `);
  const manyResult = await runCli(["plugin", "add", many, "--json"], { home });
  expect(manyResult.exitCode).toBe(6);
  expect(parseJsonStdout(manyResult).error.message).toContain("超过上限 128");
  // 两次都没登记:能力表干干净净。
  expect(parseJsonStdout(await runCli(["plugin", "list", "--json"], { home })).result.plugins).toEqual([]);
});

test("尾款 d:跨扩展名替换要删旧工件;崩在半路留下的暂存件启动与 add 时都会被清掉", async () => {
  daemon = await startDaemon(home);
  await addHello();
  expect(existsSync(path.join(registryDir(), "hello.ts"))).toBe(true);

  // 同一个插件名,这次交的是 .js —— rename 覆盖的是 hello.js,hello.ts 原地不动。
  // 不删它就等于在登记区里留一份"再也不会被调用、却看起来像这个插件的代码"的死文件。
  const replacement = path.join(workspace, "hello.js");
  await writeFile(replacement, `
    if (process.argv[2] === "describe") {
      console.log(JSON.stringify({ protocol: 1, tools: [
        { name: "greet", summary: "换成 .js 了", dangerous: false, parameters: [] },
      ] }));
      process.exit(0);
    }
    if (process.argv[2] === "call") {
      console.log(JSON.stringify({ ok: true, output: { flavour: "js" } }));
      process.exit(0);
    }
    process.exit(2);
  `, "utf8");
  const replaced = await runCli(["plugin", "add", replacement, "--json"], { home });

  expect(replaced.exitCode).toBe(0);
  expect(parseJsonStdout(replaced).result.action).toBe("replaced");
  expect(existsSync(path.join(registryDir(), "hello.js"))).toBe(true);
  expect(existsSync(path.join(registryDir(), "hello.ts"))).toBe(false); // 旧工件收了尸

  // 崩溃遗留的暂存件:add 时清扫。
  const leftover = path.join(registryDir(), ".staging-hello-deadbeef.ts");
  await writeFile(leftover, "// 上一次 add 崩在半路留下的\n", "utf8");
  await runCli(["plugin", "add", replacement, "--json"], { home });
  expect(existsSync(leftover)).toBe(false);

  // 启动时也清扫(这条更要紧:崩溃之后没有下一次 add 也该干净)。
  const afterCrash = path.join(registryDir(), ".staging-other-cafebabe.ts");
  await writeFile(afterCrash, "// 同上\n", "utf8");
  await stopDaemon(daemon);
  daemon = await startDaemon(home);
  await runCli(["status", "--json"], { home });
  expect(existsSync(afterCrash)).toBe(false);
});

test("尾款 e:手改清单塞一条非法记录,daemon 照起 —— 坏条目单条拒绝,好插件照用", async () => {
  daemon = await startDaemon(home);
  await addHello();
  await stopDaemon(daemon);

  // 名字带点 = 它派生出的能力 id 会与别人撞上,注册表构造器当场抛。
  // 11 票时这一条足以让 daemon **起不来**:手改一个文件就能掀翻整个内核。
  const manifestPath = path.join(registryDir(), "plugins.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.plugins.push({
    name: "hello.greet",
    artifact: path.join(registryDir(), "hello.ts"),
    source: "/forged",
    addedAt: new Date().toISOString(),
    tools: [{ name: "x", summary: "伪造的", dangerous: false, parameters: [] }],
    capabilities: ["plugin.hello.greet.x"],
  });
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2), "utf8");

  daemon = await startDaemon(home); // ← 起得来才算过

  const ids = await capabilityIds();
  expect(ids).toContain("plugin.hello.greet"); // 好插件照常在
  expect(ids.some((id) => id.startsWith("plugin.hello.greet."))).toBe(false); // 坏条目没上岗
  // list 与能力面口径一致:列得出来的就是调得动的,不留"列得出、调不动"的幽灵。
  const listed = parseJsonStdout(await runCli(["plugin", "list", "--json"], { home }));
  expect((listed.result.plugins as { name: string }[]).map((p) => p.name)).toEqual(["hello"]);
  // 但绝不静默:降级这件事落 stderr。
  await stopDaemon(daemon);
  const stderr = await daemon.stderr();
  daemon = undefined;
  expect(stderr).toContain("plugins.restore.degraded");
  expect(stderr).toContain("hello.greet");
});

// MARK: - 红线:进程外 + 能力只经协议白名单
//
// 10 票交接单点名的那条:旧架构的「PluginProxy 不 import 任何 Host*」(49 条 grep)随旧壳退场,
// 新架构里同一条精神的载体是**进程边界**。下面三条就是它的新断言。

test("红线①:插件是进程外子进程 —— 它回报的 pid 与内核 daemon 的 pid 不是一个", async () => {
  daemon = await startDaemon(home);
  await addHello();

  const status = parseJsonStdout(await runCli(["status", "--json"], { home }));
  const called = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.hello.greet", "--input", '{"who":"边界"}', "--json"], {
      home,
    }),
  );

  expect(typeof called.result.output.pid).toBe("number");
  expect(called.result.output.pid).not.toBe(status.result.pid);
  // 而且它跑在**登记区**里(cwd 固定 —— 与 --no-install 一起把"祖先目录有没有 node_modules"钉死)。
  // 比的是 realpath:macOS 的 /tmp 是指向 /private/tmp 的符号链接,子进程报的 cwd 已经解过了。
  expect(called.result.output.cwd).toBe(realpathSync(registryDir()));
});

test("红线②:能力只经协议白名单 —— 内核不把自己的坐标递给插件(A2_* 一个都不传)", async () => {
  // 内核这一侧确实拿着一堆 A2_*(A2_HOME 就是测试注入的),插件那一侧必须一个都看不到。
  daemon = await startDaemon(home, { A2_PLUGIN_TIMEOUT_MS: "20000" });
  await addHello();

  const called = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.hello.greet", "--input", '{"who":"白名单"}', "--json"], {
      home,
    }),
  );

  expect(called.result.output.a2env).toEqual([]);
  // 白名单本身也钉一遍:只有"任何进程都要的那几样" + 让编译产物切成 bun 的那个开关。
  const env = pluginEnv({ PATH: "/usr/bin", A2_HOME: "/should/not/leak", HOME: "/Users/someone" });
  expect(Object.keys(env).sort()).toEqual(["BUN_BE_BUN", "PATH"]);
  expect(JSON.stringify(env)).not.toContain("should/not/leak");
});

test("红线③:spawn 插件恒带 --no-install;import 不在的包 = 当场硬失败,绝不联网现装", async () => {
  // 这条纪律的特点是"有它没它正常插件都一样",所以必须有断言看着 argv 本身(02 票 spike §8.5)。
  const argv = pluginCommand("/tmp/x.ts", ["describe"]);
  expect(argv[1]).toBe("--no-install");
  expect(argv[2]).toBe("/tmp/x.ts");

  daemon = await startDaemon(home, { A2_PLUGIN_TIMEOUT_MS: "20000" });
  const file = await writePlugin("greedy", `
    import missing from "a2-definitely-not-a-real-package";
    console.log(JSON.stringify({ protocol: 1, tools: [], missing }));
  `);

  const result = await runCli(["plugin", "add", file, "--json"], { home });

  // fail-closed:装不上,而不是"先联网把包装上再说"。
  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("plugin_protocol_error");
  expect(body.error.detail).toContain("a2-definitely-not-a-real-package");
});

test("红线④:命名空间隔离 —— **全部**内置能力都不以 plugin. 开头,插件永远撞不掉它们", async () => {
  // 静态那一半:自检样本族。
  const builtins = BUILTIN_CAPABILITIES.map((capability) => capability.descriptor.id);
  expect(builtins.length).toBeGreaterThan(0);
  for (const id of builtins) {
    expect(id.startsWith(CAPABILITY_NAMESPACE)).toBe(false);
  }

  // 活体那一半(11 票 CR 尾款 g):`BUILTIN_CAPABILITIES` 只是内置能力的**一族**——
  // 代理域(proxy.*)、仲裁面(arbitration.*)是在 daemon 装配时才拼进注册表的。
  // 只扫那一族,等于把大半个内置面漏在断言之外。这里问的是**一台真内核此刻的整张表**。
  daemon = await startDaemon(home);
  const live = await capabilityIds();
  expect(live.length).toBeGreaterThan(builtins.length); // 确实比自检样本族多(否则这条断言是空的)
  expect(live.filter((id) => id.startsWith("proxy.")).length).toBeGreaterThan(0);
  expect(live.filter((id) => id.startsWith("arbitration.")).length).toBeGreaterThan(0);
  for (const id of live) {
    expect(id.startsWith(CAPABILITY_NAMESPACE)).toBe(false);
  }
});
