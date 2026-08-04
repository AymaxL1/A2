// 存活监督:daemon 里那条**只读**的观测循环。
//
// 它回答的问题只有一个 ——「我收编/自管的那个 mihomo 实例,此刻还在吗」。为此它每隔一段时间
// 对那个 external-controller 发一次 `GET /version`,把状态变化写成结构化事件。
//
// **本文件里没有任何一行会改变系统状态**:不写配置、不碰 supervisor、不动系统代理、不重拉任何进程。
// 这不是自律,是设计 —— 观测者一旦有权动手,「数据面不随控制面起落」就没人守得住了:
// 内核崩一次就会引发一串它自以为好心的重启。实例没了,内核只产出报警 + 指引(06 票的口径),
// 由人或 agent 决定怎么办。
//
// 「盯谁」用的是 06 票留下的两件事实,**不跑那套完整检测**(那要 spawn `mihomo -v` 又要问 supervisor,
// 每 5 秒来一遍太贵):① 收编记录 `adopted.json`(它存在的理由就是给「我收编的那个死了」一个主语);
// ② a2 自管配置 `config.yaml`。两者都没有 = 此刻没有可盯的对象,如实报告,不报警。
//
// 推送面(订阅 / 确认器)归 08 票。本票产出的 `ProxySupervisionEvent` **就是**将来要推的那份载荷,
// 形状不变 —— 08 票只需把它发出去,不必再造一遍。

import { appendFile, mkdir } from "node:fs/promises";
import path from "node:path";
import type { MihomoOwner, ProxySupervisionEvent, ProxySupervisionResult } from "../contract/wire.ts";
import { probeController } from "../mihomo/controller.ts";
import { readAdoption } from "../mihomo/install.ts";
import { loopbackTarget, mihomoLayout, readSecretOf } from "../mihomo/paths.ts";
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
        await record({
          at,
          kind: probe.reachable ? "watch_started" : "instance_down",
          controller: next.controller,
          owner: next.owner,
          ...(probe.detail ? { detail: probe.detail } : {}),
          ...(probe.reachable ? {} : { guidance: downGuidance(next) }),
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
          detail: "内核 daemon 停止,观测结束 —— mihomo 与系统代理不受影响(数据面不随控制面起落)。",
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
 * 盯谁。**收编记录优先**(它就是"我收编的是这一个"这句话本身),其次是 a2 自管那份配置。
 * 两者都没有 = 没有可盯的对象。
 */
async function resolveWatchTarget(
  paths: KernelPaths,
  env: Record<string, string | undefined>,
): Promise<WatchTarget | undefined> {
  const layout = mihomoLayout(paths, env);

  const adoption = await readAdoption(layout);
  if (adoption) {
    const target = loopbackTarget(adoption.controller);
    if (target) {
      const secret = adoption.configFile ? await readSecretOf(adoption.configFile) : undefined;
      return {
        owner: "foreign",
        controller: target,
        ...(secret ? { secret } : {}),
        managed: false,
        ...(adoption.configFile ? { configPath: adoption.configFile } : {}),
      };
    }
  }

  const hasManagedConfig = await Bun.file(layout.configPath)
    .text()
    .then(() => true)
    .catch(() => false);
  if (!hasManagedConfig) return undefined;
  const secret = await readSecretOf(layout.configPath);
  return {
    owner: "a2",
    controller: layout.controller,
    ...(secret ? { secret } : {}),
    managed: true,
    configPath: layout.configPath,
  };
}

/** 「实例没了」那条报警自带的指引 —— 与 06 票 `a2 mihomo install` 的拒绝报文同一口径。 */
function downGuidance(target: WatchTarget): ProxySupervisionEvent["guidance"] {
  return target.managed
    ? {
        summary: "a2 自管的那份 mihomo 没在应答。它由系统 supervisor 托管,先看它现在什么状态。",
        steps: [
          { description: "看 mihomo 现状(进程面 + 控制面)", command: "a2 mihomo status --json" },
          { description: "让它就位(幂等)", command: "a2 mihomo install --json" },
        ],
        context: { controller: target.controller, owner: target.owner },
      }
    : {
        summary: "被收编的那个实例没在应答 —— 它的生命周期归原托管方,内核绝不替你重拉。",
        steps: [
          { description: "按你原本的方式把那个 mihomo 拉起来" },
          { description: "拉起来之后重新检测", command: "a2 mihomo status --json" },
          {
            description: "或者让 a2 装一份自管实例(与你那份并存,入站端口需自行避开冲突)",
            command: "a2 mihomo install --isolated --json",
          },
        ],
        context: { controller: target.controller, owner: target.owner },
      };
}
