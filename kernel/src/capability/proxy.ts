// 代理域能力集(07 票)—— **17 条真能力**,全部经注册表、经 daemon。
//
// 为什么它们是能力而 `a2 service` / `a2 mihomo` 不是(口径见 `test/swift-parity-map.md`「有意的契约变更」13):
// 这一族要对 external-controller 发**写**请求、要动**系统代理**、要读 daemon 里那份**存活观测** ——
// 每一件都必须有唯一的仲裁点(dangerous 默拒就在 `registry.invoke` 里)和唯一的状态持有者。
//
// 风险三档怎么定的:
//   * `safe` —— 只读(status / groups / ping / config.get / subscription.list / supervision);
//   * `normal` —— 可逆写(mode / node / 系统代理接管与还原 / config.set / 订阅激活与更新);
//   * `dangerous` —— **信任面或不可逆**:`subscription.add`(引入一份新的外部配置来源,沿旧 Swift 逐字)
//     与 `subscription.remove`(抹掉用户自己攒的东西,不可逆 —— 旧系统没有这条命令,按"不可逆写"就高不就低)。
//
// 无确认器时 dangerous 一律 fail-closed 默拒(退出码 2)+ 拒绝即指引 —— 那是 04 票的底座,这里什么都不用做。

import {
  ErrorCode,
  ProxySettingsSchema,
  type JsonValue,
  type ProxySettings,
} from "../contract/wire.ts";
import {
  ControllerError,
  patchConfigs,
  readConfigs,
  readCurrentNode,
  readGroups,
  selectNode,
  testGroupDelay,
} from "../mihomo/controller.ts";
import { mihomoLayout } from "../mihomo/paths.ts";
import { applyManagedConfig, readSettings, resolveDesiredConfig, writeSettings } from "../proxy/config.ts";
import { requireManaged, requireReachable, resolveProxyTarget, type ProxyTarget } from "../proxy/endpoint.ts";
import {
  captureLive,
  createNetworkSetup,
  readSnapshot,
  restore,
  snapshotPath,
  SystemProxyError,
  SystemProxyUnsupportedError,
  takeover,
  type NetworkSetupPort,
} from "../proxy/system-proxy.ts";
import type { ProxySupervisor } from "../proxy/supervision.ts";
import {
  assertUsableBody,
  CatalogCorruptError,
  fetchSubscription,
  readCatalog,
  readSubscriptionBody,
  removeSubscriptionBody,
  subscriptionId,
  SubscriptionBodyError,
  SubscriptionError,
  writeCatalog,
  writeSubscriptionBody,
  type SubscriptionFetcher,
} from "../proxy/subscriptions.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { CapabilityFailedError, type Capability } from "./registry.ts";

/** 测速的默认值(逐字沿用旧 `aa`)。 */
export const DEFAULT_LATENCY_URL = "http://www.gstatic.com/generate_204";
export const DEFAULT_LATENCY_TIMEOUT_MS = 5000;
/**
 * 测速 timeout 的取值域。**上界不是洁癖**:旧实现有一条被记过账的洞 —— `1e300` 这种有限但超大的数
 * 经 `Int(Double)` 转换会当场把宿主打崩。TS 侧不会崩,但一个 1e300 毫秒的超时等于把这条请求挂死,
 * 同样不可接受,所以钳制原样保留(越界 → `invalid_params`,**在发任何请求之前**)。
 */
export const LATENCY_TIMEOUT_MIN_MS = 1;
export const LATENCY_TIMEOUT_MAX_MS = 600_000;

/** 代理能力的运行上下文(由 daemon runtime 注入,handler 闭包持有)。 */
export interface ProxyContext {
  paths: KernelPaths;
  env: Record<string, string | undefined>;
  supervisor: ProxySupervisor;
  /** 订阅拉取口(测试注入纯内存假件;生产是 `fetchSubscription`)。 */
  fetch?: SubscriptionFetcher;
}

export function proxyCapabilities(context: ProxyContext): Capability[] {
  return [
    status(context),
    configGet(context),
    configSet(context),
    modeGet(context),
    modeSet(context),
    groupsList(context),
    nodeSelect(context),
    latencyTest(context),
    systemStatus(context),
    systemEnable(context),
    systemDisable(context),
    subscriptionList(context),
    subscriptionAdd(context),
    subscriptionUpdate(context),
    subscriptionActivate(context),
    subscriptionRemove(context),
    supervisionGet(context),
  ];
}

