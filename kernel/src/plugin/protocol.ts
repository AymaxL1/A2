// 内核 → 插件的那条接口:**exec 一次一调**(ADR 0011)。
//
// 一次调用 = 一个进程。内核用**自己**(`process.execPath` + `BUN_BE_BUN=1`)把插件的 `.ts` 拉起来 ——
// 编译产物内部自带完整 Bun 运行时,所以用户机器上不需要装 bun,插件也不需要任何构建步骤。
// 这条机制是 02 票 spike 实测过的(`docs/research/ts-kernel-runtime-bun.md` §3/§8),不是推断。
//
// 三条纪律,每条都是 spike 撞出来的:
//   ① **必带 `--no-install`**(§8.5):Bun 在"整条祖先目录链上找不到 node_modules"时会**联网**
//      自动装包。一个 agent 现场写的插件只要 import 了一个打错字的包名,就会在**调用的那一刻**
//      静默联网 —— 供应链面从装载期漏到调用期。加上这个 flag 就变成 `Cannot find package` 硬错
//      (fail-closed),对正常的零依赖插件**零副作用**(实测输出逐字一致)。
//   ② **stderr 不进 stdout**:插件的 `console.error`、Bun 的异常栈全走 stderr;stdout 上只能有
//      那一行 JSON。内核两条流分开收,stderr 只进错误 detail。
//   ③ **退出码即成败**,且词表封闭(见 `PluginExit`)。不在词表里的非零退出一律按"没跑成"处理,
//      绝不猜它想说什么。
//
// 还有一条不是 spike 撞出来、而是红线要求的:**内核不把自己的坐标递给插件**。
// 子进程环境是**白名单**(见 `pluginEnv`),`A2_HOME` / `A2_*` 一个都不传 —— 插件想找内核的 socket
// 就得自己猜。这不是沙箱(同 UID 下没有真沙箱可言,ADR 0011 的威胁模型对此是诚实的),
// 而是「能力只经协议白名单」这条红线在**内核这一侧**能做到的部分:我不主动递,你就得自己伸手,
// 而"自己伸手"是可审计的行为。

import {
  ErrorCode,
  PLUGIN_PROTOCOL_VERSION,
  PluginCallOutputSchema,
  PluginDescribeResultSchema,
  type Guidance,
  type JsonValue,
  type PluginDescribeResult,
  type WireError,
} from "../contract/wire.ts";
import { OUTPUT_LIMIT_BYTES, captureProcess } from "./spawn.ts";

/**
 * 插件退出码词表(**契约,不是约定俗成**)。02 票 spike 的参考实现按这张表写,
 * 本表也是 `a2 plugin --help` 里印给插件作者看的那一张。
 */
export const PluginExit = {
  /** 成了。`describe` 的清单 / `call` 的 `{ok:true,output}` 在 stdout 上。 */
  ok: 0,
  /** 内核发来的请求报文插件读不懂(坏 JSON、缺 tool)—— 这说明**内核**写错了,正常永不出现。 */
  badRequest: 2,
  /** 工具执行了,业务上失败了。stdout 上是 `{ok:false,error:{message,detail?}}`。 */
  toolFailed: 3,
  /** 内核要调的工具插件不认识 —— 清单与实现漂了(describe 说有,call 说没有)。 */
  unknownTool: 4,
} as const;

/** 默认超时:一次 describe/call 的窗口。spike 实测一次往返 7–11ms,15 秒是极宽松的上限。 */
const DEFAULT_TIMEOUT_MS = 15_000;

/** stderr 进 detail 时的截断长度(排错够用,又不至于让一条错误报文变成日志倾倒场)。 */
const STDERR_DETAIL_LIMIT = 2_000;

/**
 * 一个插件最多能声明多少个工具(sanity 上限,11 票 CR 尾款 c)。
 *
 * 不是"我们觉得够用"——是**登记一个工具就往注册表里加一条能力**:一份 describe 吐十万条,
 * 内核的能力表、快照、每一次 `capabilities list` 的推送就都被它撑爆了。128 条对任何一个
 * 有意义的插件都绰绰有余,超了几乎必然是插件生成清单的代码写飞了,当场说清楚比默默吃下去强。
 */
