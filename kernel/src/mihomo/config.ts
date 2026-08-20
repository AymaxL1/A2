// a2 自管 mihomo 配置的**渲染**与那几个可调项。
//
// 两条性质决定了这个文件的形状:
//   1. **确定性** —— 同输入必同字节。幂等("这次什么都没改")就是靠渲染结果与磁盘逐字比较判出来的,
//      所以这里不许出现时间戳、随机数、Map 迭代顺序之类会漂的东西。
//   2. **a2 拥有头部,订阅拥有正文** —— 头部那七行(入站端口/模式/日志/控制端点/secret……)是
//      「内核还控不控得住这台 mihomo」的命根子,必须由 a2 说了算;节点、规则、分组则整份来自订阅。
//
// 为什么不引 YAML 解析器(与 `paths.ts::readControllerFromConfig` 同一条理由):把一份**任意来源**的
// YAML 完整解析进内存是平白多出来的攻击面与依赖,而 a2 需要做的只有一件事 —— 把订阅正文里与头部**重名的
// 顶层键**摘掉,免得同一个键出现两次(yaml.v3 遇到重复键直接报错,那会让整份配置加载失败)。
// 摘除是**行级**的:只认零缩进的 `key:` 行,连同它后面的续行(更深缩进或列表项)一起丢。

import type { ProxySettings } from "../contract/wire.ts";
import { A2_MIHOMO_MIXED_PORT, MihomoEnv, type MihomoLayout } from "./paths.ts";

/** 还没设置过时用的那一份。`mixedPort` 的默认值可被 `A2_MIHOMO_MIXED_PORT` 换掉(仅默认值)。 */
export function defaultSettings(
  env: Record<string, string | undefined> = process.env,
): ProxySettings {
  const port = Number.parseInt(env[MihomoEnv.mixedPort]?.trim() ?? "", 10);
  return {
    mixedPort: Number.isFinite(port) && port > 0 ? port : A2_MIHOMO_MIXED_PORT,
    allowLan: false,
    logLevel: "info",
    mode: "rule",
    // 出厂即 off:mihomo 功能是否启用、以哪种姿势启用,是**人的显式裁定**(ADR 0014),不随检测漂。
    managedMode: "off",
  };
}

/**
 * a2 在自管配置里**独占**的顶层键。订阅正文里出现同名键会被摘掉(并在渲染结果里留一行说明)。
 * 这张表就是「a2 拥有头部」这句话的字面定义 —— 想让某个键归订阅管,把它从这里删掉即可。
 */
export const A2_OWNED_KEYS = [
  "mixed-port",
  "allow-lan",
  "bind-address",
  "mode",
  "log-level",
  "external-controller",
  "secret",
] as const;

export interface ManagedConfigInput {
  layout: MihomoLayout;
  /** 控制端点的钥匙。**一旦生成就留住**(换钥匙会把已连着的客户端踢掉,也让幂等不成立)。 */
  secret: string;
  settings: ProxySettings;
  /** 当前激活的订阅(没有则渲染默认直连骨架)。 */
  subscription?: { id: string; body: string };
}

/** 渲染结果 + 这次摘掉了订阅里的哪些键(进报文,让人知道 a2 覆盖了什么)。 */
export interface RenderedConfig {
  text: string;
  strippedKeys: string[];
}

export function renderManagedConfig(input: ManagedConfigInput): RenderedConfig {
  const { layout, secret, settings, subscription } = input;
  const body = subscription
    ? stripOwnedKeys(subscription.body)
    : { text: DEFAULT_BODY, strippedKeys: [] as string[] };

  const header = [
    "# 由 a2 生成并收敛 —— 手改会在下次收敛时被改回(可调项请用 `a2 proxy config --json`)。",
    subscription
      ? `# 节点/规则正文来自订阅:${subscription.id}`
      : "# 尚未激活任何订阅,正文是默认直连骨架(`a2 proxy subscription list --json` 看有哪些)。",
    ...(body.strippedKeys.length > 0
      ? [`# 订阅正文里这些顶层键由 a2 接管、已摘除:${body.strippedKeys.join("、")}`]
      : []),
    `mixed-port: ${settings.mixedPort}`,
    `allow-lan: ${settings.allowLan}`,
    "bind-address: 127.0.0.1",
    `mode: ${settings.mode}`,
    `log-level: ${settings.logLevel}`,
    `external-controller: ${layout.controller}`,
    `secret: ${secret}`,
  ];

  return {
    text: `${[...header, "", body.text.trimEnd()].join("\n")}\n`,
    strippedKeys: body.strippedKeys,
  };
}

