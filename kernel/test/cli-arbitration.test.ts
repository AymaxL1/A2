// dangerous 三层仲裁完全体 + 角色注册 + 订阅推送(08 票)。
//
// 缝还是那两条(不新增更低层的缝):
//   * **CLI 面** —— argv 进、stdout JSON + 退出码出:三层仲裁的每一种收场都在这里断言;
//   * **UDS 协议面** —— 用 `test/support/fake-client.ts` 那个**假确认器 / 假订阅者**长连接客户端。
//     门禁里没有真的菜单栏壳(那是 10 票),但协议不该等壳出来才有活体验证。
//
// 退出码语义(本票补齐 3 的唯一产出面):
//   0 批准后照常执行 / 2 默拒与明确拒绝 / 3 等确认超时 / 6 协议面的报文不成立。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import {
  ArbitrationStatusResultSchema,
  ConfirmationErrorSchema,
  KernelSnapshotSchema,
} from "../src/contract/wire.ts";
import { connectFakeClient, type FakeClient } from "./support/fake-client.ts";
import {
  cleanupHome,
  makeHome,
  parseJsonStdout,
  runCli,
  sendRawLine,
  startDaemon,
  stopDaemon,
  type DaemonHandle,
} from "./support/harness.ts";

let home: string;
let daemon: DaemonHandle | undefined;
let clients: FakeClient[] = [];

beforeEach(async () => {
  home = await makeHome();
  daemon = undefined;
  clients = [];
});

afterEach(async () => {
  for (const client of clients) await client.close();
  if (daemon) await stopDaemon(daemon);
  await cleanupHome(home);
});

/** 连一个假客户端并登记进 teardown(测试绝不留悬空连接)。 */
async function fakeClient(options: {
  name?: string;
  behavior?: "approve" | "deny" | "ignore";
  reason?: string;
  codeDirectoryHash?: string;
  teamIdentifier?: string;
} = {}): Promise<FakeClient> {
  const client = await connectFakeClient({ socketPath: daemon!.socketPath, ...options });
  clients.push(client);
  return client;
}

async function wipe(input?: Record<string, unknown>) {
  const args = ["capabilities", "call", "demo.wipe"];
  if (input) args.push("--input", JSON.stringify(input));
  args.push("--json");
  return await runCli(args, { home });
}

const auditLog = () => path.join(home, "log", "arbitration.log");

/** `src/` 下的全部 `.ts`(结构性断言用:某些东西必须**在整个内核里一次都不出现**)。 */
function sourceFiles(dir: string): string[] {
  const found: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) found.push(...sourceFiles(full));
    else if (entry.name.endsWith(".ts")) found.push(full);
  }
  return found;
}

async function auditLines(): Promise<any[]> {
  const text = await readFile(auditLog(), "utf8").catch(() => "");
  return text
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
}

/**
 * 等审计日志里出现某个动作。
 * **落盘是异步且允许失败的**(见 `daemon/audit.ts`:盘满/只读不该让仲裁停摆),所以断言"文件里有这条"
 * 必须是等待式的;要同步读那份内存副本请用 `a2 arbitration status`。
 */
async function waitForAudit(action: string, timeoutMs = 3000): Promise<any> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = (await auditLines()).find((event) => event.action === action);
    if (found) return found;
    await Bun.sleep(20);
  }
  throw new Error(
    `审计日志里等不到 ${action};现有:${JSON.stringify((await auditLines()).map((e) => e.action))}`,
  );
}

// MARK: - 第③层:确认器在场时的三种收场