const MAX_TOOLS_PER_PLUGIN = 128;

export interface PluginRunOptions {
  /** 覆写超时窗口(测试与诊断用:`A2_PLUGIN_TIMEOUT_MS`)。 */
  timeoutMs?: number;
  /** 子进程的工作目录。默认取工件所在目录(登记区),`--no-install` 之外的第二重确定性。 */
  cwd?: string;
  env?: Record<string, string | undefined>;
}

export type PluginOutcome<T> = { ok: true; value: T } | { ok: false; error: WireError };

/**
 * 拉起插件的 argv。**单独导出是为了让「必带 `--no-install`」这条红线有一条直接的断言**——
 * 它是一条只在"没有它时才出事"的纪律(正常插件加不加都一样),没有断言看着就会在某次重构里悄悄丢掉。
 */
export function pluginCommand(artifact: string, args: string[]): string[] {
  return [process.execPath, "--no-install", artifact, ...args];
}

/**
 * 子进程的环境**白名单**。只给"任何进程都需要的那几样",内核自己的坐标一个都不给。
 *
 * `HOME` 也不给:给了就等于把 `~/.a2`(socket 的默认落点)直接送到插件手上。代价是插件读不到
 * `~/.bunfig.toml` 之类的用户级配置 —— 对"零依赖单文件"这个形态而言那本来也不该有影响。
 */
export function pluginEnv(env: Record<string, string | undefined> = process.env): Record<string, string> {
  const allowed = ["PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ"];
  const picked: Record<string, string> = {};
  for (const key of allowed) {
    const value = env[key];
    if (value !== undefined) picked[key] = value;
  }
  // 编译产物要靠它切换成"我是 bun"(源码模式下跑的本来就是 bun,带着也无害)。
  picked["BUN_BE_BUN"] = "1";
  return picked;
}

export interface PluginProcessResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  /** 超时被杀(此时 exitCode 无意义)。 */
  timedOut: boolean;
  /** 哪条流撞了 4MiB 上限(超限即杀,此时 exitCode 同样无意义)。 */
  overflow?: "stdout" | "stderr";
  /** 子进程 pid —— 「插件在进程外」这条红线的活体证据。 */
  pid: number;
}

/**
 * 起一次插件子进程,收 stdout/stderr/退出码。
 *
 * 超时与输出上限都在 `spawn.ts` 里(那里写着为什么"杀完还得停止等待" —— 插件的**孙进程**
 * 会攥着同一根 pipe 不放,只杀直接子进程救不了一个已经挂死的等待)。
 */
export async function runPluginProcess(
  artifact: string,
  args: string[],
  stdin: string | undefined,
  options: PluginRunOptions = {},
): Promise<PluginProcessResult> {
  const env = options.env ?? process.env;
  const captured = await captureProcess(pluginCommand(artifact, args), {
    ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
    env: pluginEnv(env),
    ...(stdin === undefined ? {} : { stdin }),
    timeoutMs: options.timeoutMs ?? readTimeout(env),
  });
  return {
    exitCode: captured.exitCode,
    stdout: captured.stdout,
    stderr: captured.stderr,
    timedOut: captured.timedOut,
    ...(captured.overflow === undefined ? {} : { overflow: captured.overflow }),
    pid: captured.pid,
  };
}

function readTimeout(env: Record<string, string | undefined>): number {
  const raw = env["A2_PLUGIN_TIMEOUT_MS"];
  if (raw === undefined) return DEFAULT_TIMEOUT_MS;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_TIMEOUT_MS;
}

// MARK: - describe

/**
 * 问插件「你有哪些工具」。非法输出(坏 JSON / 缺字段 / 协议号对不上 / 超时)一律变成
 * **结构化错误 + 指引** —— 插件作者(多半是个 agent)拿到它就知道下一步改什么。
 */
