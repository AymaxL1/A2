// URL 分流的配置:`<A2_HOME>/url-router.json` 的读取与缺省合并(spec §8 字段表是权威)。
//
// 语义照母本 `ClaudeURLRouter.swift::EffectiveConfig.load()`,三条原样继承:
//   1. **无文件 = 全缺省**,不是错 —— 一台没配过 url-router 的机器照样分流:缺省域名表本身就是产品意图。
//   2. **合并逐字段 `??`**:文件里缺的键、以及显式写成 `null` 的键,都退回缺省。于是"只想换兜底浏览器"
//      的人写一行就够,不必把整张表抄一遍。
//   3. **文件用不了 = 整份退回缺省**,不留"一半你的一半我的" —— 那种中间态没人说得清:
//      用户以为自己设过的某一项到底生效没有,只能靠猜。哪一项不合契约由 `problem` 指名道姓,
//      `url-router.status` 负责把它说给人听(spec §8:V1 的配置管理就是直接编辑文件 + status 报错)。
//
// 两处**有意偏离母本**,都是 spec §8 定的:
//   * `defaultBrowserBundleID` 改名 `fallbackBrowserBundleID`(CONTEXT.md:「默认浏览器」这个词留给
//     系统概念,兜底浏览器是另一回事)。这一项**必须是显式 bundle id、永不查系统默认** ——
//     A2 Panel 自己就是系统默认 handler 时,查系统默认等于递归打开自己。
//   * 不收 `logPath`:日志并入内核日志纪律,url-router 不另开一条日志通道。
//
// **`roxyAPIKey` 是敏感值**(spec §8:只留本机文件,不入 git、不进快照推送、不进日志)。
// 落到本模块的具体纪律:出错时报的是「哪个字段不合契约」,而**不是**解析器那句错误消息 ——
// JSON 解析器的报错会引用出错处的原文片段,而这份文件里躺着那把钥匙。要把配置说给别人听,
// 走 `redactUrlRouterConfig`。

import path from "node:path";
import { z } from "zod";
import type { KernelPaths } from "../runtime/paths.ts";

/** 配置文件名(禁止各处各拼)。 */
export const URL_ROUTER_CONFIG_NAME = "url-router.json";

/** 配置落点:`<A2_HOME>/url-router.json`(A2_HOME 覆写照旧,见 `runtime/paths.ts`)。 */
export function urlRouterConfigPath(paths: KernelPaths): string {
  return path.join(paths.home, URL_ROUTER_CONFIG_NAME);
}

/**
 * **生效配置** —— 缺省已经合并进来,每一项都有值,使用侧不必再 `??` 一遍。
 * 字段与 spec §8 的表逐字对应(顺序也照那张表,方便对读)。
 */
export interface UrlRouterConfig {
  /** 未命中分流域名时把 URL 交给谁。必须是显式 bundle id。 */
  fallbackBrowserBundleID: string;
  /** 进 Roxy 的域名表,含子域名后缀匹配(判据见 `decide.ts::isRoutedHost`)。 */
  routedDomains: string[];
  /** Roxy 的 .app 路径(CDP 与 API 都走不通时,兜底靠它拉起)。 */
  roxyApplicationPath: string;
  /** 在 `ps` 全表里认出 Roxy 主进程的命令行子串。 */
  roxyProcessMatch: string;
  /** 命令行里 profile 目录的标记,与 `roxyProfileID` 拼起来认这一个 profile。 */
  roxyProfilePathMarker: string;
  /** 要用的 Roxy profile id(空 = 没指定)。 */
  roxyProfileID: string;
  /** Roxy 本地 API 的根地址(null = 没配)。 */
  roxyAPIHost: string | null;
  /** 打开 profile 的 API 路径。 */
  roxyAPIOpenPath: string;
  /** 送 API key 的请求头名。 */
  roxyAPITokenHeader: string;
  /** Roxy API key。**敏感**:不进日志、不进快照、不进错误文本。 */
  roxyAPIKey: string | null;
  /** Roxy 工作区 id(null = 没配)。 */
  roxyWorkspaceID: number | null;
  /** 让 Roxy 强制打开 profile。 */
  roxyForceOpen: boolean;
  /** 调 Roxy API 的超时(秒)。 */
  roxyAPITimeoutSeconds: number;
  /** API 开完 profile 后,等它把 CDP 端口露出来的重试次数。 */
  roxyStartupAttempts: number;
  /** 上面每次重试之间的间隔(秒)。 */
  roxyStartupDelaySeconds: number;
}