test("确认器在场 + 批准 → 照常执行(退出码 0),且确认器拿到的是本次调用的真实入参", async () => {
  daemon = await startDaemon(home);
  const confirmer = await fakeClient({ name: "fake-panel", behavior: "approve" });
  await confirmer.register("confirm-agent");

  const result = await wipe({ target: "disk9" });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  // handler 真的跑了(第①层那条断言的**反面**:批准之后产物必须出现)。
  expect(body.result.output).toEqual({ wiped: true, target: "disk9" });

  // 确认器确实被问过,且看到的是**这一次**的参数 —— 旧 Swift 那条 `[confirm] <id> key=value`
  // 日志(防盲批)在新架构里的对位物就是它,而且升成了协议字段。
  const request = confirmer.events("confirmation")[0].request;
  expect(request.capability).toBe("demo.wipe");
  expect(request.input).toEqual({ target: "disk9" });
  expect(request.descriptor.risk).toBe("dangerous");
  expect(request.descriptor.summary.length).toBeGreaterThan(0);
  expect(confirmer.resolved).toEqual([{ confirmation: request.id, decision: "approve" }]);

  // **确认内容不出现在发起方 CLI 通路上**:既没有确认器的名字,也没有那条确认请求的 id。
  expect(result.stdout).not.toContain("fake-panel");
  expect(result.stdout).not.toContain(request.id);
}, 20000);

test("确认器在场 + 拒绝 → confirmation_denied + 退出码 2,理由进报文,handler 一次都没执行", async () => {
  daemon = await startDaemon(home);
  const confirmer = await fakeClient({ behavior: "deny", reason: "这台机器上不许 wipe" });
  await confirmer.register("confirm-agent");

  const result = await wipe({ target: "disk9" });

  expect(result.exitCode).toBe(2);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("confirmation_denied");
  expect(body.error.detail).toContain("这台机器上不许 wipe");
  // 反证:被拒 = 压根没跑。
  expect(result.stdout).not.toContain("wiped");
  // 拒绝即指引:三码都必带 guidance(契约层由 ConfirmationErrorSchema 强制)。
  expect(ConfirmationErrorSchema.safeParse(body.error).success).toBe(true);
}, 20000);

test("确认器在场但没人应答 → confirmation_timeout + 退出码 3(沉默不构成同意)", async () => {
  daemon = await startDaemon(home, { A2_CONFIRM_TIMEOUT_MS: "400" });
  const confirmer = await fakeClient({ behavior: "ignore" });
  await confirmer.register("confirm-agent");

  const started = Date.now();
  const result = await wipe({ target: "disk9" });

  expect(result.exitCode).toBe(3);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("confirmation_timeout");
  expect(body.error.guidance.context.timeoutMs).toBe("400");
  expect(result.stdout).not.toContain("wiped");
  // 确实等了那个窗口(不是立刻放弃),但也没有等到客户端自己的默认超时(5s)。
  expect(Date.now() - started).toBeGreaterThanOrEqual(400);
  expect(Date.now() - started).toBeLessThan(5000);
  expect(confirmer.events("confirmation").length).toBe(1);
}, 20000);

// MARK: - 在场 = 长连接:断线即降级

test("在途挂起时确认器断线 → 立即降回默拒(confirmation_unavailable + 退出码 2),不等超时", async () => {
  // 超时窗口开得很大:若"降级"没生效,这条测试只会超时红,不会假绿。
  daemon = await startDaemon(home, { A2_CONFIRM_TIMEOUT_MS: "60000" });
  const confirmer = await fakeClient({ behavior: "ignore" });
  await confirmer.register("confirm-agent");

  const pending = wipe({ target: "disk9" });
  await confirmer.waitForEvent((event) => event.kind === "confirmation");
  const started = Date.now();
  await confirmer.close();

  const result = await pending;
  expect(result.exitCode).toBe(2);
  expect(parseJsonStdout(result).error.code).toBe("confirmation_unavailable");
  expect(result.stdout).not.toContain("wiped");
  // 立即,而不是等那个 60s 的窗口。
  expect(Date.now() - started).toBeLessThan(5000);

  expect((await waitForAudit("downgraded")).capability).toBe("demo.wipe");
}, 20000);

test("确认器走了之后:下一条 dangerous 立刻回到第①层默拒", async () => {
  daemon = await startDaemon(home);
  const confirmer = await fakeClient({ behavior: "approve" });
  await confirmer.register("confirm-agent");
  expect((await wipe()).exitCode).toBe(0);

  await confirmer.close();

  const started = Date.now();
  const refused = await wipe();
  expect(refused.exitCode).toBe(2);
  expect(parseJsonStdout(refused).error.code).toBe("confirmation_unavailable");
  // 没有任何等待:没有确认器就没有可等的人。
  expect(Date.now() - started).toBeLessThan(5000);
}, 20000);

