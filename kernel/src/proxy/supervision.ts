// 存活监督:daemon 里那条**只读**的观测循环。
//
// 它回答的问题只有一个 ——「a2 内嵌的那个 mihomo 子进程,此刻控制面还应答吗」。为此它每隔一段时间
// 对自家 external-controller 发一次 `GET /version`,把状态变化写成结构化事件。
//
// **本文件里没有任何一行会改变系统状态**:不写配置、不动系统代理、不重拉任何进程。
// 重拉是 `child.ts` 的事(它有节流与故障态);这条循环是**控制面视角**的第二只眼 ——
// 进程活着但控制面不应答(端口被抢、配置里的 controller 漂了)只有它看得见。
//
// 「盯谁」只用一件事实,**不跑那套完整检测**:落盘的托管模式是不是 `embedded`。
// 不是 = 没有可盯的对象,如实报告,不报警 —— observe 模式**有意不进循环**(ADR 0013 的裁定原样有效:
// 反复探一个我们既不负责拉起、也不负责配置的进程,只会产出一份看着像"我管着它"的假报警)。
//
// 推送面(订阅 / 确认器)归 08 票。本票产出的 `ProxySupervisionEvent` **就是**将来要推的那份载荷,
// 形状不变 —— 08 票只需把它发出去,不必再造一遍。

import { appendFile, mkdir } from "node:fs/promises";
import path from "node:path";
import type { MihomoOwner, ProxySupervisionEvent, ProxySupervisionResult } from "../contract/wire.ts";
import { probeController } from "../mihomo/controller.ts";
import { mihomoLayout, readSecretOf } from "../mihomo/paths.ts";
import { readSettings } from "./config.ts";
import { LOG_DIR_MODE, LOG_DIR_NAME } from "../service/unit.ts";
import type { KernelPaths } from "../runtime/paths.ts";

/** 观测间隔的默认值。够快到"实例没了几秒内就有事件",又不至于把回环探成噪音。 */
export const DEFAULT_WATCH_INTERVAL_MS = 5000;
/** 覆写观测间隔(毫秒)。仅测试与诊断用。 */
export const WATCH_INTERVAL_ENV = "A2_PROXY_WATCH_INTERVAL_MS";
/** 内存里留多少条最近事件(全量在日志文件里)。 */
const RECENT_EVENTS = 50;
/** 事件日志文件名(NDJSON,一行一条)。 */
export const SUPERVISION_LOG_NAME = "proxy-supervision.log";

interface WatchTarget {
  owner: MihomoOwner;
  controller: string;
  secret?: string;
  managed: boolean;
  configPath?: string;
}

export interface ProxySupervisor {
  start(): void;
  stop(): Promise<void>;
  /** 给 `proxy.supervision.get` 用的当下快照。 */
  snapshot(): ProxySupervisionResult;
}

export function supervisionLogPath(paths: KernelPaths): string {
  return path.join(paths.home, LOG_DIR_NAME, SUPERVISION_LOG_NAME);
}

