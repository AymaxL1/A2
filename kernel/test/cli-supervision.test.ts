// CLI 缝:存活监督(07 票)—— daemon 里那条**只读**观测循环。
//
// 它要证的三件事:
//   1. 实例掉了会产出**结构化报警**(带「人类如何完成」的指引),而内核**不越权重拉**;
//   2. 它对系统状态**零影响** —— 观测者一旦有权动手,「数据面不随控制面起落」就没人守得住了;
//   3. **杀掉内核 daemon,mihomo 与系统代理都不受影响,内核回来后监督恢复**(票面第 4 条)。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { ProxySupervisionResultSchema } from "../src/contract/wire.ts";
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

async function managedPid(box: ProxySandbox): Promise<number> {
  const result = await runCli(["mihomo", "status", "--json"], { home: box.home, env: box.env });
  return JSON.parse(result.stdout).result.managed.pid as number;
}

// MARK: - 观测在跑

test("supervision:daemon 一起来就盯着自管实例,checks 会涨,事件落进 NDJSON 日志", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  await provisionManaged(box);
  await startProxyDaemon(box);

  const started = await waitForEvent(box, "watch_started");
  expect(started.owner).toBe("a2");
  expect(started.controller).toBe(`127.0.0.1:${box.controllerPort}`);

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

test("supervision:实例掉了 → instance_down + 指引;回来了 → instance_up。内核全程没有重拉它", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  await provisionManaged(box);
  await startProxyDaemon(box);
  await waitForEvent(box, "watch_started");

  const pid = await managedPid(box);
  process.kill(pid, "SIGKILL");
  await waitFor("mihomo 进程真的没了", () => !isAlive(pid));

  const down = await waitForEvent(box, "instance_down");
  expect(down.owner).toBe("a2");
  // **报警自带「人类如何完成」**(与 06 票 mihomo install 的拒绝报文同一口径)。
  const commands = down.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("a2 mihomo install --json");
  expect((await supervision(box)).alive).toBe(false);

  // 内核**没有**替它重拉:假 supervisor 那边没多出任何改状态的命令。
  const calls = (await readFile(box.supervisorLog, "utf8")).split("\n").filter((l) => l.length > 0);
  const afterDeath = calls.filter((line) => !line.startsWith("launchctl print "));
  // 只有 install 那几条(写 unit + bootstrap),观测本身一条都没发过。
  expect(afterDeath.every((line) => line.startsWith("launchctl bootstrap "))).toBe(true);

  // 人把它拉回来(这里由测试代劳 —— 现实中是人或 supervisor 的事,不是观测者的事)。
  await runCli(["mihomo", "install", "--json"], { home: box.home, env: box.env });
  const up = await waitForEvent(box, "instance_up");
  expect(up.owner).toBe("a2");
  expect((await supervision(box)).alive).toBe(true);
}, 40000);

test("supervision:被收编的实例死了 → 报警指引明说「生命周期归原托管方」,内核绝不重拉", async () => {
  const box = (sandbox = await makeProxySandbox());
  await startForeignInstance(box, { groups: "PROXY=F1" });
  await runCli(["mihomo", "install", "--json"], { home: box.home, env: box.env });
  await startProxyDaemon(box);

  const started = await waitForEvent(box, "watch_started");
  expect(started.owner).toBe("foreign");
  expect((await supervision(box)).target.managed).toBe(false);

  const pid = box.foreignProc!.pid;
  box.foreignProc!.kill("SIGKILL");
  await box.foreignProc!.exited;
  await waitFor("别人的实例真的没了", () => !isAlive(pid));

  const down = await waitForEvent(box, "instance_down");
  expect(down.owner).toBe("foreign");
  expect(down.guidance.summary).toContain("原托管方");
  const commands = down.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("a2 mihomo install --isolated --json");
  // 那个实例不在任何 a2 的 unit 里,观测者压根没有能碰它的手段。
  const calls = (await readFile(box.supervisorLog, "utf8")).split("\n").filter((l) => l.length > 0);
  expect(calls.every((line) => line.startsWith("launchctl print "))).toBe(true);
}, 40000);

// MARK: - 票面第 4 条:杀掉内核 daemon

test("杀掉内核 daemon:mihomo 的 pid 不变、系统代理不变;内核回来后监督恢复", async () => {
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
  await Bun.sleep(400);

  // **数据面纹丝不动**:同一个 pid 还在跑,控制端点照样答话
  // (`a2 mihomo status` 不经 daemon —— daemon 没跑的时候它恰恰最该能答话)。
  expect(isAlive(pidBefore)).toBe(true);
  const detached = await runCli(["mihomo", "status", "--json"], { home: box.home, env: box.env });
  expect(detached.exitCode).toBe(0);
  const detachedStatus = JSON.parse(detached.stdout).result;
  expect(detachedStatus.managed.pid).toBe(pidBefore);
  expect(detachedStatus.instance.capabilities).toContain("rest_api");
  // 系统代理也纹丝不动(「退出即还原」已废除)。
  expect(await networkState(box)).toEqual(netBefore);
  expect(netBefore).not.toEqual(INITIAL_NETWORK_STATE);

  // 内核回来:观测重新起来,盯的还是同一个端点。
  await startProxyDaemon(box);
  await waitForEvent(box, "watch_started");
  const snapshot = await supervision(box);
  expect(snapshot.watching).toBe(true);
  expect(snapshot.alive).toBe(true);
  expect(snapshot.target.controller).toBe(`127.0.0.1:${box.controllerPort}`);
  expect(await managedPid(box)).toBe(pidBefore);

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
