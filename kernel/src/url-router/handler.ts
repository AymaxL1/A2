// 系统默认 handler 的**只读**读取(02 票留的那道缝)。
//
// 回答的问题只有一个:此刻 `http` / `https` 的默认 handler 是谁的 bundle id?
// `url-router.status` 拿它报「有没有被 A2 Panel 接管」,`takeover` / `restore` 拿它做**幂等判据**
// (已是目标就直通 `already: true`,一个系统调用都不发)。
//
// 三条纪律:
//   1. **只读、不写**。写默认 handler 只有一条合法路径(壳调 `setDefaultApplication(…)`,系统弹框即确认器,
//      spec §5),内核这边永远只是"看一眼"。
//   2. **读不出来就是 `null`,绝不猜**。LaunchServices 那份库是私有格式、随版本改;`defaults export` 读到的
//      是它的一份投影,一台从没换过默认浏览器的机器上**根本没有对应条目**。那时的真话是
//      「未能判定」,不是「是 Safari」—— 后者会让 `takeover` 的幂等判据凭空多出一个错误答案。
//   3. **悬空诊断(handler 指向一个已经不在的 app)是 05 票补上的**,落点在本文件末尾那一节:
//      同样只读、同样不猜,而且**只报确知的悬空**(见 `InstalledAppLookup` 的头注)。
//
// 解析器是纯函数(`parseLaunchServicesHandler`),因为它是这段里唯一会悄悄错掉的地方:
// `LSHandlers` 的条目里嵌着 `LSHandlerPreferredVersions` 这样的**子字典**,按 `<dict>` 裸切会切歪。

import { PROCESS_TIMEOUT_MS, type UrlRouterPorts } from "./execute.ts";

/** 能被分流、也能被接管的两个 scheme —— 只有这两个(spec §3/§5)。 */
export type HandlerScheme = "http" | "https";
export const HANDLER_SCHEMES: readonly HandlerScheme[] = ["http", "https"];

/** A2 面板的 bundle id(接管的目标;10 票起全仓库就这一个身份)。 */
export const A2_PANEL_BUNDLE_ID = "com.a2.panel";

/** `defaults export` 的域:LaunchServices 记默认 handler 的那一份。 */
export const LAUNCH_SERVICES_DOMAIN =
  "com.apple.LaunchServices/com.apple.launchservices.secure";

/** 读一个 scheme 当前的默认 handler。**永不抛**:问不出来就是 `null`。 */
export interface DefaultHandlerReader {
  read(scheme: HandlerScheme): Promise<string | null>;
}

/**
 * 生产实现。非 macOS 一律 `null`(那台机器上没有 LaunchServices,这不是故障,是"没有这回事")。
 *
 * 命令是 `defaults export <域> -`(导到 stdout 的 XML plist),纯读。
 */
export function createDefaultHandlerReader(
  ports: UrlRouterPorts,
  platform: string = process.platform,
): DefaultHandlerReader {
  return {
    async read(scheme) {
      if (platform !== "darwin") return null;
      const result = await ports.run(
        [ports.bin.defaults, "export", LAUNCH_SERVICES_DOMAIN, "-"],
        PROCESS_TIMEOUT_MS,
      );
      if (result.exitCode !== 0) return null;
      return parseLaunchServicesHandler(result.stdout, scheme);
    },
  };
}

/**
 * 从 `defaults export` 的 XML plist 里取某个 scheme 的 `LSHandlerRoleAll`。
 *
 * 取**最后一条**匹配项:LaunchServices 会把新的选择追加进 `LSHandlers`,旧条目未必清掉,
 * 后写的那条才是现在生效的。没有匹配项就是 `null`(见文件抬头第 2 条)。
 */
export function parseLaunchServicesHandler(
  plistXml: string,
  scheme: HandlerScheme,
): string | null {
  let answer: string | null = null;
  for (const entry of handlerEntries(plistXml)) {
    if (stringValue(entry, "LSHandlerURLScheme")?.toLowerCase() !== scheme) continue;
    const role = stringValue(entry, "LSHandlerRoleAll");
    if (role && role.trim().length > 0) answer = role.trim();
  }
  return answer;
}

/** `LSHandlers` 数组里的每一条(**顶层字典**,内部嵌套的子字典不算一条)。 */
function handlerEntries(plistXml: string): string[] {
  const array = arrayAfterKey(plistXml, "LSHandlers");
  if (array === undefined) return [];
  return topLevelBlocks(array, "dict");
}