// MARK: - 角色注册协议

test("注册即全量快照:状态 / 能力全集 / 仲裁面 / 存活监督 / 审计,一次往返全给", async () => {
  daemon = await startDaemon(home);
  const subscriber = await fakeClient({ name: "fake-shell" });

  const registered = await subscriber.register("subscriber");

  expect(registered.role).toBe("subscriber");
  expect(registered.roles).toEqual(["subscriber"]);
  // 对端 UID 是**唯一被验证过的**身份事实(名字是自称)。
  expect(registered.uid).toBe(process.getuid?.());
  expect(typeof registered.connection).toBe("string");

  const snapshot = registered.snapshot;
  expect(KernelSnapshotSchema.safeParse(snapshot).success).toBe(true);
  expect(snapshot.status.state).toBe("running");
  expect(snapshot.capabilities.map((c: { id: string }) => c.id)).toContain("demo.wipe");
  expect(snapshot.arbitration).toEqual({
    confirmerPresent: false,
    confirmers: 0,
    subscribers: 1,
    timeoutMs: 120000,
    pending: [],
  });
  expect(snapshot.supervision.watching).toBe(true);
  expect(Array.isArray(snapshot.audit)).toBe(true);

  // **注册那一帧就带着内核版本**(15 票:面板的升级检测就靠它 —— 内嵌的那份 bin 与线上跑着的
  // 这一份对不上,面板才知道该提示"重装以升级")。位置有意不新造一个字段:快照的 status 里
  // 本来就有 `version`,而它与 `a2 version` 同一个真值源(`runtime/version.ts` ← package.json)。
  const reported = await runCli(["version"], { home });
  expect(reported.exitCode).toBe(0);
  expect(snapshot.status.version).toBe(reported.stdout.trim());
  expect(snapshot.status.protocol).toBe(1);
}, 20000);

test("一条连接可以既是确认器又是订阅者;重复注册同一角色是幂等的", async () => {
  daemon = await startDaemon(home);
  const shell = await fakeClient({ name: "fake-panel", behavior: "approve" });

  await shell.register("confirm-agent");
  const both = await shell.register("subscriber");
  expect(both.roles.sort()).toEqual(["confirm-agent", "subscriber"]);
  expect(both.snapshot.arbitration).toMatchObject({ confirmers: 1, subscribers: 1 });

  const again = await shell.register("subscriber");
  expect(again.snapshot.arbitration).toMatchObject({ confirmers: 1, subscribers: 1 });
  // 幂等 = 不再多记一次进场事件。
  await waitForAudit("subscriber_joined");
  const joins = (await auditLines()).filter((event) => event.action === "subscriber_joined");
  expect(joins.length).toBe(1);
}, 20000);

test("V1 不验签:加固字段原样收下,但唯一算数的身份事实仍是内核自己问出来的 uid", async () => {
  daemon = await startDaemon(home);
  const impostor = await fakeClient({
    name: "a2-panel",
    codeDirectoryHash: "cdhash-完全是编的",
    teamIdentifier: "TEAM-完全是编的",
  });

  // **注册成功** —— 这就是"同 UID 冒充"这条已知边界的活体样子:内核收下声明、不校验。
  const registered = await impostor.register("confirm-agent");
  expect(registered.role).toBe("confirm-agent");
  expect(registered.uid).toBe(process.getuid?.());

  // 审计里留的是"自称的名字 + 验过的 uid",两者分开记 —— 事后复盘时不会把自称当成事实。
  const joined = await waitForAudit("confirmer_joined");
  expect(joined.client.name).toBe("a2-panel");
  expect(joined.client.uid).toBe(process.getuid?.());
  // 编的那两个字段没有被抄进审计当身份用。
  expect(JSON.stringify(joined)).not.toContain("cdhash-完全是编的");
}, 20000);

