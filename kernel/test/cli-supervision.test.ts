// CLI 缝:存活监督(07 票)—— daemon 里那条**只读**观测循环。
//
// 它要证的三件事(14 票改判后的口径):
//   1. 实例掉了会产出**结构化报警**(带「人类如何完成」的指引),而重拉归 child.ts(节流/故障态),观测者自己不动手;
//   2. 观测本身对系统状态**零影响**(不写配置、不动系统代理);
//   3. **杀掉内核 daemon,内嵌 mihomo 随之停下(随 a2 生死);系统代理不变;内核回来后子进程与监督恢复**。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ProxySupervisionResultSchema } from "../src/contract/wire.ts";
import { connectFakeClient } from "./support/fake-client.ts";
import { runCli, stopDaemon } from "./support/harness.ts";
import {
  cleanupProxySandbox,
  isAlive,
  makeProxySandbox,
  networkCalls,
  networkState,
  INITIAL_NETWORK_STATE,
  out,
  provisionManaged,
  proxy,
  startForeignInstance,
  startProxyDaemon,
  waitFor,
  type ProxySandbox,
} from "./support/proxy-sandbox.ts";

const GROUPS = "PROXY=A1,A2;GLOBAL=,A1";

let sandbox: ProxySandbox | undefined;

beforeEach(() => {
  sandbox = undefined;
});

afterEach(async () => {
  if (sandbox) await cleanupProxySandbox(sandbox);
  sandbox = undefined;
});

async function supervision(box: ProxySandbox) {
  return out(await proxy(box, ["supervision"]));
}

/** 等到观测里出现某一类事件为止。 */
async function waitForEvent(box: ProxySandbox, kind: string): Promise<any> {
  let found: any;
  await waitFor(`观测事件 ${kind}`, async () => {
    const snapshot = await supervision(box);
    found = (snapshot.events as { kind: string }[]).find((event) => event.kind === kind);
    return found !== undefined;
  });
  return found;
}

/** 等观测循环真正看见实例活着(首拍 watch_started 可能记录于子进程还在拉起的瞬间)。 */
async function waitAlive(box: ProxySandbox): Promise<void> {
  await waitFor("观测认到 alive", async () => (await supervision(box)).alive === true);
}

async function managedPid(box: ProxySandbox): Promise<number> {
  const result = await runCli(["mihomo", "status", "--json"], { home: box.home, env: box.env });
  return JSON.parse(result.stdout).result.embedded.pid as number;
}

// MARK: - 观测在跑

test("supervision:daemon 一起来就盯着自管实例,checks 会涨,事件落进 NDJSON 日志", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  await provisionManaged(box);
  await startProxyDaemon(box);

  const started = await waitForEvent(box, "watch_started");
  expect(started.owner).toBe("a2");
  expect(started.controller).toBe(`127.0.0.1:${box.controllerPort}`);
  await waitAlive(box);

  const snapshot = await supervision(box);
  expect(ProxySupervisionResultSchema.safeParse(snapshot).success).toBe(true);
  expect(snapshot.watching).toBe(true);
  expect(snapshot.alive).toBe(true);
  expect(snapshot.target.owner).toBe("a2");
  expect(snapshot.target.managed).toBe(true);
  expect(snapshot.checks).toBeGreaterThan(0);
  expect(snapshot.logPath).toBe(box.supervisionLog);

  // 事件全量落在 NDJSON 文件里(08 票的推送面直接拿这份载荷)。
  const log = await readFile(box.supervisionLog, "utf8");
  const lines = log.split("\n").filter((line) => line.length > 0);
  expect(lines.length).toBeGreaterThan(0);
  expect(JSON.parse(lines[0] as string).kind).toBe("watch_started");
}, 30000);