/** `<key>NAME</key>` 之后那个 `<array>` 的内容(按 `<array>` 配对计深度,嵌套数组不会切歪)。 */
function arrayAfterKey(xml: string, key: string): string | undefined {
  const keyIndex = xml.indexOf(`<key>${key}</key>`);
  if (keyIndex < 0) return undefined;
  const open = xml.indexOf("<array>", keyIndex);
  if (open < 0) return undefined;
  return matchingClose(xml.slice(open + "<array>".length), "array");
}

/** 从一段"已经在标签内部"的文本里,截到与之配对的收标签为止。 */
function matchingClose(body: string, tag: string): string | undefined {
  const pattern = new RegExp(`<${tag}>|</${tag}>`, "g");
  let depth = 0;
  for (let match = pattern.exec(body); match !== null; match = pattern.exec(body)) {
    if (match[0] === `<${tag}>`) depth += 1;
    else if (depth === 0) return body.slice(0, match.index);
    else depth -= 1;
  }
  return undefined;
}

/** 一段文本里所有**深度为 0** 的 `<tag>…</tag>` 块(内容不含首尾标签)。 */
function topLevelBlocks(xml: string, tag: string): string[] {
  const pattern = new RegExp(`<${tag}>|</${tag}>|<${tag}/>`, "g");
  const blocks: string[] = [];
  let depth = 0;
  let start = -1;
  for (let match = pattern.exec(xml); match !== null; match = pattern.exec(xml)) {
    if (match[0] === `<${tag}/>`) continue; // 空标签,不含任何键
    if (match[0] === `<${tag}>`) {
      if (depth === 0) start = match.index + match[0].length;
      depth += 1;
      continue;
    }
    depth -= 1;
    if (depth === 0 && start >= 0) {
      blocks.push(xml.slice(start, match.index));
      start = -1;
    }
    if (depth < 0) depth = 0; // 收标签比开标签多 —— 文本不成对,按"到此为止"处理,不抛
  }
  return blocks;
}

/**
 * 字典里 `<key>NAME</key><string>值</string>` 的那个值 —— **只看这一层**。
 *
 * 嵌套块先剥掉,不是洁癖:真实的 `LSHandlers` 条目里躺着
 * `<key>LSHandlerPreferredVersions</key><dict><key>LSHandlerRoleAll</key><string>-</string></dict>`,
 * 而它排在条目自己的 `LSHandlerRoleAll` **前面**。不剥就会取到那个 `-`,
 * 于是每台正常的 Mac 都会被报成「默认浏览器是 `-`」—— 一条不会报错、只会一直答错的路。
 */
