// a2 自管 mihomo 的落点、扫描面与配置渲染。
//
// **扫描面全部可注入**,这是本票的施工红线在代码里的落点:检测逻辑绝不"扫整台机器",
// 它只看被明确交给它的那几个目录与那几份配置文件。默认值也只指向标准位置,且每一项都能被环境变量整条替换。
//
// 另一条同样重要的性质:**只连回环**。external-controller 的地址来自配置文件(别人写的),
// 所以必须当不可信输入看 —— 解析出来的主机不是回环就不探测,如实报告并跳过。内核从不做端口扫描。

import { homedir } from "node:os";
import path from "node:path";
import type { KernelPaths } from "../runtime/paths.ts";

/** a2 自管那一份 mihomo 的全部落点。 */
export interface MihomoLayout {
  /** `<home>/mihomo` —— 同时就是 mihomo 的 `-d`(它的缓存与 geo 库落这儿)。 */
  dataDir: string;
  /** `<home>/mihomo/bin` */
  binDir: string;
  /** `<home>/mihomo/bin/mihomo` —— 下载的真文件,或指向既有二进制的符号链接。 */
  binaryPath: string;
  /** `<home>/mihomo/config.yaml` —— a2 自管配置(07 票的配置面就长在它上面)。 */
  configPath: string;
  /** `<home>/mihomo/settings.json` —— a2 自管配置里那几个**可调项**的落点(07 票)。 */
  settingsPath: string;
  /** `<home>/mihomo/subscriptions` —— 订阅清单与物化配置的落点(07 票)。 */
  subscriptionsDir: string;
  /** `<home>/mihomo/subscriptions/catalog.json` */
  catalogPath: string;
  /** `<home>/mihomo/subscriptions/configs` —— 每条订阅拉到的原始字节(`<id>.conf`)。 */
  subscriptionConfigDir: string;
  /** a2 自管实例的 external-controller(恒回环)。 */
  controller: string;
}

/**
 * a2 自管实例的默认端口。**有意避开 mihomo 自己的默认值**(9090 / 7890):
 * 那两个端口正是用户自装实例最可能占着的,选开一点就少一类"两份 mihomo 抢端口"的事故。
 *
 * 混合入站端口从 07 票起是**可调项**(落 `<home>/mihomo/settings.json`,经 `proxy.config.set` 改),
 * 这里的常量只是"还没设过时用哪个"。控制端口仍是常量:改它等于换一条内核自己的控制通道,
 * 那是诊断而非日常配置,所以只给环境变量、不进配置文件。
 */
export const A2_MIHOMO_CONTROLLER_PORT = 9097;
export const A2_MIHOMO_MIXED_PORT = 7897;

/** 覆写环境变量(集中登记一次;`a2 mihomo --help` 里逐条列出)。 */
export const MihomoEnv = {
  /** 覆写「去哪些目录找 mihomo 二进制」(冒号分隔)。仅测试与诊断用。 */
  binDirs: "A2_MIHOMO_BIN_DIRS",
  /** 覆写「读哪些配置文件找 external-controller」(冒号分隔)。仅测试与诊断用。 */
  configFiles: "A2_MIHOMO_CONFIG_FILES",
  /** 直接指定别人那个 external-controller(`host:port`),跳过配置解析。**只用于读**(收编档已废除)。 */
  controller: "A2_MIHOMO_CONTROLLER",
  /** 配套 `A2_MIHOMO_CONTROLLER` 的 secret。 */
  secret: "A2_MIHOMO_SECRET",
  /** 覆写 a2 自管实例的 external-controller 端口。 */
  controllerPort: "A2_MIHOMO_CONTROLLER_PORT",
  /**
   * 覆写混合入站端口的**默认值**(还没设过 settings.json 时用它)。
   * 有意只改默认值而不覆盖已存的设置 —— 否则 `proxy.config.set mixedPort` 在有这个变量的环境里会静默失效。
   */
  mixedPort: "A2_MIHOMO_MIXED_PORT",
  /** 覆写发布渠道根地址(镜像源;测试用本地夹具)。 */
  releaseBase: "A2_MIHOMO_RELEASE_BASE",
  /** 覆写下载物的期望 SHA-256。仅测试与诊断用(生产走 `pin.ts` 的摘要表)。 */
  expectSha256: "A2_MIHOMO_EXPECT_SHA256",
  /**
   * 覆写本机资产键(`<os>-<cpu>`,如 `linux-amd64`)。仅测试与诊断用。
   * 与 `A2_SERVICE_SUPERVISOR` 同一种用途:在 mac 上把**另一个平台**的代码路径真的跑一遍 ——
   * 摘要表目前只有 `darwin-arm64` 一项,「本平台没登记摘要就 fail-closed」这条在本机上
   * 只能靠它才验得到(而那正是 Linux 上的真实路径)。
   */
  assetKey: "A2_MIHOMO_ASSET_KEY",
} as const;

export function mihomoLayout(
  paths: KernelPaths,
  env: Record<string, string | undefined> = process.env,
): MihomoLayout {
  const dataDir = path.join(paths.home, "mihomo");
  const binDir = path.join(dataDir, "bin");
  const subscriptionsDir = path.join(dataDir, "subscriptions");
  const port = Number.parseInt(env[MihomoEnv.controllerPort]?.trim() ?? "", 10);
  return {
    dataDir,
    binDir,
    binaryPath: path.join(binDir, "mihomo"),
    configPath: path.join(dataDir, "config.yaml"),
    settingsPath: path.join(dataDir, "settings.json"),
    subscriptionsDir,
    catalogPath: path.join(subscriptionsDir, "catalog.json"),
    subscriptionConfigDir: path.join(subscriptionsDir, "configs"),
    controller: `127.0.0.1:${Number.isFinite(port) && port > 0 ? port : A2_MIHOMO_CONTROLLER_PORT}`,
  };
}

