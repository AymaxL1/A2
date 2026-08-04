// 「我该跟哪个 external-controller 说话」—— 代理域每一条命令开头的那个问题。
//
// **答案只有一个来源**:`a2 mihomo status` 那套检测(06 票)。代理域不另起一套探测逻辑,
// 否则同一台机器上会出现两个来源不同、随时会打架的答案。代价是每条代理命令都要过一遍检测
// (一次 `mihomo -v` + 一次 supervisor 查询 + 一到两次回环 GET),换来的是"控制面永远只有一个真相"。
//
// 钥匙(secret)**每次现读**那份配置:自管档读 `<home>/mihomo/config.yaml`,收编档读别人那份 ——
// 它随时可能被主人改,缓存一把过期的钥匙只会让某次写操作毫无征兆地变成 401。

import { CapabilityFailedError } from "../capability/registry.ts";
import {
  ErrorCode,
  MihomoStatusResultSchema,
  type MihomoStatusResult,
  type ProxyEndpoint,
} from "../contract/wire.ts";
import type { ControllerTarget } from "../mihomo/controller.ts";
import { mihomoStatus } from "../mihomo/manager.ts";
import { MihomoEnv, mihomoLayout, readSecretOf, type MihomoLayout } from "../mihomo/paths.ts";
import type { KernelPaths } from "../runtime/paths.ts";

export interface ProxyTarget {
  /** 进报文的那一份(agent 据此知道这条命令刚才是在跟谁说话)。 */
  endpoint: ProxyEndpoint;
  /** 发请求要用的地址与钥匙。 */
  controller: ControllerTarget;
  /** 控制面此刻答不答话。 */
  apiReachable: boolean;
  /**
   * 此刻有没有一个可用于控制的实例。判据:控制面可达,**或**(自管档且 supervisor 报了 pid)。
   * 后半句保住了旧口径里那条独立事实 ——「进程活着但控制面还没就绪」不该被说成"没在跑"。
   * 收编档没有后半句:别人的进程生死归原托管方,内核对它只有控制面这一个观察窗口(这是红线,不是遗漏)。
   */
  running: boolean;
  version?: string;
  layout: MihomoLayout;
  /** 原始检测结果(需要更细的事实时直接取,不重新探一遍)。 */
  status: MihomoStatusResult;
}

/**
 * 解析当前该说话的端点。**一个实例都没有**时抛 `mihomo_unreachable` + 指引 ——
 * 这不是"内部错误",是"这条路此刻走不通",agent 该拿到的是下一步命令而不是堆栈。
 */
export async function resolveProxyTarget(
  paths: KernelPaths,
  env: Record<string, string | undefined> = process.env,
): Promise<ProxyTarget> {
  const outcome = await mihomoStatus(paths);
  if (!outcome.ok) {
    throw new CapabilityFailedError(
      "读不到本机 mihomo 现状,代理控制面无从谈起。",
      outcome.error.detail ?? outcome.error.message,
      { code: ErrorCode.mihomoUnreachable, ...(outcome.error.guidance ? { guidance: outcome.error.guidance } : {}) },
    );
  }
  const status = MihomoStatusResultSchema.parse(outcome.result);
  const layout = mihomoLayout(paths, env);
  const instance = status.instance;

  if (!instance) {
    throw new CapabilityFailedError(
      "本机没有可用于控制的 mihomo 实例。",
      `现状:${status.presence};将采用的阶梯档位:${status.rung}。`,
      {
        code: ErrorCode.mihomoUnreachable,
        guidance: {
          summary: "先让一个 mihomo 就位(a2 自管或你自己那份),代理域的命令才有对象。",
          steps: [
            { description: "看本机现状与将采用的档位", command: "a2 mihomo status --json" },
            { description: "让它按阶梯就位(幂等)", command: "a2 mihomo install --json" },
          ],
          context: { home: paths.home, presence: status.presence, rung: status.rung },
        },
      },
    );
  }

  const managed = instance.owner === "a2";
  const secret = managed
    ? await readSecretOf(layout.configPath)
    : instance.configFile
      ? await readSecretOf(instance.configFile)
      : env[MihomoEnv.secret]?.trim() || undefined;

  const apiReachable = instance.capabilities.includes("rest_api");
  return {
    endpoint: {
      owner: instance.owner,
      controller: instance.controller,
      managed,
      ...(managed ? { configPath: layout.configPath } : {}),
    },
    controller: { target: instance.controller, ...(secret ? { secret } : {}) },
    apiReachable,
    running: apiReachable || (managed && status.managed.state === "running"),
    ...(instance.version ? { version: instance.version } : {}),
    layout,
    status,
  };
}