// MARK: - 状态

function status(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.status",
      risk: "safe",
      summary:
        "报告代理控制面实况:实例在不在、控制面通不通、模式/入站端口/当前节点/版本,以及系统代理有没有被 a2 接管(只读)",
      parameters: [],
      cliAlias: ["proxy", "status"],
    },
    handler: async () => {
      const system = await systemProxySummary(context);
      // **没有实例不是错误**:如实报「没在跑」,退出码 0(与 `a2 service status` 同一口径)。
      const target = await resolveProxyTarget(context.paths, context.env).catch(() => undefined);
      if (!target) {
        return payload({ running: false, apiReachable: false, systemProxy: system });
      }

      const base = {
        running: target.running,
        apiReachable: target.apiReachable,
        endpoint: target.endpoint,
        ...(target.version ? { version: target.version } : {}),
        systemProxy: system,
      };
      // 控制面不通时**绝不臆造** mode/端口/节点 —— 那几个字段直接缺席。
      if (!target.apiReachable) return payload(base);

      const configs = await readConfigs(target.controller).catch(() => undefined);
      const node = await readCurrentNode(target.controller).catch(() => undefined);
      return payload({
        ...base,
        ...(configs?.mode ? { mode: configs.mode } : {}),
        ...(configs?.mixedPort ? { mixedPort: configs.mixedPort } : {}),
        ...(node ? { node } : {}),
      });
    },
  };
}

// MARK: - 配置面

function configGet(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.config.get",
      risk: "safe",
      summary: "读 a2 自管配置的可调项(入站端口、局域网、日志档、默认模式)与磁盘是否已收敛(只读)",
      parameters: [],
      cliAlias: ["proxy", "config"],
    },
    handler: async () => {
      const layout = mihomoLayout(context.paths, context.env);
      const desired = await withSubscriptionErrors(() =>
        resolveDesiredConfig(layout, context.env),
      );
      const current = await Bun.file(layout.configPath)
        .text()
        .catch(() => undefined);
      return payload({
        settings: desired.settings,
        configPath: layout.configPath,
        controller: layout.controller,
        activeSubscription: desired.activeSubscription,
        inSync: current === desired.text,
        actions: [],
      });
    },
  };
}

function configSet(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.config.set",
      risk: "normal",
      summary:
        "改 a2 自管配置的可调项并让内核重载(可逆写;只对 a2 自管那份有效,被收编的实例返回 mihomo_not_managed)",
      parameters: [
        {
          name: "mixedPort",
          type: "number",
          required: false,
          description: "混合入站端口(HTTP + SOCKS 同一个;系统代理接管指向的就是它)",
        },
        { name: "allowLan", type: "boolean", required: false, description: "是否允许局域网连入" },
        {
          name: "logLevel",
          type: "string",
          required: false,
          description: "mihomo 日志档",
          allowedValues: ["silent", "error", "warning", "info", "debug"],
        },
        {
          name: "mode",
          type: "string",
          required: false,
          description: "写进配置文件的默认模式(运行时切模式请用 proxy.mode.set,那条不落盘)",
          allowedValues: ["rule", "global", "direct"],
        },
      ],
      cliAlias: ["proxy", "config", "set"],
    },
    handler: async (input) => {
      const target = await resolveProxyTarget(context.paths, context.env);
      requireManaged(target, "改自管配置");

      const layout = target.layout;
      const before = await readSettings(layout, context.env);
      const wanted = ProxySettingsSchema.parse({
        mixedPort: numberOr(input["mixedPort"], before.mixedPort),
        allowLan: booleanOr(input["allowLan"], before.allowLan),
        logLevel: stringOr(input["logLevel"], before.logLevel),
        mode: stringOr(input["mode"], before.mode),
      } satisfies Record<keyof ProxySettings, unknown>);

      const actions: string[] = [];
      if (await writeSettings(layout, wanted)) actions.push("settings_written");
      const desired = await withSubscriptionErrors(() => resolveDesiredConfig(layout, context.env));
      const applied = await applyManagedConfig(target, desired);
      if (applied.written) actions.push("config_written");
      if (applied.reloaded) actions.push("config_reloaded");

      return payload({
        settings: desired.settings,
        configPath: layout.configPath,
        controller: layout.controller,
        activeSubscription: desired.activeSubscription,
        inSync: true,
        actions,
      });
    },
  };
}

