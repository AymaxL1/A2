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

/**
 * **全局兜底:任何被测进程都别想碰到真的 `networksetup`。**
 *
 * 为什么需要它:`NetworkSetupPort` 的默认实现走**绝对路径** `/usr/sbin/networksetup`,
 * 所以"把 PATH 钉死成假件目录"这道防线对它**无效**(PATH 只挡按名字查找的 launchctl/systemctl)。
 * 哪个测试忘了注入,内核就会去动用户真机的系统代理 —— 用户此刻的网络多半正靠他自己的代理活着。
 *
 * 于是这里默认把它指到一个**一执行就大声失败**的假件;真要验系统代理行为的测试经
 * `proxy-sandbox.ts` 显式覆写成同目录下的行为假件。默认值排在 `...options.env` **之前**,覆写永远赢。
 */
const FORBIDDEN_NETWORKSETUP = path.resolve(
  import.meta.dir,
  "fake-networksetup/networksetup-forbidden",
);

/**
 * **同一道防线,url-router 那四个外部程序的那一份**(02 票)。
 *
 * 理由与上面逐字相同,只是后果更露骨:`url-router.route` 的默认实现走 `/usr/bin/open`,
 * 哪个测试忘了注入,门禁就会**真在跑测试的人脸上弹出一个浏览器窗口**;而 `/bin/ps` 那一路
 * 更阴——它读的是真进程表,于是同一条测试在"开着 RoxyBrowser"和"没开"的机器上结论不同。
 *
 * 所以四个都默认指到一执行就失败的假件;要验行为的测试经 `fake-url-router/sandbox.ts` 显式覆写。
 */
const FORBIDDEN_URL_ROUTER = path.resolve(import.meta.dir, "fake-url-router/forbidden");
const URL_ROUTER_GUARD: Record<string, string> = {
  A2_URL_ROUTER_PS: FORBIDDEN_URL_ROUTER,
  A2_URL_ROUTER_LSOF: FORBIDDEN_URL_ROUTER,
  A2_URL_ROUTER_OPEN: FORBIDDEN_URL_ROUTER,
  A2_URL_ROUTER_DEFAULTS: FORBIDDEN_URL_ROUTER,
};

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
    env: {
      ...process.env,
      A2_HOME: options.home,
      A2_NETWORKSETUP: FORBIDDEN_NETWORKSETUP,
      ...URL_ROUTER_GUARD,
      ...options.env,
    },
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
  /**
   * daemon 的 stderr 全文。**只在 `stopDaemon` 之后取得到**(流要等进程退出才收尾),
   * 用于断言那些"降级但照常启动"的生命周期事件 —— 它们不进任何机读面,只落这里。
   */
  stderr(): Promise<string>;
}

/**
 * 前台起一个 daemon 并等到 socket 可连接;失败即抛,绝不留孤儿。
 *
 * `env` 是 07 票加的:代理域能力**跑在 daemon 进程里**,所以沙盒的那套注入
 * (假 supervisor 的 PATH、假 networksetup、mihomo 扫描面……)必须一并喂给它,
 * 否则 daemon 会拿着真环境去看世界。
 */
