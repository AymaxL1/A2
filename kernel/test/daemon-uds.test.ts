// UDS 协议面 + daemon 生命周期。
// 权限断言是本票的安全底线:Bun 的 UDS 文件权限跟随 umask(实测,见 docs/research/ts-kernel-runtime-bun.md §4.3),
// 所以内核必须自建 0700 父目录并在 bind 后显式收紧 socket —— 这里断言的是**结果**,不是内核怎么实现的。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, statSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  cleanupHome,
  makeHome,
  parseJsonStdout,
  runCli,
  sendRawLine,
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

test("daemon run 在 $A2_HOME/run/kernel.sock 起 UDS:父目录 0700,socket 仅本人可读写", async () => {
  daemon = await startDaemon(home);

  const runDirMode = statSync(path.join(home, "run")).mode & 0o777;
  expect(runDirMode).toBe(0o700);

  const socketStat = statSync(socketPathFor(home));
  expect(socketStat.isSocket()).toBe(true);
  expect(socketStat.mode & 0o777).toBe(0o600);
});

test("UDS 面:一行请求换一行响应,id 原样回填", async () => {
  daemon = await startDaemon(home);

  const line = await sendRawLine(
    daemon.socketPath,
    JSON.stringify({ v: 1, id: "req-42", op: "status.get" }),
  );

  const response = JSON.parse(line);
  expect(response.id).toBe("req-42");
  expect(response.ok).toBe(true);
  expect(response.v).toBe(1);
  expect(response.result.state).toBe("running");
  expect(response.error).toBeUndefined();
});

test("UDS 面:坏 JSON → bad_request(不炸 daemon,连接照常可用)", async () => {
  daemon = await startDaemon(home);

  const bad = JSON.parse(await sendRawLine(daemon.socketPath, "{ 这不是 JSON"));
  expect(bad.ok).toBe(false);
  expect(bad.error.code).toBe("bad_request");
  expect(typeof bad.id).toBe("string");

  // daemon 还活着:坏报文只毙掉那一条请求。
  const good = JSON.parse(
    await sendRawLine(daemon.socketPath, JSON.stringify({ v: 1, id: "after-bad", op: "status.get" })),
  );
  expect(good.ok).toBe(true);
  expect(good.id).toBe("after-bad");
});

test("UDS 面:未知 op → unknown_op 且列出本版已登记的 op", async () => {
  daemon = await startDaemon(home);

  const response = JSON.parse(
    await sendRawLine(daemon.socketPath, JSON.stringify({ v: 1, id: "req-op", op: "no.such.op" })),
  );

  expect(response.ok).toBe(false);
  expect(response.id).toBe("req-op");
  expect(response.error.code).toBe("unknown_op");
  expect(response.error.detail).toContain("status.get");
});

test("UDS 面:包封不合法(协议版本错/缺 op)→ bad_request,并把对方的 id 捞回来", async () => {
  daemon = await startDaemon(home);

  const wrongVersion = JSON.parse(
    await sendRawLine(daemon.socketPath, JSON.stringify({ v: 99, id: "req-v", op: "status.get" })),
  );
  expect(wrongVersion.ok).toBe(false);
  expect(wrongVersion.error.code).toBe("bad_request");
  expect(wrongVersion.id).toBe("req-v");

  const missingOp = JSON.parse(
    await sendRawLine(daemon.socketPath, JSON.stringify({ v: 1, id: "req-noop" })),
  );
  expect(missingOp.ok).toBe(false);
  expect(missingOp.error.code).toBe("bad_request");
  expect(missingOp.id).toBe("req-noop");
});

test("同一个 A2_HOME 起第二个 daemon:拒绝并给指引,不抢已有实例的 socket", async () => {
  daemon = await startDaemon(home);

  const second = await runCli(["daemon", "run", "--json"], { home });

  expect(second.exitCode).toBe(1);
  const body = parseJsonStdout(second);
  expect(body.ok).toBe(false);
  expect(body.error.guidance.steps.map((s: { command?: string }) => s.command)).toContain(
    "a2 status --json",
  );

  // 头一个实例毫发无损:socket 还是它的,还能应答。
  const alive = JSON.parse(
    await sendRawLine(daemon.socketPath, JSON.stringify({ v: 1, id: "still-alive", op: "status.get" })),
  );
  expect(alive.ok).toBe(true);
  expect(alive.result.pid).toBe(daemon.proc.pid);
});

test("上次没收摊干净的陈旧 socket:daemon run 照常起得来(探活不通即清理)", async () => {
  const stale = socketPathFor(home);
  await mkdir(path.dirname(stale), { recursive: true });
  await writeFile(stale, "");

  daemon = await startDaemon(home);

  const response = JSON.parse(
    await sendRawLine(daemon.socketPath, JSON.stringify({ v: 1, id: "after-stale", op: "status.get" })),
  );
  expect(response.ok).toBe(true);
});

test("daemon 收到 SIGTERM 后干净退出:socket 文件不留在磁盘上", async () => {
  const handle = await startDaemon(home);
  expect(existsSync(socketPathFor(home))).toBe(true);

  await stopDaemon(handle);

  expect(existsSync(socketPathFor(home))).toBe(false);
});