// MARK: - 模式

function modeGet(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.mode.get",
      risk: "safe",
      summary: "读内核此刻的代理模式(只读;原样透传内核给的字符串,不强枚举)",
      parameters: [],
      cliAlias: ["proxy", "mode", "get"],
    },
    handler: async () => {
      const target = await reachableTarget(context);
      const configs = await withController(() => readConfigs(target.controller));
      return payload({ endpoint: target.endpoint, mode: configs.mode });
    },
  };
}

function modeSet(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.mode.set",
      risk: "normal",
      summary: "切换代理模式:rule(规则)/ global(全局)/ direct(直连)(可逆写,零确认打断)",
      parameters: [
        {
          name: "mode",
          type: "string",
          required: true,
          description: "目标模式,取值 rule|global|direct(必填,大小写敏感)",
          allowedValues: ["rule", "global", "direct"],
        },
      ],
      cliAlias: ["proxy", "mode"],
    },
    handler: async (input) => {
      const mode = input["mode"] as string;
      const target = await reachableTarget(context);
      // 改的是**运行时开关**:`PATCH /configs`,不换配置文件、不碰进程 ——
      // 所以这一条对被收编的实例同样成立(票面:收编档的写面到配置为止)。
      await withController(() => patchConfigs(target.controller, { mode }));
      return payload({ endpoint: target.endpoint, mode, set: true });
    },
  };
}

// MARK: - 分组 / 节点 / 测速

function groupsList(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.groups.list",
      risk: "safe",
      summary: "列出代理分组:每组的候选节点(all)与当前选中(now),按组名排序(只读)",
      parameters: [],
      cliAlias: ["proxy", "groups"],
    },
    handler: async () => {
      const target = await reachableTarget(context);
      const groups = await withController(() => readGroups(target.controller));
      return payload({ endpoint: target.endpoint, groups });
    },
  };
}

function nodeSelect(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.node.select",
      risk: "normal",
      summary: "按组选节点:把指定分组的当前选中切到指定节点(可逆写,零确认打断)",
      parameters: [
        {
          name: "group",
          type: "string",
          required: true,
          description: "目标代理分组名(必填;见 proxy.groups.list)",
        },
        {
          name: "node",
          type: "string",
          required: true,
          description: "要选中的节点名(必填;须为该组候选之一,由内核判定)",
        },
      ],
      cliAlias: ["proxy", "node"],
    },
    handler: async (input) => {
      const group = input["group"] as string;
      const node = input["node"] as string;
      const target = await reachableTarget(context);
      await withController(() => selectNode(target.controller, group, node));
      return payload({ endpoint: target.endpoint, group, node, selected: true });
    },
  };
}

function latencyTest(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.latency.test",
      risk: "safe",
      summary:
        "按组 URL 测速:返回该组逐节点延迟,超时节点如实标注(timeout=true 且不给 delayMs,绝不臆造 0)(只读)",
      parameters: [
        {
          name: "group",
          type: "string",
          required: true,
          description: "目标代理分组名(必填;见 proxy.groups.list)",
        },
        {
          name: "timeout",
          type: "number",
          required: false,
          description: `单节点超时毫秒(可选,默认 ${DEFAULT_LATENCY_TIMEOUT_MS};取值域 ${LATENCY_TIMEOUT_MIN_MS}..${LATENCY_TIMEOUT_MAX_MS})`,
        },
        {
          name: "url",
          type: "string",
          required: false,
          description: `测试 URL(可选,默认 ${DEFAULT_LATENCY_URL})`,
        },
      ],
      cliAlias: ["proxy", "ping"],
    },
    handler: async (input) => {
      const group = input["group"] as string;
      const timeoutMs = latencyTimeout(input["timeout"]);
      const url = typeof input["url"] === "string" ? input["url"] : DEFAULT_LATENCY_URL;
      const target = await reachableTarget(context);
      const results = await withController(() =>
        testGroupDelay(target.controller, group, url, timeoutMs),
      );
      return payload({ endpoint: target.endpoint, group, url, timeoutMs, results });
    },
  };
}