export function createProxySupervisor(
  paths: KernelPaths,
  env: Record<string, string | undefined> = process.env,
  /**
   * 每记一条事件就叫一次(08 票接的推送面)。07 票留的话在这里兑现:**载荷形状一字未改** ——
   * 08 票只是在落盘与入内存之外多了一个去处,不需要为推送另造一份事件。
   */
  onEvent: (event: ProxySupervisionEvent) => void = () => {},
): ProxySupervisor {
  const parsed = Number.parseInt(env[WATCH_INTERVAL_ENV]?.trim() ?? "", 10);
  const intervalMs = Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_WATCH_INTERVAL_MS;
  const logPath = supervisionLogPath(paths);

  let timer: ReturnType<typeof setInterval> | undefined;
  let running = false;
  /** 一次探测未完成时绝不叠下一次(慢探针不该把队列堆起来)。 */
  let inFlight = false;
  let checks = 0;
  let current: WatchTarget | undefined;
  let alive: boolean | undefined;
  let lastCheckAt: string | undefined;
  let lastTransitionAt: string | undefined;
  const events: ProxySupervisionEvent[] = [];

  async function record(event: ProxySupervisionEvent): Promise<void> {
    events.push(event);
    if (events.length > RECENT_EVENTS) events.splice(0, events.length - RECENT_EVENTS);
    lastTransitionAt = event.at;
    // 推送先于落盘:订阅者不该为了一次磁盘写而多等(而且日志写失败也不该让推送丢)。
    try {
      onEvent(event);
    } catch {
      // 推送失败(对端刚断之类)同样不该让观测停摆。
    }
    try {
      await mkdir(path.dirname(logPath), { recursive: true, mode: LOG_DIR_MODE });
      await appendFile(logPath, `${JSON.stringify(event)}\n`);
    } catch {
      // 日志写不下去不该让观测停摆(内存里那份仍然可查)。
    }
  }

  async function tick(): Promise<void> {
    if (inFlight) return;
    inFlight = true;
    try {
      const next = await resolveWatchTarget(paths, env);
      const at = new Date().toISOString();

      if (!next) {
        // 没有可盯的对象:如实归零,**不报警**(「这台机器上还没有 mihomo」不是故障)。
        current = undefined;
        alive = undefined;
        lastCheckAt = at;
        checks += 1;
        return;
      }

      if (current && current.controller !== next.controller) {
        await record({
          at,
          kind: "target_changed",
          controller: next.controller,
          owner: next.owner,
          detail: `观测对象从 ${current.controller} 换成了 ${next.controller}。`,
        });
        alive = undefined;
      }
      current = next;

      const probe = await probeController(next.controller, next.secret);
      checks += 1;
      lastCheckAt = at;

      if (alive === undefined) {
        // **首拍恒记 watch_started**(14 票):daemon 起来的同一瞬孩子往往还在拉起,首拍不可达是
        // 预期中的过渡,不是事故 —— 把它报成 instance_down 等于 daemon 每次启动都先自吓一跳。
        // 持续不应答自有去处:后续转变出 up/down,连续启动失败走 status 的故障态。
        await record({
          at,
          kind: "watch_started",
          controller: next.controller,
          owner: next.owner,
          ...(probe.reachable
            ? {}
            : { detail: "控制面尚未应答(子进程可能正在拉起)。持续不应答看 a2 mihomo status 的故障态。" }),
        });
      } else if (alive !== probe.reachable) {
        await record({
          at,
          kind: probe.reachable ? "instance_up" : "instance_down",
          controller: next.controller,
          owner: next.owner,
          ...(probe.detail ? { detail: probe.detail } : {}),
          ...(probe.reachable ? {} : { guidance: downGuidance(next) }),
        });
      }
      alive = probe.reachable;
    } catch {
      // 观测永不因为一次意外而停摆 —— 它是背景噪音级别的东西,不该有能力把 daemon 拖垮。
    } finally {
      inFlight = false;
    }
  }

  return {
    start(): void {
      if (running) return;
      running = true;
      // 立刻探一次(不等第一个间隔),这样 daemon 一起来就有事实可查。
      void tick();
      timer = setInterval(() => void tick(), intervalMs);
      // 观测不该让进程活着:daemon 该退的时候不会被这个定时器拖住。
      timer.unref?.();
    },
    async stop(): Promise<void> {
      if (!running) return;
      running = false;
      if (timer) clearInterval(timer);
      timer = undefined;
      if (current) {
        await record({
          at: new Date().toISOString(),
          kind: "watch_stopped",
          controller: current.controller,
          owner: current.owner,
          detail: "内核 daemon 停止,观测结束 —— 内嵌 mihomo 随 daemon 一并停下(14 票:随 a2 生死);系统代理设置不受影响。",
        });
      }
    },
    snapshot(): ProxySupervisionResult {
      return {
        watching: running,
        intervalMs,
        checks,
        ...(current
          ? {
              target: {
                owner: current.owner,
                controller: current.controller,
                managed: current.managed,
                ...(current.configPath ? { configPath: current.configPath } : {}),
              },
            }
          : {}),
        ...(alive === undefined ? {} : { alive }),
        ...(lastCheckAt ? { lastCheckAt } : {}),
        ...(lastTransitionAt ? { lastTransitionAt } : {}),
        logPath,
        events: [...events],
      };
    },
  };
}

/**
 * 盯谁 —— **只盯 a2 内嵌的那一份**(判据:落盘的托管模式 = `embedded`)。其余模式 = 没有可盯的对象。
 *
 * observe 模式与别人的实例**有意不进循环**(ADR 0013 → ADR 0014 一脉相承):它们仍能被
 * `a2 mihomo status` 现探现报,但内核不对一个自己不负责拉起的进程做常驻监督。
 */
async function resolveWatchTarget(
  paths: KernelPaths,
  env: Record<string, string | undefined>,
): Promise<WatchTarget | undefined> {
  const layout = mihomoLayout(paths, env);
  const settings = await readSettings(layout, env);
  if (settings.managedMode !== "embedded") return undefined;
  const secret = await readSecretOf(layout.configPath);
  return {
    owner: "a2",
    controller: layout.controller,
    ...(secret ? { secret } : {}),
    managed: true,
    configPath: layout.configPath,
  };
}

/** 「实例没了」那条报警自带的指引 —— 与 status 故障态(guidance 态 C)同一口径。 */
function downGuidance(target: WatchTarget): ProxySupervisionEvent["guidance"] {
  // 被盯的对象恒是 a2 内嵌那份(`resolveWatchTarget` 只认它),所以这里只剩一种说法。
  // `owner`/`managed` 两个字段仍留在 `WatchTarget` 上 —— 它们进事件载荷,是给读事件的人看的事实。
  return {
    summary:
      "内置 mihomo 的控制面没在应答。进程面与最近错误看 status;连续启动失败会转故障态并停止重拉。",
    steps: [
      { description: "看 mihomo 现状(进程面 + 控制面 + lastError)", command: "a2 mihomo status --json" },
      { description: "重启内置内核(故障计数清零)", command: "a2 mihomo restart --json" },
    ],
    context: { controller: target.controller, owner: target.owner },
  };
}