test("角色是连接的属性:没注册 confirm-agent 的连接不能替人做决定", async () => {
  daemon = await startDaemon(home);
  const confirmer = await fakeClient({ behavior: "ignore" });
  await confirmer.register("confirm-agent");
  const bystander = await fakeClient({ name: "旁观者" });
  await bystander.register("subscriber");

  const pending = wipe({ target: "disk9" });
  const event = await confirmer.waitForEvent((e) => e.kind === "confirmation");

  // 订阅者拿不到 confirmation 事件,但就算它硬猜出 id 也没有资格做决定。
  const refused = await bystander.request("confirmations.resolve", {
    confirmation: event.request.id,
    decision: "approve",
  });
  expect(refused.ok).toBe(false);
  expect(refused.error.code).toBe("role_not_registered");

  await confirmer.close();
  expect((await pending).exitCode).toBe(2);
}, 20000);

test("协议面的两条拒绝:决定一条不存在的确认请求 / 注册一个不存在的角色", async () => {
  daemon = await startDaemon(home);
  const confirmer = await fakeClient({ behavior: "ignore" });
  await confirmer.register("confirm-agent");

  const unknown = await confirmer.request("confirmations.resolve", {
    confirmation: "根本没有这条",
    decision: "approve",
  });
  expect(unknown.ok).toBe(false);
  expect(unknown.error.code).toBe("confirmation_unknown");

  const bogusRole = JSON.parse(
    await sendRawLine(
      daemon.socketPath,
      JSON.stringify({
        v: 1,
        id: "bad-role",
        op: "roles.register",
        params: { role: "root", identity: { name: "x" } },
      }),
    ),
  );
  expect(bogusRole.ok).toBe(false);
  expect(bogusRole.error.code).toBe("invalid_params");
}, 20000);

test("快照即基线:注册响应是本连接的第一帧,且内核不把「自己进场」这条增量推给自己", async () => {
  daemon = await startDaemon(home);
  // 先来一个旁观订阅者:它应当收到**别人**进场的那条增量(对它那是真变化)。
  const watcher = await fakeClient({ name: "先来的" });
  await watcher.register("subscriber");

  const joiner = await fakeClient({ name: "后来的" });
  const registered = await joiner.register("subscriber");

  // ① 第一帧必须是自己那条响应 —— 没有"增量先于基线"的窗口。
  expect(joiner.arrivals[0]).toBe("response");
  // ② 快照里的计数**已经含它自己**(所以不需要再补一条增量)。
  expect(registered.snapshot.arbitration.subscribers).toBe(2);
  // ③ 内核不把它自己的进场事件推给它:严格按「快照 + 增量」记账的客户端不会重复计入。
  await Bun.sleep(150);
  expect(joiner.events()).toEqual([]);
  // ④ 而**别人**照常收到这条增量。
  const seen = await watcher.waitForEvent(
    (event) => event.kind === "arbitration" && event.state.subscribers === 2,
  );
  expect(seen.state.subscribers).toBe(2);
  expect(
    watcher.events("audit").some((event) => event.audit.action === "subscriber_joined"),
  ).toBe(true);
}, 20000);