export async function describePlugin(
  artifact: string,
  options: PluginRunOptions = {},
): Promise<PluginOutcome<PluginDescribeResult>> {
  const run = await runPluginProcess(artifact, ["describe"], undefined, options);

  if (run.timedOut) {
    return { ok: false, error: timeoutError(artifact, "describe", options, run) };
  }
  if (run.overflow !== undefined) {
    return { ok: false, error: overflowError(artifact, "describe", run) };
  }
  if (run.exitCode !== PluginExit.ok) {
    return {
      ok: false,
      error: {
        code: ErrorCode.pluginProtocolError,
        message: `插件的 describe 以非零退出码收场(exit=${run.exitCode})。`,
        detail: detailOf(run),
        guidance: missingPackageOf(run) ?? authorGuidance(
          artifact,
          "describe 必须以退出码 0 收场,并在 stdout 上写一行工具清单 JSON。",
        ),
      },
    };
  }

  const parsed = parseJsonLine(run.stdout);
  if (parsed === undefined) {
    return {
      ok: false,
      error: {
        code: ErrorCode.pluginProtocolError,
        message: "插件的 describe 输出不是一行合法 JSON。",
        detail: detailOf(run),
        guidance: authorGuidance(
          artifact,
          "stdout 上只能有那一行 JSON —— 调试信息请写 stderr(内核两条流是分开收的)。",
        ),
      },
    };
  }

  const shaped = PluginDescribeResultSchema.safeParse(parsed);
  if (!shaped.success) {
    return {
      ok: false,
      error: {
        code: ErrorCode.pluginProtocolError,
        message: "插件的 describe 输出不符合插件协议。",
        detail: shaped.error.message,
        guidance: authorGuidance(
          artifact,
          `形状:{"protocol":${PLUGIN_PROTOCOL_VERSION},"tools":[{"name","summary","dangerous",` +
            `"parameters":[{"name","type","required","description"}]}]}。参数类型只认 ` +
            "string/number/boolean/object/array。",
        ),
      },
    };
  }

  if (shaped.data.tools.length > MAX_TOOLS_PER_PLUGIN) {
    return {
      ok: false,
      error: {
        code: ErrorCode.pluginProtocolError,
        message: `插件声明了 ${shaped.data.tools.length} 个工具,超过上限 ${MAX_TOOLS_PER_PLUGIN}。`,
        detail:
          "每个工具都会在内核的能力表里占一条(还要进每一份快照与每一次能力全集推送)," +
          "所以清单长度是有上限的。",
        guidance: authorGuidance(
          artifact,
          `把工具收敛到 ${MAX_TOOLS_PER_PLUGIN} 个以内 —— 清单长成这样通常是生成它的代码写飞了,` +
            "而不是真的有那么多工具。",
        ),
      },
    };
  }

  return { ok: true, value: shaped.data };
}

// MARK: - call

/**
 * 调一个工具。参数 stdin JSON 进、结果 stdout JSON 出、**退出码即成败**。
 *
 * 四种收场各有各的报文(词表见 `PluginExit`),这里把它们翻成内核的 `ErrorCode`:
 *   * 0 + 合法 stdout      → 成功,`output` 原样交给调用方;
 *   * 3                    → `capability_failed`(**执行了、业务上失败了**,与内置能力同一档);
 *   * 2 / 4 / 输出不合协议 → `plugin_protocol_error`(要改的是插件);
 *   * 其余非零 / 被信号打断 → `plugin_failed`;超时 → `plugin_timeout`。
 */