/**
 * 缺省配置(spec §8 表里的「缺省」列,**唯一出处**)。
 *
 * 每次调用**新造一份**:`routedDomains` 是数组,共享一份常量意味着任何一处不小心 push 一下,
 * 全进程的缺省域名表就变了。
 *
 * Roxy 三项的值与母本不同(母本写的是 RoxyChrome):02 研究票在本机实测的是 RoxyBrowser,
 * 兼容只是纯配置值替换,匹配逻辑的形状一个字没动。
 */
export function defaultUrlRouterConfig(): UrlRouterConfig {
  return {
    fallbackBrowserBundleID: "com.apple.Safari",
    routedDomains: ["claude.ai", "claude.com", "anthropic.com"],
    roxyApplicationPath: "/Applications/RoxyBrowser.app",
    roxyProcessMatch: "/RoxyBrowser.app/Contents/MacOS/RoxyBrowser",
    roxyProfilePathMarker: "/browser-cache/",
    roxyProfileID: "",
    roxyAPIHost: null,
    roxyAPIOpenPath: "/browser/open",
    roxyAPITokenHeader: "token",
    roxyAPIKey: null,
    roxyWorkspaceID: null,
    roxyForceOpen: false,
    roxyAPITimeoutSeconds: 5.0,
    roxyStartupAttempts: 10,
    roxyStartupDelaySeconds: 0.2,
  };
}

/**
 * 文件里那份(用户手写的)。每一项都可缺、可写 `null` —— 两者一律退回缺省,这就是母本 `??` 的语义。
 *
 * **校验只到类型**,与母本的 `JSONDecoder` 同一口径。值域的兜底(次数至少 1、间隔至少 50ms)
 * 母本是在**用的地方** clamp 的,这里照办。收得更紧的代价不对等:一个写歪的 `roxyStartupAttempts: 0`
 * 会把整份文件打回缺省,连带用户设过的兜底浏览器一起丢掉。
 *
 * 不认识的键**忽略**(母本的 Decodable 也忽略):配置文件里留注释键、留将来的字段,不该是错。
 */
const FileConfigSchema = z.object({
  fallbackBrowserBundleID: z.string().nullish(),
  routedDomains: z.array(z.string()).nullish(),
  roxyApplicationPath: z.string().nullish(),
  roxyProcessMatch: z.string().nullish(),
  roxyProfilePathMarker: z.string().nullish(),
  roxyProfileID: z.string().nullish(),
  roxyAPIHost: z.string().nullish(),
  roxyAPIOpenPath: z.string().nullish(),
  roxyAPITokenHeader: z.string().nullish(),
  roxyAPIKey: z.string().nullish(),
  roxyWorkspaceID: z.number().int().nullish(),
  roxyForceOpen: z.boolean().nullish(),
  roxyAPITimeoutSeconds: z.number().nullish(),
  roxyStartupAttempts: z.number().int().nullish(),
  roxyStartupDelaySeconds: z.number().nullish(),
});
type FileConfig = z.infer<typeof FileConfigSchema>;

/** 这份生效配置是怎么来的 —— `url-router.status` 的「配置健康」就报它。 */
export type UrlRouterConfigSource =
  /** 没有配置文件:全缺省,合法状态,不是错。 */
  | "defaults"
  /** 文件读到了、合契约:缺省与文件已逐字段合并。 */
  | "file"
  /** 文件在但用不了(读不出来 / 不是合法 JSON / 字段不合契约):已整份退回缺省,详情见 `problem`。 */
  | "unusable";

export interface UrlRouterConfigLoad {
  /** 任何情况下都是一份完整的生效配置 —— 调用侧永远不必处理"没有配置"。 */
  config: UrlRouterConfig;
  source: UrlRouterConfigSource;
  /**
   * `source === "unusable"` 时说清是什么毛病。
   * **只说毛病与字段名,绝不带文件原文片段** —— 这份文件里有 `roxyAPIKey`。
   */
  problem?: string;
}

/** 读配置。三条出口(全缺省 / 合并 / 用不了但仍给全缺省)都在 `UrlRouterConfigSource` 里写着。 */
export async function loadUrlRouterConfig(paths: KernelPaths): Promise<UrlRouterConfigLoad> {
  const file = urlRouterConfigPath(paths);
  const text = await Bun.file(file).text().catch(() => undefined);
  if (text === undefined) {
    // 读不出来分两种,处置一样(全缺省)但**说法不一样**:没有文件是常态,
    // 文件在却读不出来是故障(多半是权限),得让 status 说得出话来。
    const exists = await Bun.file(file).exists().catch(() => false);
    return exists
      ? unusable("配置文件在,但读不出来(权限?)。")
      : { config: defaultUrlRouterConfig(), source: "defaults" };
  }

  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    // 有意丢掉解析器那句话:它会引用出错处的原文,而原文里可能就是那把钥匙。
    return unusable("配置文件不是合法 JSON。");
  }
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    return unusable("配置文件的顶层不是一个 JSON 对象。");
  }

  const parsed = FileConfigSchema.safeParse(raw);
  if (!parsed.success) {
    return unusable(`配置文件里这些字段不合契约:${offendingFields(parsed.error).join("、")}。`);
  }
  return { config: mergeWithDefaults(parsed.data), source: "file" };
}

