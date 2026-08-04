// `a2 daemon run` —— 前台常驻模式(ADR 0008 第 6 条:开机自启与崩溃自愈归系统 supervisor,
// 这里只负责"跑一个在前台的内核",不 fork、不写 pid 文件、不造看门狗;service 安装是 05 票)。
//
// stdout 上是 NDJSON 生命周期事件(供 launchd/systemd 日志与测试判就绪),
// **不是**线协议报文 —— 线协议只在 UDS 上说话。

import { ExitCode, exitCodeForErrorCode } from "../contract/exit-codes.ts";
import { ErrorCode, PROTOCOL_VERSION, failureResponse } from "../contract/wire.ts";
import { AlreadyRunningError, startKernelServer } from "../daemon/server.ts";
import { createRuntime } from "../daemon/runtime.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { renderWireError, type CommandOutcome } from "./outcome.ts";

function emitEvent(event: string, fields: Record<string, string | number>): void {
  process.stdout.write(`${JSON.stringify({ event, ...fields })}\n`);
}

export async function daemonRunCommand(paths: KernelPaths): Promise<CommandOutcome> {
  const runtime = createRuntime(paths);

  // 先挂信号,再起监听:否则 "socket 已存在但 handler 还没挂上" 那一瞬间收到 SIGTERM,
  // 进程会走默认行为直接死掉,把 socket 文件留在磁盘上骗下一次 status。
  const shutdown = waitForShutdownSignal();

  let server;
  try {
    server = await startKernelServer(runtime);
  } catch (error) {
    return startFailureOutcome(error, paths);
  }

  emitEvent("daemon.listening", {
    socketPath: server.socketPath,
    home: paths.home,
    pid: runtime.pid,
    version: runtime.version,
    protocol: PROTOCOL_VERSION,
    startedAt: runtime.startedAt.toISOString(),
  });

  const signal = await shutdown;
  await server.stop();
  emitEvent("daemon.stopped", { signal, pid: runtime.pid });
  return { exitCode: ExitCode.success };
}

function startFailureOutcome(error: unknown, paths: KernelPaths): CommandOutcome {
  const wireError =
    error instanceof AlreadyRunningError
      ? {
          code: ErrorCode.usage,
          message: "该 A2_HOME 下已经有一个 daemon 在运行,不重复启动。",
          detail: error.message,
          guidance: {
            summary: "同一个 socket 只能有一个 daemon;先看现有实例的状态,确需重启再显式停掉它。",
            steps: [
              { description: "查现有实例", command: "a2 status --json" },
              { description: "停掉前台实例:回到那个终端按 Ctrl-C(系统托管的实例见 05 票的 service 命令)" },
            ],
            context: { socketPath: paths.socketPath, home: paths.home },
          },
        }
      : {
          code: ErrorCode.internalError,
          message: "daemon 启动失败。",
          detail: String(error),
          guidance: {
            summary: "确认 A2_HOME 可写、路径长度未超 UDS 上限(macOS 104 字节)后重试。",
            steps: [{ description: "检查运行时目录", command: `ls -la ${paths.runDir}` }],
            context: { socketPath: paths.socketPath, home: paths.home },
          },
        };
  const envelope = failureResponse(crypto.randomUUID(), wireError);
  return {
    envelope,
    human: renderWireError(envelope.error),
    exitCode: exitCodeForErrorCode(wireError.code),
  };
}

/** 等 SIGINT/SIGTERM —— 前台常驻的唯一退出路径(Ctrl-C 与 supervisor 停服走同一条)。 */
function waitForShutdownSignal(): Promise<string> {
  return new Promise((resolve) => {
    const onSignal = (signal: string) => {
      process.off("SIGINT", onSignal);
      process.off("SIGTERM", onSignal);
      resolve(signal);
    };
    process.on("SIGINT", onSignal);
    process.on("SIGTERM", onSignal);
  });
}