test("发起方断线:在途确认立即取消(留痕 cancelled),确认器再拿旧 id 决定 → confirmation_unknown", async () => {
  // 超时窗口开得很大:若"取消"没生效,这条只会超时红,不会假绿。
  daemon = await startDaemon(home, { A2_CONFIRM_TIMEOUT_MS: "60000" });
  const confirmer = await fakeClient({ behavior: "ignore" });
  await confirmer.register("confirm-agent");

  // 用一条**裸连接**当发起方,这样我们能精确控制它什么时候断。
  const requester = await fakeClient({ name: "发起方" });
  const pending = requester.request("capabilities.call", {
    capability: "demo.wipe",
    input: { target: "disk9" },
  });
  const event = await confirmer.waitForEvent((e) => e.kind === "confirmation");

  const started = Date.now();
  await requester.close();
  pending.catch(() => {}); // 发起方走了,这条响应本来就没有去处

  // 在途那条被取消:确认器看到待办清空 + 一条 cancelled 审计。
  await confirmer.waitForEvent(
    (e) => e.kind === "arbitration" && e.state.pending.length === 0,
    10000,
  );
  expect(Date.now() - started).toBeLessThan(10000);
  const cancelled = await waitForAudit("cancelled");
  expect(cancelled.capability).toBe("demo.wipe");
  expect(cancelled.confirmation).toBe(event.request.id);

  // 确认器若仍拿旧 id 来决定,拿到的是"没有这条"——而那条报文早就把"发起方已断开"列为收场原因。
  const late = await confirmer.request("confirmations.resolve", {
    confirmation: event.request.id,
    decision: "approve",
  });
  expect(late.ok).toBe(false);
  expect(late.error.code).toBe("confirmation_unknown");
  expect(late.error.detail).toContain("发起方已断开");

  // 反证:**handler 一次都没跑** —— 取消之后再批准也不会有副作用。
  const audit = await auditLines();
  expect(audit.map((e) => e.action)).not.toContain("approved");
}, 30000);

// MARK: - 订阅推送(全量快照 + 增量,零轮询)

test("零轮询:订阅者注册之后一条请求都不再发,却照样收到能力变化与审计增量", async () => {
  daemon = await startDaemon(home);
  const subscriber = await fakeClient({ name: "fake-shell" });
  await subscriber.register("subscriber");

  // 有人改了状态(normal 档,不经确认)。订阅者没有发起任何查询。
  const changed = await runCli(
    ["capabilities", "call", "demo.note.set", "--input", '{"key":"k","value":"v"}', "--json"],
    { home },
  );
  expect(changed.exitCode).toBe(0);

  const event = await subscriber.waitForEvent((e) => e.kind === "capability");
  expect(event.capability).toEqual({
    capability: "demo.note.set",
    risk: "normal",
    // **带着 output 一起推** —— 订阅者据此直接投影,不必回头再查一次。
    output: { set: true, key: "k", value: "v", scope: "session" },
  });

  // 只读的 safe 档不产生噪音。
  await runCli(["capabilities", "call", "demo.echo", "--input", '{"message":"hi"}', "--json"], {
    home,
  });
  await Bun.sleep(200);
  expect(subscriber.events("capability").length).toBe(1);

  // 零轮询的实证:整场只发过那一条 roles.register。
  expect(subscriber.sent).toEqual(["roles.register"]);
}, 20000);

test("确认器进出会推仲裁面状态:dangerous 能不能走通是一条可观测的运行时事实", async () => {
  daemon = await startDaemon(home);
  const subscriber = await fakeClient({ name: "fake-shell" });
  const before = await subscriber.register("subscriber");
  expect(before.snapshot.arbitration.confirmerPresent).toBe(false);

  const confirmer = await fakeClient({ behavior: "approve" });
  await confirmer.register("confirm-agent");
  const joined = await subscriber.waitForEvent(
    (e) => e.kind === "arbitration" && e.state.confirmerPresent === true,
  );
  expect(joined.state.confirmers).toBe(1);

  await confirmer.close();
  const left = await subscriber.waitForEvent(
    (e) => e.kind === "arbitration" && e.state.confirmerPresent === false,
  );
  expect(left.state.confirmers).toBe(0);
}, 20000);