/** 超时钳制。**在发任何请求之前**,越界即 `invalid_params`(退出码 6)。 */
function latencyTimeout(raw: JsonValue | undefined): number {
  if (raw === undefined || raw === null) return DEFAULT_LATENCY_TIMEOUT_MS;
  const value = raw as number;
  if (
    !Number.isFinite(value) ||
    value < LATENCY_TIMEOUT_MIN_MS ||
    value > LATENCY_TIMEOUT_MAX_MS
  ) {
    throw new CapabilityFailedError(
      `timeout 须为 ${LATENCY_TIMEOUT_MIN_MS}..${LATENCY_TIMEOUT_MAX_MS} 毫秒之间的有限数,收到 ${value}。`,
      "越界的超时值在发出任何请求之前就被拒绝(它既没有意义,也会把这条调用挂死)。",
      { code: ErrorCode.invalidParams },
    );
  }
  return Math.trunc(value);
}

// MARK: - 系统代理

function systemStatus(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.system.status",
      risk: "safe",
      summary: "读系统代理实况:逐网络服务 × 逐类型的当前设置,以及 a2 手里有没有接管快照(只读)",
      parameters: [],
      cliAlias: ["proxy", "system"],
    },
    handler: async () => payload(await systemStatusResult(context)),
  };
}

function systemEnable(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.system.enable",
      risk: "normal",
      summary:
        "接管系统代理:把各网络服务的 HTTP/HTTPS/SOCKS 指向本机 mihomo 的混合端口(可逆写;还原请用 proxy.system.disable)",
      parameters: [],
      cliAlias: ["proxy", "on"],
    },
    handler: async () => {
      const net = networkSetup(context);
      const target = await reachableTarget(context);
      // 端口取**内核实况**(`GET /configs` 的 mixed-port),不取配置文件里写的那个:
      // 内核正在听哪个端口只有它自己知道,接管必须指向真在听的那个。
      const configs = await withController(() => readConfigs(target.controller));
      if (!configs.mixedPort) {
        throw new CapabilityFailedError(
          "内核没有报出混合入站端口,已拒绝接管系统代理(零写入)。",
          `控制端点 ${target.endpoint.controller} 的 /configs 里没有 mixed-port。` +
            "把系统代理指到一个不存在的端口 = 立刻断网,所以这一步宁可不做。",
          {
            code: ErrorCode.systemProxyFailed,
            guidance: {
              summary: "先确认内核起来了、混合端口配好了,再接管。",
              steps: [
                { description: "看代理实况", command: "a2 proxy status --json" },
                { description: "看自管配置的可调项", command: "a2 proxy config --json" },
              ],
              context: { controller: target.endpoint.controller },
            },
          },
        );
      }

      const result = await withSystemProxy(() =>
        takeover(context.paths, net, "127.0.0.1", configs.mixedPort as number),
      );
      return payload({
        enabled: true,
        host: result.snapshot.host,
        port: result.snapshot.port,
        status: await systemStatusResult(context, net, result.live),
      });
    },
  };
}

function systemDisable(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.system.disable",
      risk: "normal",
      summary:
        "还原系统代理:按接管前快照逐服务逐类型精确还原(含原本就有的第三方代理)。这是「退出即还原」废除后唯一的还原入口",
      parameters: [],
      cliAlias: ["proxy", "off"],
    },
    handler: async () => {
      const net = networkSetup(context);
      // **有意不要求内核可达**:还原是善后动作 —— mihomo 死了、内核刚崩过、快照是上一世代留下的,
      // 恰恰是最需要它能跑通的时候。它只读快照、只写 networksetup,与 mihomo 无关。
      const result = await withSystemProxy(() => restore(context.paths, net));
      return payload({
        enabled: false,
        restored: result.restored,
        status: await systemStatusResult(context, net, result.live),
      });
    },
  };
}

// MARK: - 订阅