export async function callPluginTool(
  artifact: string,
  tool: string,
  input: Record<string, JsonValue>,
  options: PluginRunOptions = {},
): Promise<PluginOutcome<JsonValue>> {
  const request = JSON.stringify({ tool, input });
  const run = await runPluginProcess(artifact, ["call"], `${request}\n`, options);

  if (run.timedOut) {
    return { ok: false, error: timeoutError(artifact, `call ${tool}`, options, run) };
  }
  if (run.overflow !== undefined) {
    return { ok: false, error: overflowError(artifact, `call ${tool}`, run) };
  }

  const parsed = parseJsonLine(run.stdout);
  const shaped = parsed === undefined ? undefined : PluginCallOutputSchema.safeParse(parsed);

  if (run.exitCode === PluginExit.ok) {
    if (shaped?.success && shaped.data.ok) return { ok: true, value: shaped.data.output };
    return {
      ok: false,
      error: {
        code: ErrorCode.pluginProtocolError,
        message: `插件工具 ${tool} 以退出码 0 收场,但 stdout 不是一行合法的成功结果。`,
        detail: detailOf(run),
        guidance: authorGuidance(
          artifact,
          '成功时 stdout 必须是 {"ok":true,"output":<任意 JSON>},且退出码为 0。',
        ),
      },
    };
  }

  if (run.exitCode === PluginExit.toolFailed) {
    // 插件说"我执行了,但这件事没成"。它自己给的 message/detail 原样传回去 ——
    // 插件比内核更清楚这次为什么没成,内核不替它编话。
    const failure = shaped?.success && !shaped.data.ok ? shaped.data.error : undefined;
    return {
      ok: false,
      error: {
        code: ErrorCode.capabilityFailed,
        message: failure?.message ?? `插件工具 ${tool} 执行了,但业务上失败了。`,
        detail: failure?.detail ?? detailOf(run),
      },
    };
  }

  if (run.exitCode === PluginExit.unknownTool) {
    return {
      ok: false,
      error: {
        code: ErrorCode.pluginProtocolError,
        message: `插件不认识工具 ${tool} —— 它的 describe 清单与实现漂了。`,
        detail: detailOf(run),
        guidance: authorGuidance(
          artifact,
          "describe 里列出的每个工具,call 都必须能处理。改完插件重新 `a2 plugin add` 即可刷新清单。",
        ),
      },
    };
  }

  if (run.exitCode === PluginExit.badRequest) {
    return {
      ok: false,
      error: {
        code: ErrorCode.pluginProtocolError,
        message: `插件说它读不懂内核发来的调用报文(exit=${PluginExit.badRequest})。`,
        detail: detailOf(run),
        guidance: authorGuidance(
          artifact,
          `内核发的是一行 {"tool":"<名字>","input":{…}};请确认插件读的是 stdin 全文。`,
        ),
      },
    };
  }

  return {
    ok: false,
    error: {
      code: ErrorCode.pluginFailed,
      message: `插件工具 ${tool} 没跑成(exit=${run.exitCode})。`,
      detail: detailOf(run),
      guidance:
        missingPackageOf(run) ??
        authorGuidance(
          artifact,
          `退出码词表:0 成功 / ${PluginExit.badRequest} 报文读不懂 / ${PluginExit.toolFailed} 业务失败 / ` +
            `${PluginExit.unknownTool} 未知工具。未捕获的异常会让 Bun 以 1 退出,栈在 stderr 里。`,
        ),
    },
  };
}

// MARK: - 报文零件

function timeoutError(
  artifact: string,
  what: string,
  options: PluginRunOptions,
  run: PluginProcessResult,
): WireError {
  const timeoutMs = options.timeoutMs ?? readTimeout(options.env ?? process.env);
  return {
    code: ErrorCode.pluginTimeout,
    message: `插件在 ${timeoutMs}ms 内没有交出 ${what} 的结果,已被杀掉。`,
    detail: detailOf(run),
    guidance: {
      summary: "插件是一次调用一个进程,它必须自己收场 —— 别在里面等待外部事件或常驻。",
      steps: [
        { description: "确认插件在写完 stdout 之后调用了 process.exit(0)" },
        {
          description:
            "**插件自己派生的子进程也算**:它继承了同一条 stdout,只要它不退出,这次调用就交不出结果。" +
            "内核杀得掉插件进程本身,杀不掉它的子孙(没有进程组的口子)—— 派生的进程请自己收尾。",
        },
        { description: "临时放宽窗口再试(仅诊断用)", command: "A2_PLUGIN_TIMEOUT_MS=60000 a2 …" },
      ],
      context: { plugin: artifact },
    },
  };
}