/** 默认正文:全直连。逐字沿用旧仓 `Sources/PluginProxy/Resources/default-config.yaml` 的那三段。 */
export const DEFAULT_BODY = ["proxies: []", "proxy-groups: []", "rules:", "  - MATCH,DIRECT"].join("\n");

/**
 * 顶层键的三种合法写法(YAML 允许键加引号):裸键、单引号、双引号。
 * **三种都必须认**:只认裸键的话,一份写着 `'external-controller': 127.0.0.1:9090` 的订阅就能绕过摘除,
 * 与 a2 头部凑成重复键 —— yaml.v3 遇到重复键直接报错(那条订阅从此永远激活不了),
 * 而换一个容忍重复键的解析器则是后者覆盖前者,内核当场失控。两种结局都不能接受。
 */
const TOP_LEVEL_KEY = /^(?:'([^']+)'|"([^"]+)"|([A-Za-z0-9_.\-]+))[ \t]*:(?:[ \t]|$)/;

/**
 * 摘掉订阅正文里与 a2 头部重名的**顶层**键。
 *
 * 判据只认「零缩进 + 键 + 冒号 + 键名在表里」这一种行;命中之后连同它的续行
 * (更深缩进的行、`- ` 列表项、以及块标量 `|` / `>` 的内容)一起丢,直到下一个零缩进的键为止 ——
 * 这样 `secret: |` 这类块写法也不会留下半截孤儿正文。
 *
 * **不会误伤前缀相同的键**:键名必须整段匹配到冒号,所以 `port:` 与 `mixed-port:` 是两个不同的键,
 * 前者不在表上、原样保留。
 */
export function stripOwnedKeys(body: string): { text: string; strippedKeys: string[] } {
  const owned = new Set<string>(A2_OWNED_KEYS);
  const lines = body.split("\n");
  const kept: string[] = [];
  const strippedKeys: string[] = [];
  let dropping = false;

  for (const line of lines) {
    const topLevel = TOP_LEVEL_KEY.exec(line);
    if (topLevel) {
      // 到了下一个顶层键:上一段的丢弃状态到此为止。
      const key = (topLevel[1] ?? topLevel[2] ?? topLevel[3]) as string;
      if (owned.has(key)) {
        dropping = true;
        // 记的是**归一后的键名**(不带引号)—— 报文里出现 `'secret'` 与 `secret` 两条毫无意义。
        if (!strippedKeys.includes(key)) strippedKeys.push(key);
        continue;
      }
      dropping = false;
      kept.push(line);
      continue;
    }
    // 空行不改变丢弃状态(块标量里常有空行),但在丢弃中也不保留 —— 免得留下一串空行。
    if (dropping) continue;
    kept.push(line);
  }

  return { text: kept.join("\n").trimEnd(), strippedKeys };
}


/**
 * **embedded 收敛的姿势(14 票)**:与 `renderManagedConfig`(订阅世界的全量渲染)不同,
 * 内嵌模式下**正文的主人是用户与他的 agent** —— 他们直接改这份 YAML,a2 只保证自己的七个头部键
 * 是对的。所以这里做的是**外科手术**:逐行找零缩进的 owned 键,值不对就替换那一行;
 * 键缺失就按固定顺序补在文件最前;其余每一个字节(agent 的节点、规则、注释)原样保留。
 *
 * 确定性同 `renderManagedConfig`:同输入必同字节(幂等判据仍是逐字比较)。
 */
