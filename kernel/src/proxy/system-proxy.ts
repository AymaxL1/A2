// 系统代理的接管与还原 —— **两个显式内核命令**,不挂任何客户端的生命周期。
//
// 「退出即还原」已废除(ADR 0008 / spec):壳退出只是断连,内核重启也不动系统代理。
// 于是「还原」必须是一条人能敲、agent 能调的命令,而它成立的前提是**快照落在磁盘上**:
// `<A2_HOME>/system-proxy.json`。谁把它写下来的、什么时候写的都不重要 —— 只要它在,
// `a2 proxy off` 就永远能把系统精确还原回接管前的样子,哪怕中间内核崩过、机器重启过。
//
// 三条从旧实现继承的硬性质(每一条都修过一个真事故):
//   1. **粒度对齐 networksetup**:逐网络服务 × 逐代理类型逐字段记录。这样"原本就有第三方代理"的服务
//      能被精确还原成那个第三方,而不是一律关掉(一律关掉 = 悄悄改了用户的网络配置)。
//   2. **先持久化,再写系统**。快照没落盘就动手,等于制造一个"接管了但还原不回去"的窗口;
//      持久化失败即 fail-closed,系统代理一个字节都不写。
//   3. **重复接管不覆盖首次快照**。第二次 enable 若把"已接管态"当成新快照存下来,
//      那 disable 就会把系统还原成"指向内核端口" —— 内核一旦没了,用户就永久断网。
//      接管之后新出现的服务(插了网线、连了 iPhone USB)则**并入**快照,各自记各自的原状。
//
// 与 mihomo 那一侧的关系:本文件只认「host:port」,不认识 mihomo。端口从哪来是调用方的事
// (`capability/proxy.ts` 从**内核实况** `GET /configs` 的 mixed-port 取 —— 配置文件里写的未必是它正在听的)。