test("确认内容不外泄:订阅者只看得到「有一条在途」,看不到本次调用的入参", async () => {
  daemon = await startDaemon(home, { A2_CONFIRM_TIMEOUT_MS: "60000" });
  const subscriber = await fakeClient({ name: "fake-shell" });
  await subscriber.register("subscriber");
  const confirmer = await fakeClient({ behavior: "ignore" });
  await confirmer.register("confirm-agent");

  const pending = wipe({ target: "机密-disk9" });
  const state = await subscriber.waitForEvent(
    (e) => e.kind === "arbitration" && e.state.pending.length === 1,
  );

  // 订阅者看得到坐标(哪条能力、什么时候到期),看不到 input。
  expect(state.state.pending[0]).toMatchObject({ capability: "demo.wipe", risk: "dangerous" });
  expect(Object.keys(state.state.pending[0])).toEqual([
    "id",
    "capability",
    "risk",
    "requestedAt",
    "expiresAt",
  ]);
  // 全场推给订阅者的每一帧里都没有那个参数值;`confirmation` 事件它一条都收不到。
  expect(subscriber.events("confirmation").length).toBe(0);
  expect(JSON.stringify(subscriber.events())).not.toContain("机密-disk9");
  // 而确认器收得到 —— 它必须原样呈现给人看(防社工话术)。
  // (两条连接各自独立,到达先后没有保证:确认器那一帧要单独等,不能借订阅者那帧的东风。)
  await confirmer.waitForEvent((event) => event.kind === "confirmation");
  expect(JSON.stringify(confirmer.events("confirmation"))).toContain("机密-disk9");

  await confirmer.close();
  expect((await pending).exitCode).toBe(2);
}, 20000);

test("没注册角色的连接收不到任何推送(推送只发给已注册的长连接)", async () => {
  daemon = await startDaemon(home);
  const lurker = await fakeClient({ name: "没注册的" });
  const subscriber = await fakeClient({ name: "注册了的" });
  await subscriber.register("subscriber");

  await runCli(
    ["capabilities", "call", "demo.note.set", "--input", '{"key":"k","value":"v"}', "--json"],
    { home },
  );
  await subscriber.waitForEvent((e) => e.kind === "capability");

  expect(lurker.events()).toEqual([]);
}, 20000);

// MARK: - 对端 UID 校验

test("对端 UID 与内核不符:连接当场被拒 + 留痕(a2 自己也连不上,证明这道门是真的)", async () => {
  const uid = process.getuid?.() ?? 0;
  // 期望值被换成另一个 uid —— 这个开关**只能让校验更严**(见 daemon/peer.ts 的口径),
  // 于是连内核自己的 CLI 都会被拒:活体拒绝路径。
  daemon = await startDaemon(home, { A2_PEER_EXPECT_UID: String(uid + 1) });

  const result = await runCli(["status", "--json"], { home });

  expect(result.exitCode).toBe(2);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("peer_rejected");
  expect(body.error.detail).toContain(String(uid));
  expect(body.error.guidance.steps.length).toBeGreaterThan(0);

  // 「有别的用户在敲这个 socket」是唯一值得留痕的安全信号。
  expect((await waitForAudit("peer_rejected")).client.uid).toBe(uid);
}, 20000);

test("A2_PEER_EXPECT_UID=0 被拒绝:覆写作废、回落到内核自己的 uid,连接照常可用", async () => {
  // root 该走 OS 那两道门(run/ 0700 + socket 0600),不该由一个测试开关授权。
  daemon = await startDaemon(home, { A2_PEER_EXPECT_UID: "0" });

  const result = await runCli(["status", "--json"], { home });

  expect(result.exitCode).toBe(0);
  expect(parseJsonStdout(result).result.state).toBe("running");
}, 20000);

// MARK: - 审计:留痕 + 可查询

test("审计留痕:dangerous 的请求与收场配对可查,`a2 arbitration status` 与日志文件同源", async () => {
  daemon = await startDaemon(home);
  const confirmer = await fakeClient({ name: "fake-panel", behavior: "approve" });
  await confirmer.register("confirm-agent");
  expect((await wipe({ target: "disk9" })).exitCode).toBe(0);

  const queried = await runCli(["arbitration", "status", "--json"], { home });
  expect(queried.exitCode).toBe(0);
  const output = parseJsonStdout(queried).result.output;
  expect(ArbitrationStatusResultSchema.safeParse(output).success).toBe(true);
  expect(output.logPath).toBe(auditLog());
  expect(output.state.confirmerPresent).toBe(true);

  const actions = output.events.map((event: { action: string }) => event.action);
  expect(actions).toContain("confirmer_joined");
  expect(actions).toContain("requested");
  expect(actions).toContain("approved");

  // 请求与收场**配对**:同一个 confirmation id 各出现一次。
  const requested = output.events.find((e: { action: string }) => e.action === "requested");
  const approved = output.events.find((e: { action: string }) => e.action === "approved");
  expect(approved.confirmation).toBe(requested.confirmation);
  expect(approved.capability).toBe("demo.wipe");
  expect(approved.client.name).toBe("fake-panel");

  // NDJSON 日志与内存里那份同源(全量在文件里)。
  await waitForAudit("approved");
  expect((await auditLines()).map((event) => event.action)).toEqual(actions);
}, 20000);

