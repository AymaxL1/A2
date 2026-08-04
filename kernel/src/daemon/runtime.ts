// daemon 运行态:一份进程级事实,status / 快照 / 仲裁都从这里取。
//
// 装配顺序即依赖顺序(08 票):hub(谁在场)→ audit(留痕,推送经 hub)→ arbiter(仲裁,用前两者)
// → registry(能力面,`arbitration.status` 要读 arbiter)→ supervisor(观测,事件经 hub 推出去)。

import { arbitrationCapabilities } from "../capability/arbitration.ts";
import { BUILTIN_CAPABILITIES } from "../capability/builtin.ts";
import { proxyCapabilities } from "../capability/proxy.ts";
import { CapabilityRegistry } from "../capability/registry.ts";
import { PROTOCOL_VERSION, type KernelSnapshot, type StatusResult } from "../contract/wire.ts";
import { createProxySupervisor, type ProxySupervisor } from "../proxy/supervision.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";
import { createArbiter, type Arbiter } from "./arbitration.ts";
import { createAuditLog, type AuditLog } from "./audit.ts";
import { createClientHub, type ClientHub } from "./hub.ts";

export interface KernelRuntime {
  paths: KernelPaths;
  /** 进程启动时刻(用于 uptime 与 startedAt)。 */
  startedAt: Date;
  pid: number;
  version: string;
  /** 能力注册表 —— 内核里唯一的调用面。 */
  registry: CapabilityRegistry;
  /**
   * 代理域的存活观测(07 票)。它是**进程级状态**,所以住在这里而不是每次调用现造:
   * 「实例什么时候掉的、掉了多久」这种事实,只有一个一直在的东西才答得上来。
   */
  supervisor: ProxySupervisor;
  /** 长连接与角色(08 票):谁在场、推给谁。 */
  hub: ClientHub;
  /** 仲裁审计:dangerous 的每一次仲裁都在这里留痕。 */
  audit: AuditLog;
  /** 三层仲裁的第③层(带外确认)。 */
  arbiter: Arbiter;
  /**
   * 确认器是否在场。**08 票起接的是真值**:注册了 confirm-agent 角色的长连接数 > 0,
   * 断线即自动回 false(在场 = 长连接,无心跳无 TTL)。04 票留的这条缝形状未改。
   */
  confirmerPresent(): boolean;
  /** 注册那一刻回给客户端的全量快照(此后走增量推送)。 */
  snapshot(): KernelSnapshot;
}

export function createRuntime(paths: KernelPaths, now: Date = new Date()): KernelRuntime {
  const env = process.env;
  const hub = createClientHub();
  const audit = createAuditLog(paths, (event) =>
    hub.broadcast({ kind: "audit", at: event.at, audit: event }),
  );
  const arbiter = createArbiter({ paths, hub, audit, env });
  const supervisor = createProxySupervisor(paths, env, (event) =>
    hub.broadcast({ kind: "supervision", at: event.at, supervision: event }),
  );
  const registry = new CapabilityRegistry([
    // 内置自检样本 + 代理域真能力 + 仲裁面只读查询。**顺序即 `capabilities list` 的输出顺序**。
    ...BUILTIN_CAPABILITIES,
    ...proxyCapabilities({ paths, env, supervisor }),
    ...arbitrationCapabilities({ paths, arbiter, audit }),
  ]);

  const runtime: KernelRuntime = {
    paths,
    startedAt: now,
    pid: process.pid,
    version: KERNEL_VERSION,
    registry,
    supervisor,
    hub,
    audit,
    arbiter,
    confirmerPresent: () => hub.confirmerCount() > 0,
    snapshot: () => ({
      status: statusSnapshot(runtime),
      capabilities: registry.list(),
      arbitration: arbiter.state(),
      supervision: supervisor.snapshot(),
      audit: audit.recent(),
    }),
  };
  return runtime;
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