function subscriptionList(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.subscription.list",
      risk: "safe",
      summary: "列出全部订阅(id / 名字 / 源 / 最近更新时间)与当前激活项(只读,不碰内核)",
      parameters: [],
      cliAlias: ["proxy", "subscription", "list"],
    },
    handler: async () => {
      const layout = mihomoLayout(context.paths, context.env);
      const catalog = await withSubscriptionErrors(() => readCatalog(layout));
      return payload({
        active: catalog.activeId,
        subscriptions: catalog.subscriptions,
        directory: layout.subscriptionsDir,
      });
    },
  };
}

function subscriptionAdd(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.subscription.add",
      risk: "dangerous",
      summary:
        "新增或替换订阅源:拉取并物化配置,同名覆盖=换源。**不自动激活**。dangerous —— 它往内核的信任面里放进一份新的外部配置来源",
      parameters: [
        {
          name: "name",
          type: "string",
          required: true,
          description: "订阅展示名(必填;归一为 id,同名覆盖 = 替换源)",
        },
        {
          name: "source",
          type: "string",
          required: true,
          description: "订阅源:http(s):// URL 或 file:// 路径(必填)",
        },
      ],
      cliAlias: ["proxy", "subscription", "add"],
    },
    handler: async (input) => {
      const layout = mihomoLayout(context.paths, context.env);
      const name = input["name"] as string;
      const source = input["source"] as string;
      // 参数校验**前置于所有 I/O**:名字不成立就不该拉取、不该写盘。
      const id = subscriptionId(name);
      if (!id) {
        throw new CapabilityFailedError(
          "订阅名不能是空白。",
          `收到 ${JSON.stringify(name)};id 由名字确定性派生,空名派生不出 id。`,
          { code: ErrorCode.invalidParams },
        );
      }

      const catalog = await withSubscriptionErrors(() => readCatalog(layout));
      const existing = catalog.subscriptions.find((entry) => entry.id === id);
      const body = await withSubscriptionErrors(() => (context.fetch ?? fetchSubscription)(source));
      // **落盘之前**先看这份正文 a2 拼不拼得进自管配置:坏东西根本不该进库。
      await withSubscriptionErrors(() => assertUsableBody(body, source));

      await withSubscriptionErrors(() => writeSubscriptionBody(layout, id, body));
      const entry = {
        id,
        name: name.trim(),
        source,
        lastUpdatedAt: new Date().toISOString(),
        bytes: new TextEncoder().encode(body).byteLength,
      };
      const next = [...catalog.subscriptions.filter((item) => item.id !== id), entry];
      await withSubscriptionErrors(() =>
        writeCatalog(layout, { subscriptions: next, activeId: catalog.activeId }),
      );

      return payload({
        id,
        action: existing ? "replaced" : "added",
        subscription: entry,
        active: catalog.activeId,
        // **add 绝不自动激活**:引入一份来源与让它生效是两个决定,分开做。
        reloaded: false,
      });
    },
  };
}

function subscriptionUpdate(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.subscription.update",
      risk: "normal",
      summary:
        "更新已有订阅:重新拉取并物化;若为激活项则让内核重载,重载失败自动回滚到旧配置(可逆写,零确认打断)",
      parameters: [
        { name: "id", type: "string", required: true, description: "要更新的订阅 id(必填;见 proxy.subscription.list)" },
      ],
      cliAlias: ["proxy", "subscription", "update"],
    },
    handler: async (input) => {
      const id = input["id"] as string;
      const layout = mihomoLayout(context.paths, context.env);
      const catalog = await withSubscriptionErrors(() => readCatalog(layout));
      const entry = catalog.subscriptions.find((item) => item.id === id);
      if (!entry) throw unknownSubscription(id, catalog.subscriptions.map((item) => item.id));

      const body = await withSubscriptionErrors(() =>
        (context.fetch ?? fetchSubscription)(entry.source),
      );
      // 同 add:拉到的新正文若拼不进自管配置,**旧的那份原样留着**,一个字节都不动。
      await withSubscriptionErrors(() => assertUsableBody(body, entry.source));
      const oldBody = await readSubscriptionBody(layout, id);
      await withSubscriptionErrors(() => writeSubscriptionBody(layout, id, body));

      let reloaded = false;
      if (catalog.activeId === id) {
        const target = await resolveProxyTarget(context.paths, context.env);
        requireManaged(target, "让内核重载订阅配置");
        try {
          const desired = await withSubscriptionErrors(() =>
            resolveDesiredConfig(layout, context.env),
          );
          reloaded = (await applyManagedConfig(target, desired)).reloaded;
        } catch (error) {
          // 新配置内核不认:把旧字节写回去(`applyManagedConfig` 已经把 config.yaml 回滚过了,
          // 这里补上物化文件那一份,免得清单说"更新了"而磁盘上躺着一份内核不认的东西)。
          if (oldBody !== undefined) await writeSubscriptionBody(layout, id, oldBody).catch(() => {});
          throw error;
        }
      }

      const updated = {
        ...entry,
        lastUpdatedAt: new Date().toISOString(),
        bytes: new TextEncoder().encode(body).byteLength,
      };
      await withSubscriptionErrors(() =>
        writeCatalog(layout, {
          subscriptions: catalog.subscriptions.map((item) => (item.id === id ? updated : item)),
          activeId: catalog.activeId,
        }),
      );
      return payload({
        id,
        action: "updated",
        subscription: updated,
        active: catalog.activeId,
        reloaded,
      });
    },
  };
}