/** 输出撞上限:插件被杀,报文里说清楚上限是多少、以及"大东西该怎么交"。 */
function overflowError(artifact: string, what: string, run: PluginProcessResult): WireError {
  return {
    code: ErrorCode.pluginProtocolError,
    message:
      `插件的 ${run.overflow} 超过了 ${Math.round(OUTPUT_LIMIT_BYTES / 1024 / 1024)}MiB 上限` +
      `(${what}),进程已被杀掉。`,
    detail: detailOf(run),
    guidance: authorGuidance(
      artifact,
      "stdout 上只放那一行结果 JSON。真要交出大块数据,请把它写成文件、在 output 里回一个路径 ——" +
        "内核不做无上限的管道搬运工(那等于让插件决定内核吃多少内存)。",
    ),
  };
}

/**
 * **动态 require 的运行期兜底**(12 票;02 票 spike §8.4/§8.5 的直接落地)。
 *
 * `require(变量)` 这种非静态可分析的依赖,`bun build` 打包期**一句告警都不给**(spike 实测 exit=0),
 * 所以它一定会活到运行期才发作。内核 spawn 插件恒带 `--no-install`,于是它发作的样子是确定的:
 * `Cannot find package '<名字>'` 硬错,而不是"静默联网把包装上"。这里把那句硬错认出来,
 * 换成一条**告诉 agent 该改哪儿**的指引 —— 否则它看到的只是一句 `exit=1`。
 */
function missingPackageOf(run: PluginProcessResult): Guidance | undefined {
  const match = /Cannot find (?:package|module) ['"]([^'"]+)['"]/.exec(run.stderr);
  if (!match) return undefined;
  const missing = match[1] as string;
  return {
    summary: `这个插件运行期要 ${missing},但它没被打进登记的单文件工件里。`,
    steps: [
      {
        description:
          `最常见的原因是**动态 require/import**(require(变量)、await import(拼出来的名字))——` +
          "打包器在装载期看不见它,所以只能等到调用时才发作。改成静态 import 后重新 add 即可。",
      },
      {
        description:
          "内核运行插件时恒带 --no-install:缺包就是硬失败,**绝不会**在调用的那一刻替你联网装包" +
          "(那等于把供应链面从装载期漏到调用期)。",
      },
      { description: "改成静态 import 后重新登记(同名即替换)", command: "a2 plugin add <你的插件目录>" },
    ],
    context: { missingPackage: missing },
  };
}

/** 给插件作者(多半是 agent)的指引:一条具体的修法 + 两条能直接敲的命令。 */
function authorGuidance(artifact: string, fix: string): Guidance {
  return {
    summary: "改插件文件后重新装一次即可 —— 装载零闸,不需要任何确认。",
    steps: [
      { description: fix },
      { description: "看插件协议与一个可直接抄的最小例子", command: "a2 plugin --help" },
      { description: "改完重新登记(同名即替换)", command: "a2 plugin add <你的插件.ts>" },
    ],
    context: { plugin: artifact },
  };
}

/** stdout/stderr 一起进 detail:插件到底吐了什么,排错时这是唯一的现场。 */
function detailOf(run: PluginProcessResult): string {
  const parts: string[] = [];
  if (run.stdout.trim().length > 0) parts.push(`stdout: ${truncate(run.stdout)}`);
  if (run.stderr.trim().length > 0) parts.push(`stderr: ${truncate(run.stderr)}`);
  if (parts.length === 0) parts.push("(插件既没写 stdout 也没写 stderr)");
  parts.push(`pid=${run.pid}`);
  return parts.join("\n");
}

function truncate(text: string): string {
  const trimmed = text.trim();
  return trimmed.length <= STDERR_DETAIL_LIMIT
    ? trimmed
    : `${trimmed.slice(0, STDERR_DETAIL_LIMIT)}…(已截断,共 ${trimmed.length} 字节)`;
}

/** 插件的 stdout 应当只有一行 JSON;宽容一点:允许前后有空行,但**不允许**掺散文。 */
function parseJsonLine(stdout: string): unknown {
  const trimmed = stdout.trim();
  if (trimmed.length === 0) return undefined;
  try {
    return JSON.parse(trimmed);
  } catch {
    return undefined;
  }
}