test("无确认器的默拒也留痕(unavailable),`arbitration status` 自己是 safe —— 没有确认器时照样查得动", async () => {
  daemon = await startDaemon(home);

  expect((await wipe()).exitCode).toBe(2);

  const output = parseJsonStdout(await runCli(["arbitration", "status", "--json"], { home }))
    .result.output;
  expect(output.state.confirmerPresent).toBe(false);
  expect(output.events.map((e: { action: string }) => e.action)).toContain("unavailable");
}, 20000);

// MARK: - 裸 UDS 直连:仲裁在内核里,不在客户端里

test("裸 UDS 直连 + 确认器在场:同样要走带外确认(绕开 CLI 不等于绕开仲裁)", async () => {
  daemon = await startDaemon(home);
  const confirmer = await fakeClient({ behavior: "approve" });
  await confirmer.register("confirm-agent");

  const line = await sendRawLine(
    daemon.socketPath,
    JSON.stringify({
      v: 1,
      id: "raw-wipe",
      op: "capabilities.call",
      params: { capability: "demo.wipe", input: { target: "disk9" } },
    }),
  );

  const response = JSON.parse(line);
  expect(response.id).toBe("raw-wipe");
  expect(response.ok).toBe(true);
  expect(response.result.output).toEqual({ wiped: true, target: "disk9" });
  // 裸连接**也**得经过人:确认器确实被问了一次。
  expect(confirmer.resolved.length).toBe(1);
}, 20000);

// MARK: - 全命令面:无 --yes、无 TTY 确认、协议层无平台分支

test("`--yes` 旁路在**每一条**命令面上都不存在;确认器在场也不会改变这一点", async () => {
  daemon = await startDaemon(home);
  const confirmer = await fakeClient({ behavior: "approve" });
  await confirmer.register("confirm-agent");

  const surfaces = [
    ["status"],
    ["capabilities", "call", "demo.wipe"],
    ["proxy", "status"],
    ["proxy", "subscription", "add", "--name", "x", "--source", "file:///dev/null"],
    ["arbitration", "status"],
    ["service", "status"],
    ["mihomo", "status"],
  ];
  for (const args of surfaces) {
    const result = await runCli([...args, "--yes", "--json"], { home });
    // `--yes` 不是"被忽略",是"根本不存在" —— 未知选项当场报用法错。
    expect({ args, exitCode: result.exitCode }).toEqual({ args, exitCode: 1 });
    expect(parseJsonStdout(result).error.code).toBe("usage");
  }
  // 而且它一次都没有偷偷触发确认(确认器一条 confirmation 事件都没收到)。
  expect(confirmer.events("confirmation").length).toBe(0);
}, 30000);

test("永不交互阻塞:内核里没有任何读 stdin / 认 TTY 的代码(isatty 不构成人类证明)", async () => {
  const usage = path.resolve(import.meta.dir, "../src/cli/usage.ts");
  const offenders: string[] = [];
  for (const file of sourceFiles(path.resolve(import.meta.dir, "../src"))) {
    if (file === usage) continue; // 那是帮助**散文**,下面单独断言它说的是禁令而不是实现
    const text = await readFile(file, "utf8");
    if (/process\.stdin|readline|isatty|isTTY/.test(text)) offenders.push(file);
  }
  expect(offenders).toEqual([]);
  // 唯一一处提到 isatty 的地方是帮助文本,而且它说的是"这东西不算数"。
  expect(await readFile(usage, "utf8")).toContain("isatty 不构成人类证明");
});