test("supervision:实例掉了 → instance_down + 指引;a2 **自己把它重拉回来** → instance_up(14 票:保活归内核)", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  await provisionManaged(box);
  await startProxyDaemon(box);
  await waitForEvent(box, "watch_started");
  await waitAlive(box);

  const pid = await managedPid(box);
  process.kill(pid, "SIGKILL");
  await waitFor("mihomo 进程真的没了", () => !isAlive(pid));

  const down = await waitForEvent(box, "instance_down");
  expect(down.owner).toBe("a2");
  // **报警自带「人类如何完成」**(与 status 故障态同一口径:restart,不再是 install)。
  const commands = down.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("a2 mihomo restart --json");

  // 14 票改判:内嵌子进程的保活归 a2 亲管 —— 节流之后它**自己**回来,不需要人。
  const up = await waitForEvent(box, "instance_up");
  expect(up.owner).toBe("a2");
  await waitFor("重拉后的子进程可达", async () => (await supervision(box)).alive === true);
  const revived = await managedPid(box);
  expect(revived).not.toBe(pid);
  expect(isAlive(revived)).toBe(true);

  // 全程没有一条 supervisor 命令:重拉是 child.ts 干的,launchd 与它无关(全机只剩 com.a2.kernel 一个 unit)。
  const calls = (await readFile(box.supervisorLog, "utf8")).split("\n").filter((l) => l.length > 0);
  expect(calls).toEqual([]);
}, 40000);

test("supervision:别人的实例在跑也**不进观测循环** —— 没有可盯的对象就如实说没有,不报警", async () => {
  const box = (sandbox = await makeProxySandbox());
  await startForeignInstance(box, { groups: "PROXY=F1" });
  // 14 票:双模式取代拒绝闸。observe = 只读旁观,**有意不进观测循环**(不对别人的进程做常驻监督)。
  // 08 票改判(2026-08-21):`enable --mode=observe` 的入口随检测面一并临时关闭,于是模式**直接落盘**
  // ——盘上的 observe 仍是合法态(契约词表一个字没改),本用例验的那件事(不进观测循环)也一字未改。
  await mkdir(path.join(box.home, "mihomo"), { recursive: true });
  await writeFile(
    path.join(box.home, "mihomo", "settings.json"),
    `${JSON.stringify({ managedMode: "observe" })}\n`,
  );
  await startProxyDaemon(box);

  // 等够几个观测周期,确认它一直没认领任何目标。
  await Bun.sleep(600);
  const snapshot = await supervision(box);
  expect(snapshot.watching).toBe(true);
  expect(snapshot.target).toBeUndefined();
  // 「没有对象」不是「对象死了」:一条 instance_down 都不该出现,否则等于替一个不归我们管的
  // 进程发假警报(而它此刻恰恰活得好好的)。
  expect(snapshot.events.some((e: { kind: string }) => e.kind === "instance_down")).toBe(false);
  expect(isAlive(box.foreignProc!.pid)).toBe(true);

  // 观测者对 supervisor 一条命令都没有(observe 连 unit 都不涉及)。
  const calls = (await readFile(box.supervisorLog, "utf8")).split("\n").filter((l) => l.length > 0);
  expect(calls).toEqual([]);
}, 40000);

// MARK: - 票面第 4 条:杀掉内核 daemon

