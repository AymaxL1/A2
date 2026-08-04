#!/usr/bin/env bun
// a2 CLI 入口。一个编译产物多模式(ADR 0010):默认 CLI 子命令,`a2 daemon run` 进常驻模式。
//
// 纪律(ADR 0005/0008):永不交互阻塞、无 `--yes` 旁路、`--json` 时 stdout 只有一条 JSON 包封。

import { ExitCode } from "../contract/exit-codes.ts";
import { ErrorCode, failureResponse } from "../contract/wire.ts";
import { resolvePaths } from "../runtime/paths.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";
import { daemonRunCommand } from "./daemon.ts";
import { emitOutcome, renderWireError, type CommandOutcome } from "./outcome.ts";
import { statusCommand } from "./status.ts";

const USAGE = `a2 ${KERNEL_VERSION} —— agent-first 的本机代理内核

用法:
  a2 [--json] <子命令> [参数]

子命令:
  status               查询 daemon 运行态(经 UDS 往返)
  daemon run           前台起常驻内核(调试用;开机自启请用 service 安装)
  help                 打印本帮助
  version              打印版本

全局参数:
  --json               机读输出:stdout 上只有一条 JSON 包封(成功与失败同一形状)
  -h, --help           同 help
  -V, --version        同 version

环境变量:
  A2_HOME              覆写 ~/.a2(socket 落 <A2_HOME>/run/kernel.sock)

退出码:0 成功 / 1 用法错 / 2 denied / 3 超时 / 4 daemon 不可达 / 5 能力业务失败 / 6 协议·校验错`;

/** 用法错 —— 也照「拒绝即指引」给出下一步命令。 */
function usageOutcome(message: string): CommandOutcome {
  const envelope = failureResponse(crypto.randomUUID(), {
    code: ErrorCode.usage,
    message,
    guidance: {
      summary: "查看可用子命令与参数后重试。",
      steps: [{ description: "打印帮助", command: "a2 help" }],
    },
  });
  return {
    envelope,
    human: `${renderWireError(envelope.error)}\n\n${USAGE}`,
    exitCode: ExitCode.usage,
  };
}

/** argv(不含 argv0/argv1)→ 结果。**不**碰进程状态,好让下面那三行决定怎么输出、怎么退出。 */
async function dispatch(argv: string[]): Promise<CommandOutcome> {
  const [command, ...args] = argv.filter((arg) => arg !== "--json");

  if (command === undefined) return { human: USAGE, exitCode: ExitCode.usage };
  if (command === "help" || command === "-h" || command === "--help") {
    return { human: USAGE, exitCode: ExitCode.success };
  }
  if (command === "version" || command === "-V" || command === "--version") {
    return { human: KERNEL_VERSION, exitCode: ExitCode.success };
  }
  if (command === "status") {
    if (args.length > 0) return usageOutcome(`status 不接受多余参数:${args.join(" ")}`);
    return await statusCommand(resolvePaths());
  }
  if (command === "daemon") {
    if (args[0] !== "run" || args.length > 1) {
      return usageOutcome("daemon 只支持 run 子命令:a2 daemon run");
    }
    return await daemonRunCommand(resolvePaths());
  }
  return usageOutcome(`未知子命令:${command}`);
}

const argv = process.argv.slice(2);
const outcome = await dispatch(argv);
emitOutcome(outcome, argv.includes("--json"));
process.exit(outcome.exitCode);