test("Linux 形态由构造保证:角色协议与仲裁这一层没有任何平台分支", async () => {
  const protocolLayer = [
    "daemon/hub.ts",
    "daemon/arbitration.ts",
    "daemon/audit.ts",
    "daemon/router.ts",
    "capability/registry.ts",
    "capability/arbitration.ts",
  ];
  for (const relative of protocolLayer) {
    const text = await readFile(path.resolve(import.meta.dir, "../src", relative), "utf8");
    expect({ relative, hasBranch: /process\.platform|darwin|linux/.test(text) }).toEqual({
      relative,
      hasBranch: false,
    });
  }
  // 平台差异**只**住在取对端凭据那一处(getpeereid vs SO_PEERCRED),那是操作系统 API 的差异,
  // 不是协议的差异 —— 所以「Linux 上无确认器」这个形态在本票是先天成立的,不靠运行时判断。
  const peer = await readFile(path.resolve(import.meta.dir, "../src/daemon/peer.ts"), "utf8");
  expect(peer).toContain("process.platform");
});

// MARK: - 活体拒绝报文 ≡ 金标(04 票 CR 建议的那道防线)

/**
 * 活体报文与金标逐字段对照。**归一化只做三类**,每一类都写明理由:
 *   * `home` / `socketPath` —— 临时 A2_HOME 每次都不一样,金标里是个示例路径;
 *   * 超时窗口的数值 —— 门禁把它调到几百毫秒(否则一条测试要跑两分钟),金标记的是默认值;
 *   * 响应包封的 `id` —— 每次调用现造。
 * 除此之外**一个字都不许差**:文案、步骤、命令、context 键集合,全部逐字比对。
 */
function normalizeLive(error: any, timeoutMs?: number): any {
  const copy = JSON.parse(JSON.stringify(error));
  copy.guidance.context.home = GOLDEN_HOME;
  copy.guidance.context.socketPath = GOLDEN_SOCKET;
  if (timeoutMs !== undefined) {
    copy.message = copy.message.replace(String(timeoutMs), String(GOLDEN_TIMEOUT_MS));
    copy.guidance.context.timeoutMs = String(GOLDEN_TIMEOUT_MS);
  }
  return copy;
}

const GOLDEN_HOME = "/Users/alice/.a2";
const GOLDEN_SOCKET = "/Users/alice/.a2/run/kernel.sock";
const GOLDEN_TIMEOUT_MS = 120000;

async function goldenError(file: string): Promise<any> {
  return (await Bun.file(path.resolve(import.meta.dir, "../contract/golden", file)).json()).error;
}

test("活体默拒报文 ≡ 金标 response-confirmation-unavailable(除 id 与路径类字段)", async () => {
  daemon = await startDaemon(home);

  const body = parseJsonStdout(await wipe());

  expect(normalizeLive(body.error)).toEqual(await goldenError("response-confirmation-unavailable.json"));
}, 20000);

test("活体拒绝报文 ≡ 金标 response-confirmation-denied(除 id 与路径类字段)", async () => {
  daemon = await startDaemon(home);
  const confirmer = await fakeClient({ behavior: "deny", reason: "这台机器上不许 wipe" });
  await confirmer.register("confirm-agent");

  const body = parseJsonStdout(await wipe());

  expect(normalizeLive(body.error)).toEqual(await goldenError("response-confirmation-denied.json"));
}, 20000);

test("活体超时报文 ≡ 金标 response-confirmation-timeout(除 id、路径类字段与超时窗口值)", async () => {
  daemon = await startDaemon(home, { A2_CONFIRM_TIMEOUT_MS: "400" });
  const confirmer = await fakeClient({ behavior: "ignore" });
  await confirmer.register("confirm-agent");

  const body = parseJsonStdout(await wipe());

  expect(normalizeLive(body.error, 400)).toEqual(
    await goldenError("response-confirmation-timeout.json"),
  );
}, 20000);