/** 检测的扫描面 —— 每一项都是"被交给我的"列表,没有任何一处是内核自己去遍历系统得来的。 */
export interface MihomoScanInputs {
  /** 找**别人的** mihomo 二进制的目录(有序,第一个命中即用)。 */
  binaryDirs: string[];
  /** 找**别人的** external-controller 的配置文件(有序,第一份解析出地址的即用)。 */
  configFiles: string[];
  /** 显式指定的 controller(有则完全跳过配置解析)。 */
  explicit?: { controller: string; secret?: string };
}

function userHome(env: Record<string, string | undefined>): string {
  const home = env.HOME?.trim();
  return home ? path.resolve(home) : homedir();
}

/** 默认的二进制搜索目录:PATH 上的每一段 + 两个包管理器的标准前缀。去重、保序。 */
export function defaultBinaryDirs(env: Record<string, string | undefined> = process.env): string[] {
  const fromPath = (env.PATH ?? "").split(":").filter((entry) => entry.length > 0);
  return [...new Set([...fromPath, "/usr/local/bin", "/opt/homebrew/bin"])];
}

/**
 * 默认的配置候选:**只有 mihomo 自己的标准位置**(`$XDG_CONFIG_HOME/mihomo/config.yaml`,
 * 缺省 `~/.config/mihomo/config.yaml`,见 mihomo `constant/path.go`)。
 * a2 自管的那份不在这个列表里 —— 它走 `MihomoLayout.configPath`,两边不能混为一谈。
 */
export function defaultConfigFiles(env: Record<string, string | undefined> = process.env): string[] {
  const xdg = env.XDG_CONFIG_HOME?.trim();
  const base = xdg ? path.resolve(xdg) : path.join(userHome(env), ".config");
  return [path.join(base, "mihomo", "config.yaml")];
}

export function resolveScanInputs(
  env: Record<string, string | undefined> = process.env,
): MihomoScanInputs {
  const binDirs = env[MihomoEnv.binDirs]?.trim();
  const configFiles = env[MihomoEnv.configFiles]?.trim();
  const explicitController = env[MihomoEnv.controller]?.trim();
  const explicitSecret = env[MihomoEnv.secret]?.trim();
  return {
    binaryDirs: binDirs ? splitList(binDirs) : defaultBinaryDirs(env),
    configFiles: configFiles ? splitList(configFiles) : defaultConfigFiles(env),
    ...(explicitController
      ? {
          explicit: {
            controller: explicitController,
            ...(explicitSecret ? { secret: explicitSecret } : {}),
          },
        }
      : {}),
  };
}

function splitList(value: string): string[] {
  return value.split(":").map((entry) => entry.trim()).filter((entry) => entry.length > 0);
}

/**
 * 从一份 mihomo 配置里读 `external-controller` 与 `secret`。
 *
 * **有意只做行级解析、不引 YAML 解析器**:内核对别人的配置只需要这两行,而把一份任意来源的 YAML
 * 完整解析进内存是平白多出来的攻击面与依赖。读不出来就当"没有",不猜、不报错。
 */
export function readControllerFromConfig(
  text: string,
): { controller: string; secret?: string } | undefined {
  const scalar = (key: string): string | undefined => {
    const match = new RegExp(`^[ \\t]*${key}[ \\t]*:[ \\t]*(.+?)[ \\t]*$`, "m").exec(text);
    if (!match) return undefined;
    const raw = match[1]!.replace(/\s+#.*$/, "").trim();
    const unquoted = raw.replace(/^["']/, "").replace(/["']$/, "").trim();
    return unquoted.length > 0 ? unquoted : undefined;
  };
  const controller = scalar("external-controller");
  if (!controller) return undefined;
  const secret = scalar("secret");
  return secret ? { controller, secret } : { controller };
}

/**
 * 从**一份配置文件**里现读 secret —— 读不到(文件不在、没那一行)就当没有,不猜、不报错。
 *
 * **每次现读、绝不缓存**:那份配置的主人随时可能改 secret(别人那份尤其 —— 那压根是别人的文件),
 * 缓存一把过期的钥匙只会让探测在某个时刻毫无征兆地变成 401。
 * 三处调用点(检测自管实例、检测别人的实例、就位后等控制端点应答)共用这一条,免得各写各的 catch。
 */
export async function readSecretOf(configFile: string): Promise<string | undefined> {
  const text = await Bun.file(configFile).text().catch(() => undefined);
  return text === undefined ? undefined : readControllerFromConfig(text)?.secret;
}

/**
 * 把配置里写的监听地址归一成"我要去连的那个地址"。
 * 返回 undefined = **不该连**:主机不是回环(内核不对局域网/公网端点发一个字节)。
 */
export function loopbackTarget(address: string): string | undefined {
  const trimmed = address.trim();
  const lastColon = trimmed.lastIndexOf(":");
  if (lastColon < 0) return undefined;
  const host = trimmed.slice(0, lastColon).replace(/^\[|\]$/g, "").trim();
  const port = trimmed.slice(lastColon + 1).trim();
  if (!/^\d+$/.test(port)) return undefined;
  // 空 host(`:9090`)与 0.0.0.0/:: 都是"监听全部网卡",本机连它走回环即可。
  const loopback = ["", "0.0.0.0", "::", "127.0.0.1", "localhost", "::1"];
  if (!loopback.includes(host)) return undefined;
  return `127.0.0.1:${port}`;
}

// a2 自管配置的渲染搬去了 `./config.ts`(07 票:它长出了订阅正文与可调项,不再是几行字面量)。
