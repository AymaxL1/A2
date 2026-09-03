// URL 分流的决策核心(施工 01 票):域名两分、五值词表、CDP 端点编码。
//
// 为什么这一族值得在函数缝上把边界写全,而不是等 e2e:**错法都是静默的**。
// 域名判据松一格,`claude.ai.evil.com` 就会被送进登录着账号的 profile,而现象是"打开了";
// CDP 那段编码直译,带 fragment 的链接会被截断,现象是"打开了,但不是那一页"。
// 两种都不会报错、不会红,只会让人以为自己记错了网址。
//
// 决策所需的运行期事实(CDP 端口)在这里是**注入的参数** —— 探测的真身归 02 票,
// 但"探到了/没探到"这两种世界下的分支必须现在就钉死。

import { expect, test } from "bun:test";
import { cdpNewTabEndpoint, encodeCdpTargetURL } from "../src/url-router/cdp.ts";
import { defaultUrlRouterConfig, type UrlRouterConfig } from "../src/url-router/config.ts";
import { decide, decisionWord, isRoutedHost, normalizeHost } from "../src/url-router/decide.ts";

/** 缺省配置 + 若干覆写,省得每条用例抄全表。 */
function config(overrides: Partial<UrlRouterConfig> = {}): UrlRouterConfig {
  return { ...defaultUrlRouterConfig(), ...overrides };
}

/** 决策的线上写法(词表就是契约,断言一律对它,不对内部形状)。 */
function wordFor(url: string, port: number | null = null, overrides: Partial<UrlRouterConfig> = {}): string {
  return decisionWord(decide({ url, config: config(overrides), roxyDevToolsPort: port }));
}

/** 配齐 Roxy API 三件套(host + key + workspaceID)。 */
const API_READY: Partial<UrlRouterConfig> = {
  roxyAPIHost: "http://127.0.0.1:50000",
  roxyAPIKey: "不该出现在任何报文里",
  roxyWorkspaceID: 7,
};

// MARK: - 域名两分

test("域名两分:命中本域与任意层子域名,不命中同后缀的旁域名", () => {
  // 命中:域名本身,以及 `.claude.ai` 结尾的任意层子域。
  expect(isRoutedHost("claude.ai", ["claude.ai"])).toBe(true);
  expect(isRoutedHost("www.claude.ai", ["claude.ai"])).toBe(true);
  expect(isRoutedHost("a.b.c.claude.ai", ["claude.ai"])).toBe(true);

  // 不命中:少了那个点就是另一家。这三条正是判据写松时会漏进来的钓鱼形状。
  expect(isRoutedHost("claude.ai.evil.com", ["claude.ai"])).toBe(false);
  expect(isRoutedHost("notclaude.ai", ["claude.ai"])).toBe(false);
  expect(isRoutedHost("evilclaude.ai", ["claude.ai"])).toBe(false);
  // 反过来也不行:配置里写的是子域,访问父域不该命中。
  expect(isRoutedHost("claude.ai", ["www.claude.ai"])).toBe(false);
});

test("域名两分:host 与配置里的域名**两边都归一**(大小写、前后点号)", () => {
  expect(normalizeHost(".Claude.AI.")).toBe("claude.ai");
  expect(normalizeHost("..a.b..")).toBe("a.b");

  // host 侧:大写、尾点(`claude.ai.` 是合法的绝对域名写法,URL.hostname 原样留着那个点)。
  expect(isRoutedHost("CLAUDE.AI", ["claude.ai"])).toBe(true);
  expect(isRoutedHost("claude.ai.", ["claude.ai"])).toBe(true);
  expect(isRoutedHost("WWW.Claude.AI.", ["claude.ai"])).toBe(true);
  // 配置侧:用户写成 `.Claude.AI` 或 `CLAUDE.AI.` 都该照样工作。
  expect(isRoutedHost("www.claude.ai", [".Claude.AI"])).toBe(true);
  expect(isRoutedHost("claude.ai", ["CLAUDE.AI."])).toBe(true);
});

test("域名两分:空 host 与空域名一律不命中(手滑的 `\"\"` 不该把全世界送进 Roxy)", () => {
  expect(isRoutedHost("", ["claude.ai"])).toBe(false);
  expect(isRoutedHost(".", ["claude.ai"])).toBe(false);
  expect(isRoutedHost("example.com", [""])).toBe(false);
  expect(isRoutedHost("example.com", ["."])).toBe(false);
  // 空表 = 一条都不分流(合法配置,不是错)。
  expect(isRoutedHost("claude.ai", [])).toBe(false);
});

test("域名两分:国际化域名按 URL 归一后的 punycode 比,子域照样命中", () => {
  // `https://用户.claude.ai/` 的 hostname 是 `xn--zouo53b.claude.ai` —— 仍是 `.claude.ai` 的子域。
  expect(wordFor("https://用户.claude.ai/x")).toBe("roxy-launcher");
});

// MARK: - 五值词表(spec §3)

test("decide:非 http/https 一律 unsupported —— 连域名都不看", () => {
  for (const url of [
    "ftp://claude.ai/x",
    "file:///etc/passwd",
    "mailto:someone@claude.ai",
    "javascript:alert(1)",
    "data:text/html,<h1>hi</h1>",
    "a2://claude.ai",
  ]) {
    expect(wordFor(url, 9222, API_READY)).toBe("unsupported");
  }
  // 解析不动的字符串同样是 unsupported:壳转发的是系统给的任意串,内核不猜它想说什么。
  expect(wordFor("claude.ai/foo")).toBe("unsupported");
  expect(wordFor("")).toBe("unsupported");
  // scheme 大小写不敏感(URL 自己归一),HTTP:// 是正经可分流的。
  expect(wordFor("HTTP://example.com/")).toBe("fallback-browser");
});

