// daemon 运行态:一份进程级事实,status 等 op 从这里取快照。

import { BUILTIN_CAPABILITIES } from "../capability/builtin.ts";
import { CapabilityRegistry } from "../capability/registry.ts";
import { PROTOCOL_VERSION, type StatusResult } from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";

export interface KernelRuntime {
  paths: KernelPaths;
  /** 进程启动时刻(用于 uptime 与 startedAt)。 */
  startedAt: Date;
  pid: number;
  version: string;
  /** 能力注册表 —— 内核里唯一的调用面。 */
  registry: CapabilityRegistry;
  /**
   * 确认器是否在场。**04 票恒 false**:内核此时没有任何确认通道,dangerous 一律 fail-closed 默拒。
   * 08 票把它接到"长连接上注册了 confirm-agent 角色的连接数 > 0",断线即自动回 false ——
   * 仲裁那一侧不用改,它问的一直是这个问题。
   */
  confirmerPresent(): boolean;
}

export function createRuntime(paths: KernelPaths, now: Date = new Date()): KernelRuntime {
  return {
    paths,
    startedAt: now,
    pid: process.pid,
    version: KERNEL_VERSION,
    registry: new CapabilityRegistry(BUILTIN_CAPABILITIES),
    confirmerPresent: () => false,
  };
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