function subscriptionActivate(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.subscription.activate",
      risk: "normal",
      summary:
        "激活指定订阅:把它的正文渲染进 a2 自管配置并让内核重载(同一时刻只激活一个;可逆写,零确认打断)",
      parameters: [
        { name: "id", type: "string", required: true, description: "要激活的订阅 id(必填;见 proxy.subscription.list)" },
      ],
      cliAlias: ["proxy", "subscription", "activate"],
    },
    handler: async (input) => {
      const id = input["id"] as string;
      const layout = mihomoLayout(context.paths, context.env);
      const catalog = await withSubscriptionErrors(() => readCatalog(layout));
      const entry = catalog.subscriptions.find((item) => item.id === id);
      if (!entry) throw unknownSubscription(id, catalog.subscriptions.map((item) => item.id));

      const target = await resolveProxyTarget(context.paths, context.env);
      requireManaged(target, "激活订阅");

      const previousActive = catalog.activeId;
      await withSubscriptionErrors(() =>
        writeCatalog(layout, { subscriptions: catalog.subscriptions, activeId: id }),
      );
      try {
        const desired = await withSubscriptionErrors(() => resolveDesiredConfig(layout, context.env));
        const applied = await applyManagedConfig(target, desired);
        return payload({
          id,
          action: "activated",
          subscription: entry,
          active: id,
          reloaded: applied.reloaded,
        });
      } catch (error) {
        // 内核不认这份配置:清单也退回去 —— **不留半态**(磁盘上的 config.yaml 已由事务回滚)。
        await writeCatalog(layout, {
          subscriptions: catalog.subscriptions,
          activeId: previousActive,
        }).catch(() => {});
        throw error;
      }
    },
  };
}

function subscriptionRemove(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.subscription.remove",
      risk: "dangerous",
      summary:
        "删除一条订阅(清单条目 + 物化配置)。dangerous —— 它抹掉的是你自己攒的东西,且不可逆;若删的是激活项,配置会退回默认直连骨架",
      parameters: [
        { name: "id", type: "string", required: true, description: "要删除的订阅 id(必填;见 proxy.subscription.list)" },
      ],
      cliAlias: ["proxy", "subscription", "remove"],
    },
    handler: async (input) => {
      const id = input["id"] as string;
      const layout = mihomoLayout(context.paths, context.env);
      const catalog = await withSubscriptionErrors(() => readCatalog(layout));
      const entry = catalog.subscriptions.find((item) => item.id === id);
      if (!entry) throw unknownSubscription(id, catalog.subscriptions.map((item) => item.id));

      const wasActive = catalog.activeId === id;
      await withSubscriptionErrors(() =>
        writeCatalog(layout, {
          subscriptions: catalog.subscriptions.filter((item) => item.id !== id),
          activeId: wasActive ? null : catalog.activeId,
        }),
      );
      await removeSubscriptionBody(layout, id);

      let reloaded = false;
      if (wasActive) {
        const target = await resolveProxyTarget(context.paths, context.env).catch(() => undefined);
        if (target?.endpoint.managed) {
          const desired = await withSubscriptionErrors(() =>
            resolveDesiredConfig(layout, context.env),
          );
          reloaded = (await applyManagedConfig(target, desired)).reloaded;
        }
      }
      return payload({
        id,
        action: "removed",
        active: wasActive ? null : catalog.activeId,
        reloaded,
      });
    },
  };
}

