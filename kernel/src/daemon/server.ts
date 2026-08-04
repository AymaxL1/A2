// UDS server:起监听、收紧权限、逐行路由、干净收摊。
//
// 权限的两道门(ADR 0010 Consequences:Bun 的 UDS 权限跟随 umask,内核不能指望它):
//   1. `<A2_HOME>/run` 自建并 **显式 chmod 0700**(mkdir 的 mode 会被 umask 削,必须补一刀);
//   2. socket **bind 之后 chmod 0600**(bind 时的权限同样随 umask,0755 是常见默认值)。
// 对端 UID 校验(getpeereid via bun:ffi)属仲裁面,08 票补 —— 本票先把文件权限这道门关死。

import { chmod, mkdir, stat, unlink } from "node:fs/promises";
import { RUN_DIR_MODE, SOCKET_MODE, type KernelPaths } from "../runtime/paths.ts";
import { handleLine } from "./router.ts";
import type { KernelRuntime } from "./runtime.ts";

/** socket 上已经有个活着的 daemon —— 不抢,报错退出(自愈归系统 supervisor,应用层不造看门狗)。 */
export class AlreadyRunningError extends Error {
  constructor(readonly socketPath: string) {
    super(`socket 上已有活着的 daemon:${socketPath}`);
    this.name = "AlreadyRunningError";
  }
}

export interface KernelServer {
  socketPath: string;
  /** 关监听、断连接、删 socket 文件。可重复调用。 */
  stop(): Promise<void>;
}

interface ConnectionState {
  buffer: string;
}

export async function startKernelServer(runtime: KernelRuntime): Promise<KernelServer> {
  const paths = runtime.paths;
  await prepareRunDirectory(paths);
  await clearStaleSocket(paths.socketPath);

  const listener = Bun.listen<ConnectionState>({
    unix: paths.socketPath,
    socket: {
      open(socket) {
        socket.data = { buffer: "" };
      },
      data(socket, chunk) {
        const state = socket.data;
        state.buffer += chunk.toString();
        // NDJSON:一次 data 可能带来半行、一行或多行,逐行吃干净,余料留在 buffer 里等下一片。
        let newline = state.buffer.indexOf("\n");
        while (newline >= 0) {
          const line = state.buffer.slice(0, newline);
          state.buffer = state.buffer.slice(newline + 1);
          if (line.trim().length > 0) socket.write(handleLine(line, runtime));
          newline = state.buffer.indexOf("\n");
        }
      },
    },
  });

  // bind 之后立刻收紧:在此之前的窗口里 socket 的权限来自 umask,不可信。
  await chmod(paths.socketPath, SOCKET_MODE);

  let stopped = false;
  return {
    socketPath: paths.socketPath,
    async stop() {
      if (stopped) return;
      stopped = true;
      listener.stop(true);
      // UDS 文件不随进程退出自动消失,自己收拾干净(留下的陈旧 socket 会骗到下一次 status)。
      await unlink(paths.socketPath).catch(() => {});
    },
  };
}

/** 自建 `<home>/run` 并显式收紧到 0700(已存在但权限松的目录也一并纠正)。 */
async function prepareRunDirectory(paths: KernelPaths): Promise<void> {
  await mkdir(paths.runDir, { recursive: true, mode: RUN_DIR_MODE });
  await chmod(paths.runDir, RUN_DIR_MODE);
}

/**
 * socket 文件存在时先探活:连得上 = 真有 daemon 在跑(拒绝启动);连不上 = 上次没收摊干净的残骸(删掉)。
 * 不这么做的话,bind 会直接 EADDRINUSE,而人看到的错误分不清"已经在跑"和"上次崩了"。
 */
async function clearStaleSocket(socketPath: string): Promise<void> {
  const exists = await stat(socketPath).then(
    () => true,
    () => false,
  );
  if (!exists) return;

  try {
    // 注:Bun.connect 至少要一个 data/drain 回调,空 handler 会 TypeError(探活本身不读数据)。
    const probe = await Bun.connect({ unix: socketPath, socket: { data() {} } });
    probe.end();
    throw new AlreadyRunningError(socketPath);
  } catch (error) {
    if (error instanceof AlreadyRunningError) throw error;
    await unlink(socketPath).catch(() => {});
  }
}
