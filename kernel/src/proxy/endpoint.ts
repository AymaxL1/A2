// 「我该跟哪个 external-controller 说话」—— 代理域每一条命令开头的那个问题。
//
// **答案只有一个来源**:`a2 mihomo status` 那套检测(06 票)。代理域不另起一套探测逻辑,
// 否则同一台机器上会出现两个来源不同、随时会打架的答案。代价是每条代理命令都要过一遍检测
// (一次 `mihomo -v` + 一次 supervisor 查询 + 一到两次回环 GET),换来的是"控制面永远只有一个真相"。
//
// 钥匙(secret)**每次现读**那份配置:自管的读 `<home>/mihomo/config.yaml`,别人的读它自己那份 ——
// 它随时可能被主人改,缓存一把过期的钥匙只会让某次请求毫无征兆地变成 401。
//
// 收编档废除后(2026-08-12),别人的实例仍然会成为这里的 target ——「读它的状态」正是留下来的那件事。
// 变的是写面:能对 external-controller 发写请求的那几条能力已整体停用(见 `capability/proxy.ts`
// 的 `DISABLED_CAPABILITY_IDS`),所以本文件的两道闸目前只在停用能力的代码路径上还有调用点。

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
   * 此刻有没有一个可用于控制的实例。判据:控制面可达,**或**(embedded 且认尸文件判 running)。
   * 后半句保住了旧口径里那条独立事实 ——「进程活着但控制面还没就绪」不该被说成"没在跑"。
   * 别人那份没有后半句:它的进程生死归原托管方,内核对它只有控制面这一个观察窗口(这是红线,不是遗漏)。
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

  // embedded:代理域的对话对象恒是自己那份(它归 a2 管,写面的闸门也只对它开)。
  if (status.mode === "embedded") {
    // 故障态给**准确的码**(CR M5):mihomo_failed = 它在这台机器上、但坏着 ——
    // 与 mihomo_unreachable(压根没有对象)是两种处境,agent 的下一步也不同(restart,不是 enable)。
    if (status.embedded.state === "failed") {
      throw new CapabilityFailedError(
        "内置 mihomo 处于故障态(连续启动失败,已暂停重拉),代理控制面此刻没有对象。",
        status.embedded.lastError ?? "最近一次失败没有留下 stderr 输出。",
        {
          code: ErrorCode.mihomoFailed,
          guidance: {
            summary: "对照 lastError 修好配置,再重启内置内核(故障计数清零)。",
            steps: [
              { description: "看故障详情(lastError 原文 + 配置路径)", command: "a2 mihomo status --json" },
              { description: "修好后重启内置内核", command: "a2 mihomo restart --json" },
            ],
            context: { configPath: status.embedded.configPath },
          },
        },
      );
    }
    const secret = await readSecretOf(layout.configPath);
    const apiReachable = status.embedded.controllerReachable;
    return {
      endpoint: {
        owner: "a2",
        controller: status.embedded.controller,
        managed: true,
        configPath: layout.configPath,
      },
      controller: { target: status.embedded.controller, ...(secret ? { secret } : {}) },
      apiReachable,
      // 「进程活着但控制面还没就绪」不该被说成"没在跑"—— embedded 的进程事实来自认尸文件。
      running: apiReachable || status.embedded.state === "running",
      ...(status.embedded.binaryVersion ? { version: status.embedded.binaryVersion } : {}),
      layout,
      status,
    };
  }

  // observe / off:只可能跟别人那份说话(只读;写面在 requireManaged 处被挡)。
  const instance = status.foreign?.instance;
  if (!instance) {
    throw new CapabilityFailedError(
      "本机没有可用于控制的 mihomo 实例。",
      `托管模式:${status.mode};未检测到可达的外来实例。`,
      {
        code: ErrorCode.mihomoUnreachable,
        guidance: {
          summary: "先启用一种托管模式(embedded 推荐),代理域的命令才有对象。",
          steps: [
            { description: "看本机现状与两种模式的说明", command: "a2 mihomo status --json" },
            {
              description: "与用户确认后启用内置代理内核",
              command: "a2 mihomo enable --mode=embedded --json",
            },
          ],
          context: { home: paths.home, mode: status.mode },
        },
      },
    );
  }

  const secret = instance.configFile
    ? await readSecretOf(instance.configFile)
    : env[MihomoEnv.secret]?.trim() || undefined;
  const apiReachable = instance.capabilities.includes("rest_api");
  return {
    endpoint: { owner: "foreign", controller: instance.controller, managed: false },
    controller: { target: instance.controller, ...(secret ? { secret } : {}) },
    apiReachable,
    // 别人那份没有"进程窗口":它的生死归原托管方,内核对它只有控制面这一个观察窗口(红线,不是遗漏)。
    running: apiReachable,
    ...(instance.version ? { version: instance.version } : {}),
    layout,
    status,
  };
}

/**
 * 要求控制面此刻真的答话 —— 凡是要发写请求的能力,开头都得过这一关。
 * 拒绝报文里那条「人类可执行的命令」与 status 的 guidance 同源(restart / enable,不另写一套)。
 */
export function requireReachable(target: ProxyTarget): void {
  if (target.apiReachable) return;
  const managed = target.endpoint.managed;
  throw new CapabilityFailedError(
    `mihomo 的控制端点 ${target.endpoint.controller} 连不上,这条命令没有对象。`,
    managed
      ? "a2 自管的那份 mihomo 此刻没有应答(可能没起来,也可能刚起还没就绪)。"
      : "别人托管的那个实例此刻没有应答 —— 它的生命周期归原托管方,内核不会替你重拉。",
    {
      code: ErrorCode.mihomoUnreachable,
      guidance: {
        summary: managed
          ? "重启 a2 内置那份(或先看它为什么没起来),再重试这条命令。"
          : "按你原本的方式把那个 mihomo 拉起来,再重试;内核只报警和指路。",
        steps: managed
          ? [
              { description: "重启内置内核(故障态也走这条,计数清零)", command: "a2 mihomo restart --json" },
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
 * 为什么别人那份要在这里被挡住:`PUT /configs {path}` 的语义是「把配置整个换成我这份」。
 * 对别人的实例做这件事,等于替人家把配置抢了 —— 与「进程生死归原托管方」是同一条边界的两侧。
 *
 * 注:它的三个调用点(`proxy.config.set` / 订阅激活 / 订阅更新)当前都在停用名单里,
 * 所以这道闸此刻是**纵深而非第一道防线**。恢复那几条能力时它原样生效,不需要重新想一遍。
 */
export function requireManaged(target: ProxyTarget, what: string): void {
  if (target.endpoint.managed) return;
  throw new CapabilityFailedError(
    `${what}只对 a2 自管的 mihomo 有效,当前控制的是别人托管的实例。`,
    `当前端点 ${target.endpoint.controller} 属于 ${target.endpoint.owner};` +
      "内核绝不替别人的实例换配置文件。",
    {
      code: ErrorCode.mihomoNotManaged,
      guidance: {
        summary:
          "别人那份的配置请由它的主人(你自己、或你的 agent)直接改那份配置文件;内核只读它。",
        steps: [
          { description: "看清楚现在是哪一档、各自是什么", command: "a2 mihomo status --json" },
          {
            description: "要让 a2 管配置,启用内置模式(与你那份并行,端口自动错开)",
            command: "a2 mihomo enable --mode=embedded --json",
          },
        ],
        context: { controller: target.endpoint.controller, owner: target.endpoint.owner },
      },
    },
  );
}