test("杀掉内核 daemon:内嵌 mihomo **随之停下**(14 票:随 a2 生死);系统代理不变;内核回来后子进程与监督恢复", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  await provisionManaged(box);
  await startProxyDaemon(box);
  await waitForEvent(box, "watch_started");
  await proxy(box, ["on"]);

  const pidBefore = await managedPid(box);
  const netBefore = await networkState(box);

  // 内核 daemon 整个没了(等价于崩溃 / `a2 service uninstall`)。
  await stopDaemon(box.daemon!);
  box.daemon = undefined;
  await waitFor("内嵌 mihomo 随 daemon 停下", () => !isAlive(pidBefore));

  // **14 票改判**:「数据面不随控制面起落」废除 —— a2 死则 mihomo 死,这是「小白第一」显式收下的代价。
  // `a2 mihomo status` 不经 daemon,daemon 没跑的时候它恰恰最该能答话:如实报 stopped,不臆造。
  const detached = await runCli(["mihomo", "status", "--json"], { home: box.home, env: box.env });
  expect(detached.exitCode).toBe(0);
  const detachedStatus = JSON.parse(detached.stdout).result;
  expect(detachedStatus.mode).toBe("embedded");
  expect(detachedStatus.embedded.state).toBe("stopped");
  // 系统代理**纹丝不动**(「退出即还原」仍是废除态:还原只有显式命令一条路)。
  expect(await networkState(box)).toEqual(netBefore);
  expect(netBefore).not.toEqual(INITIAL_NETWORK_STATE);

  // 内核回来:子进程按落盘的模式重建(新 pid),观测重新盯上同一个端点。
  await startProxyDaemon(box);
  await waitForEvent(box, "watch_started");
  await waitAlive(box);
  const snapshot = await supervision(box);
  expect(snapshot.watching).toBe(true);
  expect(snapshot.alive).toBe(true);
  expect(snapshot.target.controller).toBe(`127.0.0.1:${box.controllerPort}`);
  const pidAfter = await managedPid(box);
  expect(pidAfter).not.toBe(pidBefore);
  expect(isAlive(pidAfter)).toBe(true);

  // 日志是**追加**的:上一世代的事件还在,新世代接在后面。
  const lines = (await readFile(box.supervisionLog, "utf8")).split("\n").filter((l) => l.length > 0);
  expect(lines.filter((line) => JSON.parse(line).kind === "watch_started").length).toBe(2);
  expect(lines.some((line) => JSON.parse(line).kind === "watch_stopped")).toBe(true);
}, 40000);

test("观测是只读的:整场没有对系统代理发过任何写调用", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  await provisionManaged(box);
  await startProxyDaemon(box);
  await waitForEvent(box, "watch_started");
  // 让它多探几轮(间隔 200ms)。
  await Bun.sleep(800);

  expect((await supervision(box)).checks).toBeGreaterThan(2);
  // 观测循环从不碰 networksetup —— 一条调用都没有(连读都没有)。
  expect(await networkCalls(box)).toEqual([]);
  expect(await networkState(box)).toEqual(INITIAL_NETWORK_STATE);
}, 30000);

// MARK: - 08 票:同一份事件推给订阅者(07 票留的账)
//
// 07 票在 `proxy/supervision.ts` 文件头写下:「本票产出的 ProxySupervisionEvent **就是**将来要推的
// 那份载荷,形状不变 —— 08 票只需把它发出去」。下面这条就是那句话的活体证据:
// 订阅者收到的 `supervision` 事件与 `proxy supervision` 查到的那一条**逐字段相等**。

test("supervision:事件同时推给订阅者,载荷与查询到的那一条逐字段相等(零轮询)", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  await provisionManaged(box);
  await startProxyDaemon(box);

  const subscriber = await connectFakeClient({
    socketPath: box.daemon!.socketPath,
    name: "fake-shell",
  });
  try {
    await subscriber.register("subscriber");
    await waitAlive(box);

    // 让实例掉下去 —— 这是"状态真的变了"的那一刻。
    const pid = await managedPid(box);
    process.kill(pid, "SIGKILL");
    await waitFor("mihomo 进程真的没了", () => !isAlive(pid));

    const pushed = await subscriber.waitForEvent(
      (event) => event.kind === "supervision" && event.supervision.kind === "instance_down",
      10000,
    );
    const queried = await waitForEvent(box, "instance_down");

    // **同一份载荷**:07 票的形状一字未改,08 票只是多了一个去处。
    expect(pushed.supervision).toEqual(queried);
    // 订阅者除了那一次注册,一条请求都没发过。
    expect(subscriber.sent).toEqual(["roles.register"]);
  } finally {
    await subscriber.close();
  }
}, 40000);