/**
 * 要求控制面此刻真的答话 —— 凡是要发写请求的能力,开头都得过这一关。
 * 拒绝报文里那条「人类可执行的重启命令」与 06 票 `mihomo install` 给的是同一句话(同源,不另写)。
 */
export function requireReachable(target: ProxyTarget): void {
  if (target.apiReachable) return;
  const managed = target.endpoint.managed;
  throw new CapabilityFailedError(
    `mihomo 的控制端点 ${target.endpoint.controller} 连不上,这条命令没有对象。`,
    managed
      ? "a2 自管的那份 mihomo 此刻没有应答(可能没起来,也可能刚起还没就绪)。"
      : "被收编的那个实例此刻没有应答 —— 它的生命周期归原托管方,内核不会替你重拉。",
    {
      code: ErrorCode.mihomoUnreachable,
      guidance: {
        summary: managed
          ? "让 a2 自管那份就位(幂等),再重试这条命令。"
          : "按你原本的方式把那个 mihomo 拉起来,再重试;内核只报警和指路。",
        steps: managed
          ? [
              { description: "让 a2 自管的 mihomo 就位(幂等)", command: "a2 mihomo install --json" },
              { description: "确认它真的在跑", command: "a2 mihomo status --json" },
            ]
          : [
              { description: "按你原本的方式把那个 mihomo 拉起来(内核不会替你重拉别人托管的进程)" },
              { description: "拉起来之后重新检测", command: "a2 mihomo status --json" },
            ],
        context: { controller: target.endpoint.controller, owner: target.endpoint.owner },
      },
    },
  );
}

/**
 * 要求这份归 a2 管 —— **「换配置文件」类动作的唯一闸门**(配置面收敛、订阅激活/更新)。
 *
 * 为什么收编档要在这里被挡住:`PUT /configs {path}` 的语义是「把配置整个换成我这份」。
 * 对别人的实例做这件事,等于替人家把配置抢了 —— 与「进程生死归原托管方」是同一条边界的两侧。
 * 收编档能做的写面到 `PATCH /configs`(改 mode)与 `PUT /proxies/<组>`(选节点)为止:
 * 那两条改的是运行时开关,不换文件、不碰进程。
 */
export function requireManaged(target: ProxyTarget, what: string): void {
  if (target.endpoint.managed) return;
  throw new CapabilityFailedError(
    `${what}只对 a2 自管的 mihomo 有效,当前控制的是别人托管的实例。`,
    `当前端点 ${target.endpoint.controller} 属于 ${target.endpoint.owner};` +
      "内核对被收编的实例只改运行时开关(模式、节点),绝不替它换配置文件。",
    {
      code: ErrorCode.mihomoNotManaged,
      guidance: {
        summary:
          "要让 a2 管配置与订阅,得让它拥有一份自己的实例;别人那份的配置请由它的主人维护。",
        steps: [
          { description: "看清楚现在是哪一档、各自是什么", command: "a2 mihomo status --json" },
          {
            description: "让 a2 装一份自管实例(与你那份并存,入站端口需自行避开冲突)",
            command: "a2 mihomo install --isolated --json",
          },
          { description: "对被收编的实例,这两条仍然可用", command: "a2 proxy mode --mode rule --json" },
        ],
        context: { controller: target.endpoint.controller, owner: target.endpoint.owner },
      },
    },
  );
}
