// daemon 运行态:一份进程级事实,status / 快照 / 仲裁都从这里取。
//
// 装配顺序即依赖顺序(08 票):hub(谁在场)→ audit(留痕,推送经 hub)→ arbiter(仲裁,用前两者)
// → registry(能力面,`arbitration.status` 要读 arbiter)→ supervisor(观测,事件经 hub 推出去)。

import { arbitrationCapabilities } from "../capability/arbitration.ts";
import { BUILTIN_CAPABILITIES } from "../capability/builtin.ts";
import { proxyCapabilities } from "../capability/proxy.ts";
import { urlRouterCapabilities } from "../capability/url-router.ts";
import { CapabilityRegistry } from "../capability/registry.ts";
import { PROTOCOL_VERSION, type KernelSnapshot, type StatusResult } from "../contract/wire.ts";
import { restorePlugins } from "../plugin/host.ts";
import { sweepStaleBuildAreas } from "../plugin/bundle.ts";
import { sweepStagingArtifacts } from "../plugin/store.ts";
import { MihomoChild } from "../mihomo/child.ts";
import { mihomoApplyOp } from "../mihomo/manager.ts";
import { mihomoLayout } from "../mihomo/paths.ts";
import { createProxySupervisor, type ProxySupervisor } from "../proxy/supervision.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";
import { createArbiter, type Arbiter } from "./arbitration.ts";
import { createAuditLog, type AuditLog } from "./audit.ts";
import { createClientHub, type ClientHub } from "./hub.ts";

export interface KernelRuntime {
  paths: KernelPaths;
  /**
   * daemon 进程的环境。**沙盒注入的那一套(假 supervisor / 假 mihomo / 插件超时)全在这里** ——
   * 11 票起插件子进程也要从它派生(经白名单过滤,见 `plugin/protocol.ts`),所以它得是运行态的一部分,
   * 而不是各处各读一次 `process.env`。
   */
  env: Record<string, string | undefined>;
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
  /**
   * 内嵌 mihomo 子进程(14 票 / ADR 0014)。**一个 daemon 一只**,生死随 daemon:
   * daemon 正常退出走 `stop()`(SIGTERM → 宽限 → SIGKILL → exit 0),崩溃则由 launchd 的组清理兜住。
   */
  mihomo: MihomoChild;
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
  const audit = createAuditLog(paths, (event, except) =>
    hub.broadcast({ kind: "audit", at: event.at, audit: event }, except),
  );
  const arbiter = createArbiter({ paths, hub, audit, env });
  const supervisor = createProxySupervisor(paths, env, (event) =>
    hub.broadcast({ kind: "supervision", at: event.at, supervision: event }),
  );
  const mihomo = new MihomoChild(paths, mihomoLayout(paths, env));
  // 11 票:已登记的插件在**建注册表之前**还原出来 —— 于是"内核提供哪些能力"从第一帧起就是完整的,
  // 不存在"daemon 起来了但插件还没装上"的中间态(那会让刚连上的壳先看到一份少一截的快照)。
  const plugins = restorePlugins(paths, env);
  // 上一次进程被杀在 add 半路时留下的暂存工件,在这里清掉(11 票 CR 尾款 d);
  // 系统临时目录里的**构建区**残骸同理(13 票补的 12 票 CR 尾款 a —— 那边一个残骸是一棵 node_modules)。
  // 不 await:卫生问题不该让 daemon 晚一毫秒起来,失败也不该拦住启动。
  void sweepStagingArtifacts(paths).catch(() => {});
  void sweepStaleBuildAreas().catch(() => []);
  const registry = new CapabilityRegistry([
    // 内置自检样本 + 代理域真能力 + URL 分流域 + 仲裁面只读查询 + 已登记的插件工具。
    // **顺序即 `capabilities list` 的输出顺序**;插件排在最后(内置的位置永远不因装插件而变)。
    ...BUILTIN_CAPABILITIES,
    ...proxyCapabilities({ paths, env, supervisor }),
    // url-router(02 票):不注入 ports/handlers —— 生产路径用真实现(`ps`/`lsof`/`open`/`defaults`,
    // 路径可经 `A2_URL_ROUTER_*` 覆写,与 `A2_NETWORKSETUP` 同一档)。假件只在单测里注入。
    ...urlRouterCapabilities({ paths, env }),
    ...arbitrationCapabilities({ paths, arbiter, audit }),
    ...plugins.capabilities,
  ]);
  if (plugins.problem !== undefined) {
    // 清单坏了不该拦住 daemon 启动(代理面与仲裁面与插件无关),但也绝不静默 ——
    // 落一行到 stderr(daemon 的生命周期事件都在那儿),`a2 plugin list` 会把同一条细节再说一遍。
    process.stderr.write(
      `${JSON.stringify({ event: "plugins.restore.degraded", detail: plugins.problem })}\n`,
    );
  }

  const runtime: KernelRuntime = {
    paths,
    env,
    startedAt: now,
    pid: process.pid,
    version: KERNEL_VERSION,
    registry,
    supervisor,
    mihomo,
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
