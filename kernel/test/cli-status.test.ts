// CLI 缝(最高缝):`a2 status --json` 的行为契约。
// 这里只断言外部可观察的东西 —— stdout 的 JSON、退出码、文件系统副作用。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import {
  cleanupHome,
  makeHome,
  parseJsonStdout,
  runCli,
  socketPathFor,
  startDaemon,
  stopDaemon,
  type DaemonHandle,
} from "./support/harness.ts";

let home: string;
let daemon: DaemonHandle | undefined;

beforeEach(async () => {
  home = await makeHome();
  daemon = undefined;
});

afterEach(async () => {
  if (daemon) await stopDaemon(daemon);
  await cleanupHome(home);
});

test("daemon 未运行时:结构化错误 + 精确修复指引 + 退出码 4,且绝不隐式拉起 daemon", async () => {
  const result = await runCli(["status", "--json"], { home });

  expect(result.exitCode).toBe(4);

  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("daemon_unreachable");

  // 拒绝即指引:报文自带机器可读的「人类如何完成」精确命令。
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("a2 service install");
  expect(commands).toContain("a2 daemon run");

  // 指引里带上算出的 socket 路径,agent 不必自己猜 A2_HOME 的展开结果。
  expect(body.error.guidance.context.socketPath).toBe(socketPathFor(home));

  // 「永不隐式拉起」:查询之后系统状态一点没变。
  expect(existsSync(socketPathFor(home))).toBe(false);
});

test("daemon 运行中:status --json 走完整 UDS 往返,返回运行态快照并以 0 退出", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(["status", "--json"], { home });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(body.v).toBe(1);
  expect(body.result.state).toBe("running");
  expect(body.result.protocol).toBe(1);
  // 快照报的是**那个 daemon 进程**,不是 CLI 自己。
  expect(body.result.pid).toBe(daemon.proc.pid);
  expect(body.result.home).toBe(home);
  expect(body.result.socketPath).toBe(socketPathFor(home));
  expect(body.result.uptimeMs).toBeGreaterThanOrEqual(0);
  expect(Number.isNaN(Date.parse(body.result.startedAt))).toBe(false);
});

test("A2_HOME 隔离:两个 home 各起各的 daemon,status 只看见自己那个", async () => {
  daemon = await startDaemon(home);
  const otherHome = await makeHome();
  try {
    const mine = parseJsonStdout(await runCli(["status", "--json"], { home }));
    const theirs = await runCli(["status", "--json"], { home: otherHome });

    expect(mine.result.socketPath).toBe(socketPathFor(home));
    // 另一个 A2_HOME 下没有 daemon:不可达,且指引里的路径是**它自己的**,不是我的。
    expect(theirs.exitCode).toBe(4);
    const body = parseJsonStdout(theirs);
    expect(body.error.code).toBe("daemon_unreachable");
    expect(body.error.guidance.context.socketPath).toBe(socketPathFor(otherHome));
  } finally {
    await cleanupHome(otherHome);
  }
});