function stringValue(dict: string, key: string): string | undefined {
  const pattern = new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`);
  return pattern.exec(withoutNested(dict))?.[1];
}

/** 去掉所有嵌套的 `<dict>…</dict>` / `<array>…</array>`,只留这一层的键值。 */
function withoutNested(xml: string): string {
  const pattern = /<(?:dict|array)>|<\/(?:dict|array)>/g;
  let out = "";
  let depth = 0;
  let resume = 0;
  for (let match = pattern.exec(xml); match !== null; match = pattern.exec(xml)) {
    if (match[0].startsWith("</")) {
      depth -= 1;
      if (depth <= 0) {
        depth = 0;
        resume = match.index + match[0].length;
      }
      continue;
    }
    if (depth === 0) out += xml.slice(resume, match.index);
    depth += 1;
  }
  if (depth === 0) out += xml.slice(resume);
  return out;
}

/** 两个 scheme 的现状 + 「是不是已经是目标了」这一个判断。 */
export interface HandlerSnapshot {
  http: string | null;
  https: string | null;
  /** 两个 scheme **都**是目标才算是;有一个读不出来就是 `null`(未能判定,绝不猜)。 */
  matchesTarget: boolean | null;
}

/** bundle id 比较:LaunchServices 存的是小写形式,而配置里用户多半按官网写法抄。 */
export function sameBundleID(left: string | null, right: string | null): boolean {
  if (left === null || right === null) return false;
  return left.trim().toLowerCase() === right.trim().toLowerCase();
}

/** 读两个 scheme 的现状,并对着 `target` 给出幂等判据。 */
export async function readHandlerSnapshot(
  reader: DefaultHandlerReader,
  target: string,
): Promise<HandlerSnapshot> {
  const http = await reader.read("http").catch(() => null);
  const https = await reader.read("https").catch(() => null);
  return {
    http,
    https,
    matchesTarget:
      http === null || https === null
        ? null
        : sameBundleID(http, target) && sameBundleID(https, target),
  };
}

// MARK: - 悬空诊断(05 票):handler 指着一个已经不在的 app

/**
 * 「这个 bundle id 在本机还找得到一份装着的 app 吗」——**只读**。
 *
 * 三值,不是布尔:`true` 找得到 / `false` **确知**找不到 / `null` 未能判定。
 * 这一格是整条诊断的分水岭:报一次"悬空"等于告诉用户"你的默认浏览器坏了、去跑这条命令修",
 * 而那句话若来自一台只是**关掉了 Spotlight** 的机器,就是纯粹的假警报。
 * 所以判据只认**确知**的两侧,拿不准一律 `null`(fail-open 的诊断:只报确知的悬空)。
 */
export interface InstalledAppLookup {
  exists(bundleID: string): Promise<boolean | null>;
}

/**
 * 「Spotlight 此刻答不答话」的**对照探询**:每台 macOS 都必然装着 Finder,
 * 所以连它都查不到,就说明查不到的原因是索引而不是那个 app 真的不在。
 */
export const SPOTLIGHT_CONTROL_BUNDLE_ID = "com.apple.finder";

/** 能安全塞进 mdfind 查询串的 bundle id 形状(LaunchServices 里的取值本来就在这个集合内)。 */
const SAFE_BUNDLE_ID = /^[A-Za-z0-9._-]+$/;

/**
 * 生产实现:`mdfind "kMDItemCFBundleIdentifier == '<id>'"`(Spotlight,**零副作用**)。
 *
 * 三条纪律:
 *   1. **绝不用 `open -b <id>`** —— 那条能准确回答"在不在",代价是**真把 app 拉起来**。
 *      一条 `status` 查询不该在用户屏幕上打开任何东西。
 *   2. **空结果不等于"不在"**。索引关了、刚重建、被排除目录,mdfind 都会安静地吐零行 + 退出 0。
 *      于是空结果要再问一次对照探询(Finder):它也查不到 → Spotlight 不答话 → `null`。
 *   3. **查询串里只放白名单字符**。bundle id 来自 LaunchServices 那份库(不是用户输入),
 *      但它终究是外部数据 —— 形状不对就**不查**(返回 `null`),而不是拼一条我们没想过的查询。
 *      argv 本来就不经 shell(`ports.run`),这一条挡的是 mdfind **自己的查询语法**。
 */
export function createInstalledAppLookup(
  ports: UrlRouterPorts,
  platform: string = process.platform,
): InstalledAppLookup {
  async function query(bundleID: string): Promise<{ found: boolean } | undefined> {
    const result = await ports.run(
      [ports.bin.mdfind, `kMDItemCFBundleIdentifier == '${bundleID}'`],
      PROCESS_TIMEOUT_MS,
    );
    if (result.exitCode !== 0) return undefined;
    return { found: result.stdout.split("\n").some((line) => line.trim().length > 0) };
  }

  return {
    async exists(bundleID) {
      // 非 macOS 上没有 LaunchServices、也没有 Spotlight —— 这不是故障,是"没有这回事"。
      if (platform !== "darwin") return null;
      if (!SAFE_BUNDLE_ID.test(bundleID)) return null;
      const answer = await query(bundleID);
      if (answer === undefined) return null;
      if (answer.found) return true;
      // 空结果的两种来路要分开(见纪律 2):对照探询答得上来,这个"没找到"才算数。
      const control = await query(SPOTLIGHT_CONTROL_BUNDLE_ID);
      if (control === undefined || !control.found) return null;
      return false;
    },
  };
}

/** 一条悬空的登记:哪个 scheme、指着哪个找不到的 bundle id。 */
export interface DanglingHandler {
  scheme: HandlerScheme;
  bundleID: string;
}

/**
 * 快照里哪些 scheme 是悬空的(**只报确知的那些**)。
 *
 * 同一个 bundle id 只问一次:两个 scheme 指着同一个 app 是常态,问两遍只是多起一次进程。
 */
export async function findDanglingHandlers(
  snapshot: HandlerSnapshot,
  lookup: InstalledAppLookup,
): Promise<DanglingHandler[]> {
  const verdicts = new Map<string, boolean | null>();
  const dangling: DanglingHandler[] = [];
  for (const scheme of HANDLER_SCHEMES) {
    const bundleID = snapshot[scheme];
    if (bundleID === null || bundleID.trim().length === 0) continue;
    const key = bundleID.trim();
    if (!verdicts.has(key)) {
      verdicts.set(key, await lookup.exists(key).catch(() => null));
    }
    if (verdicts.get(key) === false) dangling.push({ scheme, bundleID: key });
  }
  return dangling;
}
