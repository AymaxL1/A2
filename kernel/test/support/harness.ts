// 测试夹具:在 CLI 缝(argv 进、stdout JSON + 退出码出)上驱动 a2。
//
// 两种被测体,同一套断言:
//   * 缺省:`bun run src/cli/main.ts …`(快,日常红绿循环用)
//   * `A2_TEST_BIN=<path>`:直接跑 `bun build --compile` 出的单文件 bin(scripts/build.sh 用)
// 这样"编译产物真能跑"与"源码行为对不对"是同一批测试,不写两遍。
//
// 纪律:每个测试自带临时 A2_HOME(/tmp 短路径,避开 sockaddr_un 104 字节上限),
// 绝不落用户真实 ~/.a2;daemon 一律经 stopDaemon() 收尸,不留孤儿进程。

import { mkdtemp, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

const CLI_ENTRY = path.resolve(import.meta.dir, "../../src/cli/main.ts");

/** 被测的 a2 命令行(编译产物或源码入口)。 */
export function a2Command(): string[] {
  const bin = process.env.A2_TEST_BIN;
  if (bin) return [bin];
  return [process.execPath, "run", CLI_ENTRY];
}

/** 一次性临时 A2_HOME(调用方负责 cleanupHome)。 */
export async function makeHome(): Promise<string> {
  return await mkdtemp("/tmp/a2t-");
}

export async function cleanupHome(home: string): Promise<void> {
  await rm(home, { recursive: true, force: true });
}

/** 该 A2_HOME 下的 socket 路径(测试自己拼一次,用于断言内核算出的路径与约定一致)。 */
export function socketPathFor(home: string): string {
  return path.join(home, "run", "kernel.sock");
}

export interface CliResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

/** 跑一条 a2 子命令到退出,收 stdout/stderr/退出码。 */
export async function runCli(
  args: string[],
  options: { home: string; env?: Record<string, string> } ,
): Promise<CliResult> {
  const proc = Bun.spawn({
    cmd: [...a2Command(), ...args],
    env: { ...process.env, A2_HOME: options.home, ...options.env },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  await proc.exited;
  return { exitCode: proc.exitCode ?? -1, stdout, stderr };
}

/** stdout 必须是单条 JSON(agent 面的硬要求:机读输出不掺散文)。 */
export function parseJsonStdout(result: CliResult): any {
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(
      `stdout 不是合法 JSON(exit=${result.exitCode}):\n${result.stdout}\n--- stderr ---\n${result.stderr}`,
    );
  }
}

export interface DaemonHandle {
  home: string;
  socketPath: string;
  proc: Bun.Subprocess;
  stdout(): Promise<string>;
}

/** 前台起一个 daemon 并等到 socket 可连接;失败即抛,绝不留孤儿。 */
export async function startDaemon(home: string): Promise<DaemonHandle> {
  const proc = Bun.spawn({
    cmd: [...a2Command(), "daemon", "run"],
    env: { ...process.env, A2_HOME: home },
    stdout: "pipe",
    stderr: "pipe",
  });
  const socketPath = socketPathFor(home);
  const handle: DaemonHandle = {
    home,
    socketPath,
    proc,
    stdout: async () => await new Response(proc.stdout).text(),
  };
  try {
    await waitForSocket(socketPath);
  } catch (error) {
    await stopDaemon(handle);
    const stderr = await new Response(proc.stderr).text();
    throw new Error(`daemon 起不来:${(error as Error).message}\n--- stderr ---\n${stderr}`);
  }
  return handle;
}

/** SIGTERM 收尸,等进程真退出(测试 teardown 必调,trap 兜底见 scripts/build.sh)。 */
export async function stopDaemon(handle: DaemonHandle): Promise<void> {
  if (handle.proc.killed) return;
  handle.proc.kill("SIGTERM");
  await handle.proc.exited;
}

/** 轮询到 socket 真能连上为止(存在 ≠ 能连,stale socket 文件也存在)。 */
export async function waitForSocket(socketPath: string, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastError = "未开始";
  while (Date.now() < deadline) {
    if (existsSync(socketPath)) {
      try {
        // 注:Bun.connect 至少要一个 data/drain 回调,空 handler 会 TypeError。
        const socket = await Bun.connect({ unix: socketPath, socket: { data() {} } });
        socket.end();
        return;
      } catch (error) {
        lastError = String(error);
      }
    } else {
      lastError = `socket 不存在:${socketPath}`;
    }
    await Bun.sleep(20);
  }
  throw new Error(`等 socket 超时(${timeoutMs}ms):${lastError}`);
}

/**
 * 直连 UDS 发一行 JSON、读一行响应 —— 用于 UDS 协议面(绕开 CLI)的断言。
 *
 * **有意不复用 `src/contract/ndjson.ts` 与 `src/client/uds-client.ts`**:这是测试对线协议的**独立实现**。
 * 若拆行或帧格式在实现侧写歪了,用被测代码去读被测代码的输出只会一起歪、测试照绿;这里手写一遍,
 * 才能让"实现改了行为"与"契约变了"吵起来。08 票把 UDS 改成长连接时,这份夹具应当**独立地**跟着改。
 */
export async function sendRawLine(socketPath: string, line: string, timeoutMs = 5000): Promise<string> {
  let resolveResponse: (value: string) => void;
  let rejectResponse: (reason: Error) => void;
  const response = new Promise<string>((resolve, reject) => {
    resolveResponse = resolve;
    rejectResponse = reject;
  });
  let buffer = "";
  const socket = await Bun.connect({
    unix: socketPath,
    socket: {
      data(_socket, chunk) {
        buffer += chunk.toString();
        const newline = buffer.indexOf("\n");
        if (newline >= 0) resolveResponse(buffer.slice(0, newline));
      },
      error(_socket, error) {
        rejectResponse(error as Error);
      },
      close() {
        rejectResponse(new Error(`连接关闭但未收到整行响应:${JSON.stringify(buffer)}`));
      },
    },
  });
  socket.write(line.endsWith("\n") ? line : `${line}\n`);
  const timer = setTimeout(() => rejectResponse!(new Error(`等响应超时(${timeoutMs}ms)`)), timeoutMs);
  try {
    return await response;
  } finally {
    clearTimeout(timer);
    socket.end();
  }
}