// MARK: - 存活监督

function supervisionGet(context: ProxyContext): Capability {
  return {
    descriptor: {
      id: "proxy.supervision.get",
      risk: "safe",
      summary:
        "读 daemon 里那条存活观测的当下状态与最近事件(只读;事件全量在 logPath 指的 NDJSON 文件里)",
      parameters: [],
      cliAlias: ["proxy", "supervision"],
    },
    handler: () => payload(context.supervisor.snapshot()),
  };
}

// MARK: - 共用

/**
 * 能力返回值 → `JsonValue`。
 *
 * handler 的返回值本质上是"某个已登记 result 的形状"(`ProxyStatusResult` 之类),而 `JsonValue` 是个
 * 递归联合类型 —— TS 不认为一个具名 interface 结构化地属于它(可选字段的 `| undefined` 在联合里对不上),
 * 于是每处都要写一遍 `as unknown as JsonValue`。**运行时什么都没发生**:那些对象本来就只含 JSON 值。
 * 收敛到这一个函数,是为了让"这里有一次类型放行"只需要读一遍、也只有一个地方可以出错。
 * (真正的形状把关在别处:CLI 侧 `outcomeFromEnvelope` 拿 zod schema 校验 daemon 的应答,漂了就红。)
 */
function payload(value: object): JsonValue {
  return value as unknown as JsonValue;
}

async function reachableTarget(context: ProxyContext): Promise<ProxyTarget> {
  const target = await resolveProxyTarget(context.paths, context.env);
  requireReachable(target);
  return target;
}

/** 控制面的失败 → `proxy_operation_failed` + 一条能看清现状的指引。 */
async function withController<T>(body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (!(error instanceof ControllerError)) throw error;
    throw new CapabilityFailedError("mihomo 控制面拒绝了这次操作。", error.message, {
      code: ErrorCode.proxyOperationFailed,
      guidance: {
        summary: "先看清楚内核此刻的实况(分组名/节点名是否存在、模式是否可切),再重试。",
        steps: [
          { description: "看代理实况", command: "a2 proxy status --json" },
          { description: "看有哪些分组与候选节点", command: "a2 proxy groups --json" },
        ],
      },
    });
  }
}

/** 系统代理的失败 → 两个码分开(平台不支持 = 6,别的 = 5)。 */
async function withSystemProxy<T>(body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof SystemProxyUnsupportedError) throw unsupportedSystemProxy(error);
    if (error instanceof SystemProxyError) {
      throw new CapabilityFailedError(error.message, error.detail, {
        code: ErrorCode.systemProxyFailed,
        guidance: {
          summary: "系统代理这条路没走通。先看实况,必要时手工核对系统设置。",
          steps: [
            { description: "看系统代理实况(a2 记不记着接管快照)", command: "a2 proxy system --json" },
            { description: "把系统代理还原回接管前(幂等)", command: "a2 proxy off --json" },
          ],
        },
      });
    }
    throw error;
  }
}