test("decide:未命中分流域名 → fallback-browser(有 CDP 端口也不改判)", () => {
  expect(wordFor("https://example.com/x")).toBe("fallback-browser");
  expect(wordFor("https://example.com/x", 9222, API_READY)).toBe("fallback-browser");
});

test("decide:命中后按 CDP → API → launcher 三级降级,一级一条词", () => {
  const hit = "https://claude.ai/chat/1";
  // 一级:探到了属于目标 profile 的 CDP 端口,端口进词。
  expect(wordFor(hit, 9222)).toBe("roxy-cdp:9222");
  expect(wordFor(hit, 9222, API_READY)).toBe("roxy-cdp:9222");
  // 二级:没有 CDP,但 API 三件套齐备。
  expect(wordFor(hit, null, API_READY)).toBe("roxy-api");
  // 三级:两样都没有 —— 拉起 Roxy 本体。
  expect(wordFor(hit, null)).toBe("roxy-launcher");
});

test("decide:Roxy API 三件套缺一即降到 launcher,空白串按没配算", () => {
  const hit = "https://claude.ai/";
  expect(wordFor(hit, null, { ...API_READY, roxyAPIHost: null })).toBe("roxy-launcher");
  expect(wordFor(hit, null, { ...API_READY, roxyAPIKey: null })).toBe("roxy-launcher");
  expect(wordFor(hit, null, { ...API_READY, roxyWorkspaceID: null })).toBe("roxy-launcher");
  // 配置文件里留一行 `"roxyAPIKey": "   "` 不该被当成设过。
  expect(wordFor(hit, null, { ...API_READY, roxyAPIKey: "   " })).toBe("roxy-launcher");
  expect(wordFor(hit, null, { ...API_READY, roxyAPIHost: " " })).toBe("roxy-launcher");
  // workspaceID 是 0 则是**设过**(0 不是"没配"),该走 API。
  expect(wordFor(hit, null, { ...API_READY, roxyWorkspaceID: 0 })).toBe("roxy-api");
});

test("decide:缺省域名表就是产品意图 —— 三条 Anthropic 域进 Roxy,别的进兜底", () => {
  for (const host of ["claude.ai", "claude.com", "anthropic.com", "www.claude.ai", "console.anthropic.com"]) {
    expect(wordFor(`https://${host}/`)).toBe("roxy-launcher");
  }
  for (const host of ["example.com", "anthropic.com.evil.net", "github.com"]) {
    expect(wordFor(`https://${host}/`)).toBe("fallback-browser");
  }
});

test("decisionWord:五条词逐字对上 spec §3 的词表(值即契约)", () => {
  expect(decisionWord({ kind: "fallback-browser" })).toBe("fallback-browser");
  expect(decisionWord({ kind: "roxy-cdp", port: 61234 })).toBe("roxy-cdp:61234");
  expect(decisionWord({ kind: "roxy-api" })).toBe("roxy-api");
  expect(decisionWord({ kind: "roxy-launcher" })).toBe("roxy-launcher");
  expect(decisionWord({ kind: "unsupported" })).toBe("unsupported");
});

// MARK: - CDP 端点编码(02 研究票的那个坑)

test("CDP 编码:`#` 必须成 `%23` —— 直译 encodeURI 会让 fragment 在 `/json/new?` 处被截断", () => {
  const target = "https://claude.ai/chat/abc#msg-42";

  // 差异见证:JS 的 encodeURI **保留** `#`,Swift 的 .urlQueryAllowed **不含** `#`。
  // 这两行就是"为什么不能直接换"的证据,它俩同时成立才说明补丁没白打。
  expect(encodeURI(target)).toContain("#");
  expect(encodeCdpTargetURL(target)).not.toContain("#");
  expect(encodeCdpTargetURL(target)).toBe("https://claude.ai/chat/abc%23msg-42");

  // 后果面:端点自己必须没有 fragment,整条目标 URL 完好地留在 query 里。
  const endpoint = new URL(cdpNewTabEndpoint(9222, target));
  expect(endpoint.hash).toBe("");
  expect(endpoint.search).toBe("?https://claude.ai/chat/abc%23msg-42");
  // Chrome 那头解出来的,得是原样那条 URL(含 fragment),一个字符都不少。
  expect(decodeURIComponent(endpoint.search.slice(1))).toBe(target);
});

test("CDP 编码:query 与 fragment 同时在场时,`?`/`&` 照母本保留、只有 `#` 被编", () => {
  const target = "https://claude.ai/x?a=1&b=2#f";
  expect(encodeCdpTargetURL(target)).toBe("https://claude.ai/x?a=1&b=2%23f");
  // 刻意不用 encodeURIComponent:它把 `:` `/` 也编掉,传出去的字节与母本不同,是另一种改写。
  expect(encodeURIComponent(target)).toContain("%3A%2F%2F");
  expect(encodeCdpTargetURL(target)).toContain("://");
});

test("CDP 端点:恒回环 + `/json/new?`,空格与非 ASCII 正常百分号编码", () => {
  expect(cdpNewTabEndpoint(9222, "https://claude.ai/a b")).toBe(
    "http://127.0.0.1:9222/json/new?https://claude.ai/a%20b",
  );
  expect(cdpNewTabEndpoint(61234, "https://claude.ai/搜索")).toBe(
    "http://127.0.0.1:61234/json/new?https://claude.ai/%E6%90%9C%E7%B4%A2",
  );
});
