// daemon 运行态:一份进程级事实,status 等 op 从这里取快照。

import { PROTOCOL_VERSION, type StatusResult } from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";

export interface KernelRuntime {
  paths: KernelPaths;
  /** 进程启动时刻(用于 uptime 与 startedAt)。 */
  startedAt: Date;
  pid: number;
  version: string;
}

export function createRuntime(paths: KernelPaths, now: Date = new Date()): KernelRuntime {
  return { paths, startedAt: now, pid: process.pid, version: KERNEL_VERSION };
}

export function statusSnapshot(runtime: KernelRuntime, now: Date = new Date()): StatusResult {
  return {
    state: "running",
    version: runtime.version,
    protocol: PROTOCOL_VERSION,
    pid: runtime.pid,
    startedAt: runtime.startedAt.toISOString(),
    uptimeMs: Math.max(0, now.getTime() - runtime.startedAt.getTime()),
    home: runtime.paths.home,
    socketPath: runtime.paths.socketPath,
  };
}
