// 起一个子进程、把它的两条流收干净 —— 插件调用(`protocol.ts`)与装载期工具链(`bundle.ts`)
// 共用的那一段。**只有这里知道"子进程怎么收场"**,上面两层只管翻译收场的含义。
//
// 三条纪律,每条都是被真事撞出来的(11 票 CR 尾款 b/c):
//
//   ① **超时与读流赛跑,不是"杀完接着等"**。插件可以 spawn 自己的孙进程;孙进程继承了 stdout,
//      于是即使内核把直接子进程 SIGKILL 了,那根 pipe 依然没有 EOF —— `new Response(stdout).text()`
//      会**永远不返回**,超时形同虚设。所以这里的等待是 `Promise.race([读完, 超时, 超限])`:
//      时钟一到就带着**已经收到的那部分**返回,绝不把内核的可用性押在插件的子孙身上。
//
//   ② **输出有上限**(默认 4MiB)。stdout 是插件唯一的机读面,一行 JSON 而已;它要是打算吐一个
//      GB 进来,那不是"输出多",那是内核的内存被插件说了算。超限即杀 + 结构化错误。
//
//   ③ **不吹"不留孤儿"**。SIGKILL 只作用在**直接子进程**上:Bun.spawn 没有 detached/进程组的口子
//      (实测口径见 02 票 spike),内核也不能 `kill(-pgid)` —— 那个进程组里还有内核自己。
//      所以诚实的账是:直接子进程必被杀;它派生的孙进程**可能活下来**,内核只保证自己不被它挂住。
//      要根治得等到有进程组/作业对象的口子,那是运行时能力问题,不是这里能糊过去的。

/** 输出上限(stdout / stderr 各自计):4MiB。到顶即杀 + 结构化错误,不做静默截断。 */
export const OUTPUT_LIMIT_BYTES = 4 * 1024 * 1024;

export interface CaptureOptions {
  cwd?: string;
  /** 子进程的环境**全集**(调用方自己过白名单 —— 这里不替谁做决定)。 */
  env: Record<string, string>;
  stdin?: string;
  timeoutMs: number;
  limitBytes?: number;
}

export interface CaptureResult {
  /** 超时/超限被杀时无意义(那两个标志才是收场的判据)。 */
  exitCode: number;
  stdout: string;
  stderr: string;
  /** 超时被杀(带着已收到的那部分输出返回)。 */
  timedOut: boolean;
  /** 哪条流撞了上限(超限即杀)。 */
  overflow?: "stdout" | "stderr";
  /** 子进程 pid —— 「插件在进程外」这条红线的活体证据。 */
  pid: number;
  ms: number;
}

interface Sink {
  chunks: Uint8Array[];
  bytes: number;
}

export async function captureProcess(
  cmd: string[],
  options: CaptureOptions,
): Promise<CaptureResult> {
  const started = performance.now();
  const limit = options.limitBytes ?? OUTPUT_LIMIT_BYTES;
  const proc = Bun.spawn({
    cmd,
    ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
    env: options.env,
    stdin: options.stdin === undefined ? "ignore" : new TextEncoder().encode(options.stdin),
    stdout: "pipe",
    stderr: "pipe",
  });
  const pid = proc.pid;

  let timedOut = false;
  let overflow: "stdout" | "stderr" | undefined;
  let stop: (reason: "timeout" | "overflow") => void = () => {};
  const stopped = new Promise<"timeout" | "overflow">((resolve) => {
    stop = resolve;
  });

  const kill = () => {
    try {
      proc.kill("SIGKILL");
    } catch {
      // 已经退了。
    }
  };

  const timer = setTimeout(() => {
    timedOut = true;
    // 先礼后兵没有意义:插件是一次性进程,它卡住时没有"收摊"要做。
    kill();
    stop("timeout");
  }, options.timeoutMs);

  const out: Sink = { chunks: [], bytes: 0 };
  const err: Sink = { chunks: [], bytes: 0 };
  const onOverflow = (which: "stdout" | "stderr") => {
    if (overflow === undefined) overflow = which;
    kill();
    stop("overflow");
  };

  const drained = Promise.all([
    drain(proc.stdout as ReadableStream<Uint8Array>, out, limit, () => onOverflow("stdout")),
    drain(proc.stderr as ReadableStream<Uint8Array>, err, limit, () => onOverflow("stderr")),
  ]).then(async () => {
    await proc.exited;
  });

  await Promise.race([drained, stopped]);
  clearTimeout(timer);

  return {
    exitCode: proc.exitCode ?? -1,
    stdout: decode(out),
    stderr: decode(err),
    timedOut,
    ...(overflow === undefined ? {} : { overflow }),
    pid,
    ms: Math.round(performance.now() - started),
  };
}

/**
 * 把一条流读到底(或读到上限)。读流抛错(进程被杀时会)一律咽掉 —— 收场的判据是
 * `timedOut` / `overflow` / 退出码,不是"读流那一刻抛没抛"。
 */
async function drain(
  stream: ReadableStream<Uint8Array>,
  sink: Sink,
  limit: number,
  onOverflow: () => void,
): Promise<void> {
  const reader = stream.getReader();
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) return;
      if (value === undefined || value.byteLength === 0) continue;
      sink.chunks.push(value);
      sink.bytes += value.byteLength;
      if (sink.bytes > limit) {
        onOverflow();
        return;
      }
    }
  } catch {
    return;
  } finally {
    try {
      await reader.cancel();
    } catch {
      // 流已经关了。
    }
  }
}

/** **先拼字节再 decode**:分片边界与字符边界互不相干,先 decode 会把半个汉字解成 U+FFFD。 */
function decode(sink: Sink): string {
  if (sink.chunks.length === 0) return "";
  const merged = new Uint8Array(sink.bytes);
  let offset = 0;
  for (const chunk of sink.chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(merged);
}