function unusable(problem: string): UrlRouterConfigLoad {
  return { config: defaultUrlRouterConfig(), source: "unusable", problem };
}

/** 出错字段名(去重、保序)。只取路径,不取 zod 的消息 —— 消息在某些分支上会回显收到的值。 */
function offendingFields(error: z.ZodError): string[] {
  return [...new Set(error.issues.map((issue) => issue.path.join(".") || "(顶层)"))];
}

/** 逐字段 `??`:缺的键与显式 `null` 都退回缺省;`false` / `0` / `""` / `[]` 是用户写的值,原样留着。 */
function mergeWithDefaults(file: FileConfig): UrlRouterConfig {
  const defaults = defaultUrlRouterConfig();
  return {
    fallbackBrowserBundleID: file.fallbackBrowserBundleID ?? defaults.fallbackBrowserBundleID,
    routedDomains: file.routedDomains ?? defaults.routedDomains,
    roxyApplicationPath: file.roxyApplicationPath ?? defaults.roxyApplicationPath,
    roxyProcessMatch: file.roxyProcessMatch ?? defaults.roxyProcessMatch,
    roxyProfilePathMarker: file.roxyProfilePathMarker ?? defaults.roxyProfilePathMarker,
    roxyProfileID: file.roxyProfileID ?? defaults.roxyProfileID,
    roxyAPIHost: file.roxyAPIHost ?? defaults.roxyAPIHost,
    roxyAPIOpenPath: file.roxyAPIOpenPath ?? defaults.roxyAPIOpenPath,
    roxyAPITokenHeader: file.roxyAPITokenHeader ?? defaults.roxyAPITokenHeader,
    roxyAPIKey: file.roxyAPIKey ?? defaults.roxyAPIKey,
    roxyWorkspaceID: file.roxyWorkspaceID ?? defaults.roxyWorkspaceID,
    roxyForceOpen: file.roxyForceOpen ?? defaults.roxyForceOpen,
    roxyAPITimeoutSeconds: file.roxyAPITimeoutSeconds ?? defaults.roxyAPITimeoutSeconds,
    roxyStartupAttempts: file.roxyStartupAttempts ?? defaults.roxyStartupAttempts,
    roxyStartupDelaySeconds: file.roxyStartupDelaySeconds ?? defaults.roxyStartupDelaySeconds,
  };
}

/**
 * 这份配置够不够走 Roxy API 那一级(host + key + workspaceID **三者齐备**,母本 `hasRoxyAPIConfig`)。
 *
 * 判据是「齐备」而不是「能不能连上」:能不能连上要发请求才知道,而决策必须是纯函数。
 * 配置不齐就直接降到 launcher —— 拿着半份配置去调 API 只会白等一个超时。
 * 空白串按没配算(配置文件里留一行 `"roxyAPIKey": " "` 不该被当成设过)。
 */
export function hasRoxyAPIConfig(config: UrlRouterConfig): boolean {
  return (
    (config.roxyAPIHost ?? "").trim().length > 0 &&
    (config.roxyAPIKey ?? "").trim().length > 0 &&
    config.roxyWorkspaceID !== null
  );
}

/** 能给人看的那份配置视图:`roxyAPIKey` 只剩「设过没设过」这一个事实。 */
export interface RedactedUrlRouterConfig extends Omit<UrlRouterConfig, "roxyAPIKey"> {
  /** 设过 key 没有(值永不外传)。 */
  roxyAPIKeyConfigured: boolean;
}

/**
 * 把配置脱敏成可以进报文/日志/快照的形状。
 *
 * 存在的理由是让那条纪律**有唯一落点**:凡是要把配置说给别人听的地方(status 报文、诊断日志、
 * 下发给壳的快照)都过这里,而不是各处各自记得"别带 roxyAPIKey"——那种记性迟早有一处会失手。
 */
export function redactUrlRouterConfig(config: UrlRouterConfig): RedactedUrlRouterConfig {
  const { roxyAPIKey, ...rest } = config;
  return { ...rest, roxyAPIKeyConfigured: (roxyAPIKey ?? "").trim().length > 0 };
}