import { rm } from "node:fs/promises";
import path from "node:path";
import {
  type NetworkServiceProxy,
  type ProxyKind,
  type ProxySetting,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";

/** 覆写 `networksetup` 可执行路径。**测试必须设它**(门禁绝不碰真的系统代理)。 */
export const NETWORKSETUP_ENV = "A2_NETWORKSETUP";

const DEFAULT_NETWORKSETUP = "/usr/sbin/networksetup";
const KINDS: ProxyKind[] = ["http", "https", "socks"];

/** 一次 `networksetup` 调用的上限。它是个本机命令,慢到这个份上说明有别的问题。 */
const NETWORKSETUP_TIMEOUT_MS = 10_000;

/** 关掉的那一档统一长这样(host 空、port 0)—— 归一之后快照才能逐字段比较。 */
const OFF: ProxySetting = { enabled: false, host: "", port: 0 };

/** 这一层的失败。上层翻成 `system_proxy_failed`(退出码 5)。 */
export class SystemProxyError extends Error {
  constructor(
    message: string,
    readonly detail: string,
  ) {
    super(message);
    this.name = "SystemProxyError";
  }
}

/** 本平台没有已支持的接管路径(V1 只有 macOS 的 networksetup)。上层翻成退出码 6。 */
export class SystemProxyUnsupportedError extends Error {
  constructor(readonly reason: string) {
    super("本平台没有已支持的系统代理接管路径。");
    this.name = "SystemProxyUnsupportedError";
  }
}

/**
 * 与系统网络设置说话的那一层。**唯一接触面**,而且**整条可注入** ——
 * 门禁里它指向一个假件,真 `networksetup` 在被测进程眼里根本不存在。
 */
export interface NetworkSetupPort {
  /** 枚举网络服务(已禁用的服务 —— 名字前带 `*` 的 —— 不算)。 */
  services(): Promise<string[]>;
  read(service: string, kind: ProxyKind): Promise<ProxySetting>;
  set(service: string, kind: ProxyKind, host: string, port: number): Promise<void>;
  disable(service: string, kind: ProxyKind): Promise<void>;
}

/**
 * 本机该用哪个实现。macOS → `networksetup`;显式给了 `A2_NETWORKSETUP` 也算数
 * (这就是"在别的平台上跑一遍 macOS 代码路径"的注入口,与 `A2_SERVICE_SUPERVISOR` 同一种用途)。
 */
export function createNetworkSetup(
  env: Record<string, string | undefined> = process.env,
  platform: string = process.platform,
): NetworkSetupPort {
  const override = env[NETWORKSETUP_ENV]?.trim();
  if (!override && platform !== "darwin") {
    throw new SystemProxyUnsupportedError(
      `平台 ${platform} 没有 networksetup(系统代理接管 V1 只支持 macOS;` +
        "Linux 上请按你的桌面环境/代理链自行配置,内核不猜)。",
    );
  }
  return new NetworkSetupCommand(override || DEFAULT_NETWORKSETUP);
}

/** `networksetup` 的三组子命令 —— 读、设、开关,一一对应三类代理。 */
const SUBCOMMANDS: Record<ProxyKind, { get: string; set: string; state: string }> = {
  http: { get: "-getwebproxy", set: "-setwebproxy", state: "-setwebproxystate" },
  https: { get: "-getsecurewebproxy", set: "-setsecurewebproxy", state: "-setsecurewebproxystate" },
  socks: {
    get: "-getsocksfirewallproxy",
    set: "-setsocksfirewallproxy",
    state: "-setsocksfirewallproxystate",
  },
};

class NetworkSetupCommand implements NetworkSetupPort {
  constructor(private readonly bin: string) {}

  async services(): Promise<string[]> {
    const out = await this.run(["-listallnetworkservices"]);
    // 首行是说明抬头(An asterisk … denotes that a network service is disabled);
    // `*` 前缀 = 已禁用的服务,设了也不生效,跳过。
    return out
      .split("\n")
      .slice(1)
      .map((line) => line.trim())
      .filter((line) => line.length > 0 && !line.startsWith("*"));
  }

  async read(service: string, kind: ProxyKind): Promise<ProxySetting> {
    const out = await this.run([SUBCOMMANDS[kind].get, service]);
    const fields = new Map<string, string>();
    for (const line of out.split("\n")) {
      const separator = line.indexOf(":");
      if (separator <= 0) continue;
      fields.set(line.slice(0, separator).trim().toLowerCase(), line.slice(separator + 1).trim());
    }
    const enabled = (fields.get("enabled") ?? "").toLowerCase() === "yes";
    if (!enabled) return { ...OFF };
    const port = Number.parseInt(fields.get("port") ?? "", 10);
    return {
      enabled: true,
      host: fields.get("server") ?? "",
      port: Number.isFinite(port) && port > 0 ? port : 0,
    };
  }

  async set(service: string, kind: ProxyKind, host: string, port: number): Promise<void> {
    // 防呆:`-setwebproxy <svc> "" 0` 会被真机 networksetup 拒掉,而它出现在**还原**路径上
    // (快照里某项 enabled=true 但 host/port 是空的)—— 一条拒绝就能把整场还原拖垮。
    // 那种数据只可能来自坏快照,按"关掉"处理是唯一安全的解释。
    if (port <= 0 || host.length === 0) {
      await this.disable(service, kind);
      return;
    }
    await this.run([SUBCOMMANDS[kind].set, service, host, String(port)]);
    // `set*` 通常会顺带置 on,但个别系统版本不会;补一发 state on(幂等)。
    await this.run([SUBCOMMANDS[kind].state, service, "on"]);
  }

  async disable(service: string, kind: ProxyKind): Promise<void> {
    await this.run([SUBCOMMANDS[kind].state, service, "off"]);
  }

  private async run(args: string[]): Promise<string> {
    const argv = [this.bin, ...args];
    let proc;
    try {
      proc = Bun.spawn({ cmd: argv, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
    } catch (error) {
      throw new SystemProxyError("执行 networksetup 失败。", `无法执行 ${argv.join(" ")}:${String(error)}`);
    }
    const timer = setTimeout(() => proc.kill(), NETWORKSETUP_TIMEOUT_MS);
    try {
      const [stdout, stderr] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
      ]);
      await proc.exited;
      if ((proc.exitCode ?? -1) !== 0) {
        throw new SystemProxyError(
          "networksetup 命令失败。",
          `${argv.join(" ")} 退出码=${proc.exitCode}:${`${stdout}${stderr}`.trim()}`,
        );
      }
      return stdout;
    } finally {
      clearTimeout(timer);
    }
  }
}

// MARK: - 快照

/** 接管快照 —— **还原的全部依据**。它在 = 现在是我接管着。 */
export interface TakeoverSnapshot {
  takenOverAt: string;
  host: string;
  port: number;
  services: NetworkServiceProxy[];
}

export function snapshotPath(paths: KernelPaths): string {
  return path.join(paths.home, "system-proxy.json");
}

export async function readSnapshot(paths: KernelPaths): Promise<TakeoverSnapshot | undefined> {
  const text = await Bun.file(snapshotPath(paths))
    .text()
    .catch(() => undefined);
  if (text === undefined) return undefined;
  try {
    const parsed = JSON.parse(text) as Partial<TakeoverSnapshot>;
    if (!Array.isArray(parsed.services)) return undefined;
    return {
      takenOverAt: typeof parsed.takenOverAt === "string" ? parsed.takenOverAt : "",
      host: typeof parsed.host === "string" ? parsed.host : "",
      port: typeof parsed.port === "number" ? parsed.port : 0,
      services: parsed.services as NetworkServiceProxy[],
    };
  } catch {
    return undefined;
  }
}

async function writeSnapshot(paths: KernelPaths, snapshot: TakeoverSnapshot): Promise<void> {
  try {
    await Bun.write(snapshotPath(paths), `${JSON.stringify(snapshot, null, 2)}\n`);
  } catch (error) {
    throw new SystemProxyError(
      "接管快照写不下去,已拒绝接管系统代理(fail-closed)。",
      `写 ${snapshotPath(paths)} 失败:${String(error)}。` +
        "先能还原,才谈得上接管 —— 快照落不了盘就绝不动系统设置。",
    );
  }
}

async function clearSnapshot(paths: KernelPaths): Promise<void> {
  await rm(snapshotPath(paths), { force: true });
}

// MARK: - 读实况

/** 逐服务 × 逐类型读回当前实况。 */
export async function captureLive(net: NetworkSetupPort): Promise<NetworkServiceProxy[]> {
  const services = await net.services();
  const captured: NetworkServiceProxy[] = [];
  for (const service of services) {
    captured.push({
      service,
      http: await net.read(service, "http"),
      https: await net.read(service, "https"),
      socks: await net.read(service, "socks"),
    });
  }
  return captured;
}

function settingOf(state: NetworkServiceProxy, kind: ProxyKind): ProxySetting {
  return state[kind];
}

/** 把快照原样写回系统:开的还原成原来的 host:port(**含原本就有的第三方代理**),关的还原成关。 */
export async function restoreSnapshot(
  net: NetworkSetupPort,
  services: NetworkServiceProxy[],
): Promise<void> {
  for (const state of services) {
    for (const kind of KINDS) {
      const setting = settingOf(state, kind);
      if (setting.enabled) await net.set(state.service, kind, setting.host, setting.port);
      else await net.disable(state.service, kind);
    }
  }
}

// MARK: - 接管 / 还原

export interface TakeoverResult {
  snapshot: TakeoverSnapshot;
  /** 接管后的实况(报文里给出,免得调用方再读一次)。 */
  live: NetworkServiceProxy[];
}

/**
 * 接管:把每个网络服务的三类代理都指向 `host:port`。
 *
 * 顺序即安全语义:**读实况 → 合并出最终还原快照 → 落盘 → 才动系统**。
 * 中途任何一步写失败,都用本次调用开始时的实况回滚,并把快照标记恢复成调用前的样子。
 */
export async function takeover(
  paths: KernelPaths,
  net: NetworkSetupPort,
  host: string,
  port: number,
  now: Date = new Date(),
): Promise<TakeoverResult> {
  const previous = await readSnapshot(paths);
  const live = await captureLive(net);

  // 已在快照里的服务**保持首次记录的原状**(绝不用"已接管态"覆盖它);
  // 接管之后新出现的服务并入,各自记各自此刻的原状。
  const merged: NetworkServiceProxy[] = previous ? [...previous.services] : [];
  const known = new Set(merged.map((entry) => entry.service));
  for (const entry of live) {
    if (!known.has(entry.service)) merged.push(entry);
  }

  const snapshot: TakeoverSnapshot = {
    takenOverAt: previous?.takenOverAt || now.toISOString(),
    host,
    port,
    services: merged,
  };
  await writeSnapshot(paths, snapshot);

  try {
    for (const entry of live) {
      for (const kind of KINDS) await net.set(entry.service, kind, host, port);
    }
  } catch (error) {
    // 只撤销**本次调用**:回到调用开始时的实况(既有接管因此仍然保持启用)。
    await restoreSnapshot(net, live).catch(() => {});
    if (previous) await writeSnapshot(paths, previous).catch(() => {});
    else await clearSnapshot(paths);
    throw error instanceof SystemProxyError
      ? new SystemProxyError(
          "接管系统代理写到一半失败,已回滚到本次调用前的状态。",
          error.detail,
        )
      : error;
  }

  return { snapshot, live: await captureLive(net) };
}

export interface RestoreResult {
  /** 本次是不是真的还原了(没有快照时为 false —— 那是合法的 no-op,不是失败)。 */
  restored: boolean;
  live: NetworkServiceProxy[];
}

/**
 * 还原:按快照精确复原,然后**清掉快照**(接管关系到此为止)。
 * 没有快照时是干净的 no-op:`restored: false`,退出码 0 —— 「本来就没接管」是合法答案。
 *
 * 还原写失败时**保留快照**:下次再敲一遍 `a2 proxy off` 还能重试,
 * 而不是把唯一的还原依据也丢掉。
 */
export async function restore(paths: KernelPaths, net: NetworkSetupPort): Promise<RestoreResult> {
  const snapshot = await readSnapshot(paths);
  if (!snapshot) return { restored: false, live: await captureLive(net) };
  await restoreSnapshot(net, snapshot.services);
  await clearSnapshot(paths);
  return { restored: true, live: await captureLive(net) };
}