/** 订阅面的失败 → `subscription_failed`;清单损坏那条另给一份"别覆盖它"的指引。 */
async function withSubscriptionErrors<T>(body: () => Promise<T> | T): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof CatalogCorruptError) {
      throw new CapabilityFailedError(error.message, error.detail ?? "", {
        code: ErrorCode.subscriptionFailed,
        guidance: {
          summary:
            "内核绝不把损坏的清单当成空清单覆盖掉 —— 那会一次性抹掉你所有订阅。请人工检查后再决定。",
          steps: [
            { description: "看那份清单", command: `cat ${error.catalogPath}` },
            {
              description: "确认它确实没救之后,自己把它移走(内核不替你删)",
              command: `mv ${error.catalogPath} ${error.catalogPath}.broken`,
            },
          ],
          context: { catalogPath: error.catalogPath },
        },
      });
    }
    if (error instanceof SubscriptionBodyError) {
      throw new CapabilityFailedError(error.message, error.detail ?? "", {
        code: ErrorCode.subscriptionFailed,
        guidance: {
          summary:
            "a2 不会替你猜该保留哪一段 —— 请把这份订阅裁成单文档 YAML(去掉文档分隔符)后再换源。",
          steps: [
            { description: `打开那份订阅,看第 ${error.line} 行前后是不是两份配置被粘在了一起` },
            {
              description: "裁成单文档之后重新换源(add 同名即换源)",
              command: "a2 proxy subscription add --name <名字> --source <裁好的源> --json",
            },
            { description: "看当前有哪些订阅", command: "a2 proxy subscription list --json" },
          ],
          context: { line: String(error.line) },
        },
      });
    }
    if (error instanceof SubscriptionError) {
      throw new CapabilityFailedError(error.message, error.detail ?? "", {
        code: ErrorCode.subscriptionFailed,
        guidance: {
          summary: "订阅这一步没成。失败不留痕:清单与物化配置都没被改。",
          steps: [
            { description: "看当前有哪些订阅", command: "a2 proxy subscription list --json" },
          ],
        },
      });
    }
    throw error;
  }
}

function unknownSubscription(id: string, known: string[]): CapabilityFailedError {
  return new CapabilityFailedError(
    `没有 id 为 ${id} 的订阅。`,
    known.length === 0 ? "当前一条订阅都没有。" : `已有的订阅 id:${known.join("、")}`,
    {
      code: ErrorCode.subscriptionFailed,
      guidance: {
        summary: "先列出订阅拿到正确的 id。",
        steps: [{ description: "列出全部订阅", command: "a2 proxy subscription list --json" }],
        context: { id },
      },
    },
  );
}

function unsupportedSystemProxy(error: SystemProxyUnsupportedError): CapabilityFailedError {
  return new CapabilityFailedError("本平台没有已支持的系统代理接管路径。", error.reason, {
    code: ErrorCode.systemProxyUnsupported,
    guidance: {
      summary:
        "系统代理接管 V1 只支持 macOS。Linux 上请按你的桌面环境/代理链自行指向 mihomo 的混合端口。",
      steps: [
        { description: "看 mihomo 正在听哪个混合端口", command: "a2 proxy status --json" },
        {
          description: "然后按你的环境自行设置(例如)",
          command: "export ALL_PROXY=http://127.0.0.1:<mixedPort>",
        },
      ],
    },
  });
}

function networkSetup(context: ProxyContext): NetworkSetupPort {
  try {
    return createNetworkSetup(context.env);
  } catch (error) {
    if (error instanceof SystemProxyUnsupportedError) throw unsupportedSystemProxy(error);
    throw error;
  }
}

/** 紧凑摘要(嵌进 `proxy.status`)。**永不抛** —— 平台不支持只是 `supported: false`。 */
async function systemProxySummary(context: ProxyContext) {
  let supported = true;
  try {
    createNetworkSetup(context.env);
  } catch {
    supported = false;
  }
  const snapshot = await readSnapshot(context.paths);
  return {
    supported,
    takenOver: snapshot !== undefined,
    ...(snapshot?.host ? { host: snapshot.host } : {}),
    ...(snapshot?.port ? { port: snapshot.port } : {}),
  };
}

async function systemStatusResult(
  context: ProxyContext,
  net?: NetworkSetupPort,
  live?: Awaited<ReturnType<typeof captureLive>>,
) {
  const summary = await systemProxySummary(context);
  const snapshot = await readSnapshot(context.paths);
  let services = live;
  if (!services) {
    if (net) services = await withSystemProxy(() => captureLive(net));
    else if (summary.supported) services = await withSystemProxy(() => captureLive(networkSetup(context)));
    else services = [];
  }
  return {
    ...summary,
    snapshotPath: snapshotPath(context.paths),
    ...(snapshot?.takenOverAt ? { takenOverAt: snapshot.takenOverAt } : {}),
    services,
  };
}

function numberOr(value: JsonValue | undefined, fallback: number): number {
  return typeof value === "number" ? value : fallback;
}

function booleanOr(value: JsonValue | undefined, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function stringOr<T extends string>(value: JsonValue | undefined, fallback: T): T {
  return typeof value === "string" ? (value as T) : fallback;
}
