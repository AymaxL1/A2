// daemon 运行态:一份进程级事实,status / 快照 / 仲裁都从这里取。
//
// 装配顺序即依赖顺序(08 票):hub(谁在场)→ audit(留痕,推送经 hub)→ arbiter(仲裁,用前两者)
// → registry(能力面,`arbitration.status` 要读 arbiter)→ supervisor(观测,事件经 hub 推出去)。

import { arbitrationCapabilities } from "../capability/arbitration.ts";
import { BUILTIN_CAPABILITIES } from "../capability/builtin.ts";
import { proxyCapabilities } from "../capability/proxy.ts";
import { urlRouterCapabilities } from "../capability/url-router.ts";
import { CapabilityRegistry } from "../capability/registry.ts";
import {
  PROTOCOL_VERSION,
  type KernelSnapshot,
  type StatusResult,
  type UrlRouterSnapshot,
} from "../contract/wire.ts";
import { loadUrlRouterConfig } from "../url-router/config.ts";
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
import {
  createUrlRouterExecutorHub,
  type UrlRouterExecutorHub,
} from "./url-router-executor.ts";

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
   * 机械执行器那一侧的在场与往返(url-router 施工 04 票)。
   *
   * 它与 `arbiter` 是**并列的两条路**,不是它的一部分:那条管"人同不同意",这条管
   * "把这件事做了、结果如实回来"。takeover/restore 的确认由**系统弹框**承载,所以它们走这条。
   */
  urlRouterExecutor: UrlRouterExecutorHub;
  /**
   * 确认器是否在场。**08 票起接的是真值**:注册了 confirm-agent 角色的长连接数 > 0,
   * 断线即自动回 false(在场 = 长连接,无心跳无 TTL)。04 票留的这条缝形状未改。
   */
  confirmerPresent(): boolean;
  /**
   * 快照里唯一**不来自进程内状态**的那一节(03 票):兜底浏览器是谁,事实源是磁盘上那份
   * `<A2_HOME>/url-router.json`,所以取它要 await。
   *
   * 它单独一个口、而不是把 `snapshot()` 整个变成 async —— 那是协议顺序的要求,不是洁癖:
   * `roles.register` 的响应必须是这条连接上的**第一帧**,所以"注册"与"建快照"之间**不能有 await 点**
   * (让出去的那一瞬间,别的连接触发的推送就能挤在响应前头写给这条已注册的连接)。
   * 于是调用方的规矩是:**先 await 这一节(那时本连接还没注册,收不到任何推送),再 register,
   * 再同步建快照**。见 `router.ts` 的 `roles.register`。
   *
   * 不设文件监视:值在**每次建全量快照时现读**,与"注册即快照"同一条机制 —— 读的时刻就是发的时刻,
   * 不存在"内核缓存了一份旧配置"的窗口。
   */
  urlRouterSnapshot(): Promise<UrlRouterSnapshot>;
  /** 注册那一刻回给客户端的全量快照(此后走增量推送)。`urlRouter` 由上面那个口先读好再传进来。 */
  snapshot(urlRouter: UrlRouterSnapshot): KernelSnapshot;
}

export function createRuntime(paths: KernelPaths, now: Date = new Date()): KernelRuntime {
  const env = process.env;
  const hub = createClientHub();
  const audit = createAuditLog(paths, (event, except) =>
    hub.broadcast({ kind: "audit", at: event.at, audit: event }, except),
  );
  const arbiter = createArbiter({ paths, hub, audit, env });
  const urlRouterExecutor = createUrlRouterExecutorHub({ hub, audit, env });
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
    // **执行器那一侧要注入**(04 票):takeover/restore 的确认由系统弹框承载,而弹框只有壳能调 ——
    // 于是能力 handler 必须够得着"谁在场、怎么下发指令"这件进程级事实。
    ...urlRouterCapabilities({ paths, env, executor: urlRouterExecutor }),
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
    urlRouterExecutor,
    confirmerPresent: () => hub.confirmerCount() > 0,
    // 配置用不了(文件坏了/读不出来)时 `loadUrlRouterConfig` 已经整份退回缺省,所以这里
    // 永远拿得到一个非空 bundle id —— 壳那侧不必处理"内核给了空值"这种形状。
    // 「配歪了」这件事由 `url-router.status` 指名道姓地说,不在快照里重复报警。
    urlRouterSnapshot: async () => ({
      fallbackBrowserBundleID: (await loadUrlRouterConfig(paths)).config.fallbackBrowserBundleID,
    }),
    snapshot: (urlRouter) => ({
      status: statusSnapshot(runtime),
      capabilities: registry.list(),
      arbitration: arbiter.state(),
      supervision: supervisor.snapshot(),
      audit: audit.recent(),
      urlRouter,
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