export function ensureOwnedHeader(
  current: string,
  input: { layout: MihomoLayout; secret: string; settings: ProxySettings },
): { text: string; changed: boolean } {
  const desired: [key: string, value: string][] = [
    ["mixed-port", String(input.settings.mixedPort)],
    ["allow-lan", String(input.settings.allowLan)],
    ["bind-address", "127.0.0.1"],
    ["mode", input.settings.mode],
    ["log-level", input.settings.logLevel],
    ["external-controller", input.layout.controller],
    ["secret", input.secret],
  ];
  const lines = current.split("\n");
  const seen = new Set<string>();
  let changed = false;

  for (let i = 0; i < lines.length; i += 1) {
    const match = TOP_LEVEL_KEY.exec(lines[i] as string);
    if (!match) continue;
    const key = (match[1] ?? match[2] ?? match[3]) as string;
    const want = desired.find(([k]) => k === key);
    if (!want) continue;
    if (seen.has(key)) {
      // owned 键出现第二次 = 重复键(yaml.v3 直接拒载)。第一处已被钉成 a2 的值,后面的丢弃。
      lines.splice(i, 1);
      i -= 1;
      changed = true;
      continue;
    }
    seen.add(key);
    const wantedLine = `${want[0]}: ${want[1]}`;
    if (lines[i] !== wantedLine) {
      lines[i] = wantedLine;
      changed = true;
    }
  }

  const missing = desired.filter(([key]) => !seen.has(key));
  if (missing.length > 0) {
    changed = true;
    lines.unshift(...missing.map(([key, value]) => `${key}: ${value}`));
  }
  return { text: lines.join("\n"), changed };
}

/**
 * 这份配置里**有没有节点**(guidance 态 F「尚未配置节点」的判据)。
 * 行级启发式,与本文件其余部分同一口径:零缩进 `proxies:` 后面跟着至少一个列表项,
 * 或行内非空数组。判不准宁可判"有"(不该在人配好了之后还唠叨)。
 */
export function configHasProxies(text: string): boolean {
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] as string;
    if (/^proxies[ \t]*:[ \t]*\[/.test(line)) return !/\[[ \t]*\]/.test(line);
    if (/^proxies[ \t]*:[ \t]*$/.test(line)) {
      for (let j = i + 1; j < lines.length; j += 1) {
        const next = lines[j] as string;
        if (/^[ \t]*$/.test(next) || /^[ \t]*#/.test(next)) continue;
        return /^[ \t]+-/.test(next);
      }
      return false;
    }
  }
  return false;
}

/**
 * 找订阅正文里的 **YAML 文档分隔符**(`---` 文档开始 / `...` 文档结束)。
 *
 * 为什么这一条要**拒绝**而不是像重复键那样"摘掉":a2 的渲染物是「a2 头部 + 订阅正文」拼起来的**一份**文档,
 * 正文里只要有一个零缩进的 `---`,拼出来的就成了**多文档流**——而 mihomo 只读第一个文档,
 * 也就是只剩 a2 那几行头部。后果极其阴险:重载会成功,`reloaded: true` 是真的,
 * 而那份订阅的节点与规则**整份静默失效**,用户以为切过去了、实际全走了默认直连。
 *
 * 摘掉分隔符同样不安全(那等于把两份互不相干的文档硬粘成一份,语义由 a2 替用户瞎猜),
 * 所以这里的处置是**结构化拒绝 + 指引**:告诉人第几行、让人自己拆。
 *
 * 返回命中的行号(**从 1 起**,给人读的)与那一行原文;没有则 undefined。
 */
export function findDocumentSeparator(body: string): { line: number; text: string } | undefined {
  const lines = body.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] as string;
    // 只认零缩进:缩进过的 `---` 是别的东西(块标量内容、字符串值),不是文档分隔符。
    if (/^(---|\.\.\.)([ \t].*)?$/.test(line)) {
      return { line: index + 1, text: line };
    }
  }
  return undefined;
}