export async function startDaemon(
  home: string,
  env: Record<string, string> = {},
): Promise<DaemonHandle> {
  const proc = Bun.spawn({
    cmd: [...a2Command(), "daemon", "run"],
    env: {
      ...process.env,
      A2_HOME: home,
      A2_NETWORKSETUP: FORBIDDEN_NETWORKSETUP,
      ...URL_ROUTER_GUARD,
      ...env,
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const socketPath = socketPathFor(home);
  // 两条流各只能被读一次 —— 缓存下来,让 `stderr()` 既能给启动失败的诊断用、也能给断言用。
  let stderrText: Promise<string> | undefined;
  const handle: DaemonHandle = {
    home,
    socketPath,
    proc,
    stdout: async () => await new Response(proc.stdout).text(),
    stderr: async () => {
      stderrText ??= new Response(proc.stderr).text();
      return await stderrText;
    },
  };
  try {
    await waitForSocket(socketPath);
  } catch (error) {
    await stopDaemon(handle);
    throw new Error(
      `daemon 起不来:${(error as Error).message}\n--- stderr ---\n${await handle.stderr()}`,
    );
  }
  return handle;
}

/** SIGTERM 收尸,等进程真退出(测试 teardown 必调,trap 兜底见 scripts/build.sh)。 */
export async function stopDaemon(handle: DaemonHandle): Promise<void> {
  if (handle.proc.killed) return;
  handle.proc.kill("SIGTERM");
  const exitCode = await handle.proc.exited;
  // **exit-0 红线**(14 票 / CR M8):KeepAlive 双键(SuccessfulExit:false)下,主动停止路径
  // 必须以 0 收尾,否则 launchd 会把刚停的服务顶回来。每一次测试停 daemon 都是一次断言。
  if (exitCode !== 0) {
    throw new Error(`daemon 对 SIGTERM 的退出码是 ${exitCode},不是 0 —— KeepAlive.SuccessfulExit=false 会把它顶回来`);
  }
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
 * 直连 UDS 发一行 JSON、读回**属于这条请求的那一行响应** —— 用于 UDS 协议面(绕开 CLI)的断言。
 *
 * **有意不复用 `src/contract/ndjson.ts` 与 `src/client/uds-client.ts`**:这是测试对线协议的**独立实现**。
 * 若拆行或帧格式在实现侧写歪了,用被测代码去读被测代码的输出只会一起歪、测试照绿;这里手写一遍,
 * 才能让"实现改了行为"与"契约变了"吵起来。
 *
 * **08 票的长连接改造在这里是独立做的**(04 票交接单的要求):连接上现在可能先来若干**推送帧**
 * (`{"push":true,…}`),响应才在后面。判据是**结构性的**:有 `ok` 的是响应,有 `push` 的是推送。
 * 这里刻意手写这条判据,而不是 import 契约里的 `ServerFrameSchema` —— 判别方式若被实现悄悄改了,
 * 这份夹具要能吵起来。推送帧一律丢弃(要收推送请用 `fake-client.ts`)。
 *
 * 拆行同样**在字节层面**独立做一遍:分片边界可能切在多字节字符中间,先 `toString()` 就会把半个汉字
 * 解成 U+FFFD。实现侧有 `contract/ndjson.ts` 守这件事,这里手写第二份 —— 两边一起写歪的概率才够低。
 */
export async function sendRawLine(socketPath: string, line: string, timeoutMs = 5000): Promise<string> {
  let resolveResponse: (value: string) => void;
  let rejectResponse: (reason: Error) => void;
  const response = new Promise<string>((resolve, reject) => {
    resolveResponse = resolve;
    rejectResponse = reject;
  });
  let buffer = new Uint8Array(0);
  const decoder = new TextDecoder();
  const socket = await Bun.connect({
    unix: socketPath,
    socket: {
      data(_socket, chunk) {
        const merged = new Uint8Array(buffer.length + chunk.length);
        merged.set(buffer, 0);
        merged.set(chunk, buffer.length);
        buffer = merged;
        let newline = buffer.indexOf(0x0a);
        while (newline >= 0) {
          // **整行到齐了才 decode** —— 分片边界与字符边界互不相干。
          const frame = decoder.decode(buffer.subarray(0, newline));
          buffer = buffer.slice(newline + 1);
          if (frame.trim().length > 0 && !isPushFrame(frame)) {
            resolveResponse(frame);
            return;
          }
          newline = buffer.indexOf(0x0a);
        }
      },
      error(_socket, error) {
        rejectResponse(error as Error);
      },
      close() {
        rejectResponse(
          new Error(`连接关闭但未收到整行响应:${JSON.stringify(decoder.decode(buffer))}`),
        );
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

/** 一帧是不是推送(而不是响应)。手写判据,见 `sendRawLine` 文件内注释的理由。 */
function isPushFrame(frame: string): boolean {
  try {
    const parsed = JSON.parse(frame);
    return parsed !== null && typeof parsed === "object" && (parsed as { push?: unknown }).push === true;
  } catch {
    return false;
  }
}
