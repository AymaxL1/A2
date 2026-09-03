// URL 分流的执行侧(施工 02 票):探测、CDP、Roxy API、降级链、把 URL 交出去。
//
// **全用假件**:进程、HTTP、时钟三口都从 `UrlRouterPorts` 注入 —— 于是这套测试
// 不真开浏览器、不依赖本机有没有跑着 RoxyBrowser、不出回环外一个字节。
// 这不只是纪律,也是这一族能被测全的前提:三级降级的每一格都要造出对应的世界才验得到,
// 而那些世界(Roxy 开着但 CDP 拒绝、API 返回了端口但 CDP 还没就绪)在真机上根本摆不出来。
//
// 这一族的错法**几乎全是静默的**:认错 profile 会把链接开进另一个账号的窗口,
// 降级链写反会让人以为"Roxy 每次都要重启一遍",`open` 失败被吞掉会让人以为自己没点中链接。
// 没有一条会报错、会红 —— 所以每一格都得在函数缝上钉死。

import { expect, test } from "bun:test";
import { defaultUrlRouterConfig, type UrlRouterConfig } from "../src/url-router/config.ts";
import {
  CDP_NEW_TAB_TIMEOUT_MS,
  CDP_PROBE_TIMEOUT_MS,
  devToolsPortMatchesProfile,
  extractPort,
  findRoxyDevToolsPort,
  listeningPorts,
  openInExistingRoxy,
  openViaRoxyAPI,
  roxyAPIPortFrom,
  roxyMainPIDs,
  routeUrl,
  sanitizeUrlForLog,
  UrlRouterOpenError,
  type CommandResult,
  type UrlRouterPorts,
} from "../src/url-router/execute.ts";

/** 这台测试机上永远不该被谁看见的一把钥匙 —— 漏进任何报文/步骤,断言就该红。 */
const SECRET_KEY = "roxy-key-绝密-02票";

function config(overrides: Partial<UrlRouterConfig> = {}): UrlRouterConfig {
  return { ...defaultUrlRouterConfig(), ...overrides };
}

/** Roxy API 三件套齐备的一份配置(带那把钥匙)。 */
function apiReadyConfig(overrides: Partial<UrlRouterConfig> = {}): UrlRouterConfig {
  return config({
    roxyAPIHost: "http://127.0.0.1:50000",
    roxyAPIKey: SECRET_KEY,
    roxyWorkspaceID: 7,
    roxyProfileID: "p1",
    ...overrides,
  });
}

interface FakeCall {
  cmd: string[];
  url?: string;
  init?: RequestInit;
}

interface FakeOptions {
  /** 按命令的第一个 token(程序名)给答案。 */
  run?: Record<string, Partial<CommandResult>>;
  /** 按请求 URL 的**子串**给答案(先命中先算);没命中就是连接被拒。 */
  http?: { match: string; status?: number; body?: string; throws?: boolean }[];
}

interface Fake {
  ports: UrlRouterPorts;
  /** 每一次外部动作(按发生顺序)。断言"发了什么、没发什么"都看它。 */
  calls: FakeCall[];
  /** 睡过的毫秒数(验重试循环的间隔与次数)。 */
  slept: number[];
}

function makeFake(options: FakeOptions = {}): Fake {
  const calls: FakeCall[] = [];
  const slept: number[] = [];
  const ports: UrlRouterPorts = {
    bin: { ps: "/fake/ps", lsof: "/fake/lsof", open: "/fake/open", defaults: "/fake/defaults" },
    async run(cmd) {
      calls.push({ cmd: [...cmd] });
      const canned = options.run?.[cmd[0] as string];
      return { exitCode: 0, stdout: "", stderr: "", ...canned };
    },
    async fetch(url, init) {
      calls.push({ cmd: ["fetch"], url, init });
      const rule = options.http?.find((entry) => url.includes(entry.match));
      if (!rule) throw new Error(`fake fetch:没人管这条 ${url}(当作连接被拒)`);
      if (rule.throws) throw new Error("fake fetch:按约定抛一次");
      return new Response(rule.body ?? "", { status: rule.status ?? 200 });
    },
    async sleep(ms) {
      slept.push(ms);
    },
  };
  return { ports, calls, slept };
}

/** 只取 fetch 那些调用的 URL(断言"问了谁、按什么顺序问的")。 */
function fetched(fake: Fake): string[] {
  return fake.calls.filter((call) => call.cmd[0] === "fetch").map((call) => call.url as string);
}

// MARK: - 日志脱敏(母本 sanitize)

test("脱敏:query 与 fragment 一律换成 redacted,路径与 host 原样留着", () => {
  expect(sanitizeUrlForLog("https://claude.ai/chat/abc?token=秘密&x=1#section-2")).toBe(
    "https://claude.ai/chat/abc?redacted#redacted",
  );
  // 没有的东西不凭空加(母本语义:有值才换)。
  expect(sanitizeUrlForLog("https://claude.ai/chat")).toBe("https://claude.ai/chat");
  expect(sanitizeUrlForLog("https://claude.ai/chat?a=1")).toBe("https://claude.ai/chat?redacted");
  expect(sanitizeUrlForLog("https://claude.ai/chat#top")).toBe("https://claude.ai/chat#redacted");
});

test("脱敏:解析不动的字符串**不回显原文** —— 那是系统送进来的任意文本,不替它转发", () => {
  const sanitized = sanitizeUrlForLog("这不是 URL,而且里面有 秘密-Xy9");
  expect(sanitized).not.toContain("秘密-Xy9");
  expect(sanitized).toContain("已隐去原文");
});

// MARK: - 探测:ps → lsof → CDP 校验

const ROXY_LINE = " 4321 /Applications/RoxyBrowser.app/Contents/MacOS/RoxyBrowser --user-data-dir=/Users/me/browser-cache/p1";

test("ps:主进程要同时满足三条 —— 是 Roxy、是这个 profile、不是 /Helpers/ 子进程", async () => {
  const fake = makeFake({
    run: {
      "/fake/ps": {
        stdout: [
          ROXY_LINE,
          // 是 Roxy、也是这个 profile,但**是渲染子进程** —— 它没有 CDP,认上它只是白问一次 lsof。
          " 4322 /Applications/RoxyBrowser.app/Contents/MacOS/../Helpers/RoxyBrowser Helper --user-data-dir=/Users/me/browser-cache/p1",
          // 是 Roxy,但是**另一个 profile** —— 认上它就会把链接开进别人的账号。
          " 4323 /Applications/RoxyBrowser.app/Contents/MacOS/RoxyBrowser --user-data-dir=/Users/me/browser-cache/p2",
          // 压根不是 Roxy。
          " 4324 /Applications/Safari.app/Contents/MacOS/Safari",
        ].join("\n"),
      },
    },
  });

  const pids = await roxyMainPIDs(fake.ports, config({ roxyProfileID: "p1" }));

  expect(pids).toEqual([4321]);
  expect(fake.calls[0]?.cmd).toEqual(["/fake/ps", "axww", "-o", "pid=,command="]);
});

test("lsof:只认回环上的 LISTEN 端口(别的地址不是我们要找的 CDP)", async () => {
  const fake = makeFake({
    run: {
      "/fake/lsof": {
        stdout: [
          "RoxyBrows 4321 me   30u  IPv4 0x1  0t0  TCP 127.0.0.1:50325 (LISTEN)",
          "RoxyBrows 4321 me   31u  IPv4 0x2  0t0  TCP 127.0.0.1:50326 (LISTEN)",
          "RoxyBrows 4321 me   32u  IPv4 0x3  0t0  TCP 192.168.1.9:8080 (LISTEN)",
        ].join("\n"),
      },
    },
  });

  expect(await listeningPorts(fake.ports, 4321)).toEqual([50325, 50326]);
  expect(fake.calls[0]?.cmd).toEqual([
    "/fake/lsof",
    "-nP",
    "-a",
    "-p",
    "4321",
    "-iTCP",
    "-sTCP:LISTEN",
  ]);
});

test("CDP 校验:两问都要过 —— 是个 Chrome CDP,且是**这一个** profile", async () => {
  const chrome = { match: "/json/version", body: '{"Browser":"Chrome/131.0.0.0"}' };

  // 两问都过。
  const good = makeFake({
    http: [chrome, { match: "/json/list", body: '[{"url":"chrome://…/dashboard.html?id=p1"}]' }],
  });
  expect(await devToolsPortMatchesProfile(good.ports, config({ roxyProfileID: "p1" }), 50325)).toBe(
    true,
  );

  // 是个 CDP,但列表里是**别的 profile** —— 必须判否,否则链接会开进另一个账号的窗口。
  const otherProfile = makeFake({
    http: [chrome, { match: "/json/list", body: '[{"url":"chrome://…/dashboard.html?id=p2"}]' }],
  });
  expect(
    await devToolsPortMatchesProfile(otherProfile.ports, config({ roxyProfileID: "p1" }), 50325),
  ).toBe(false);

  // 端口上听着的不是 CDP(第一问就不过,**第二问根本不该发**)。
  const notCdp = makeFake({ http: [{ match: "/json/version", body: "hello" }] });
  expect(await devToolsPortMatchesProfile(notCdp.ports, config({ roxyProfileID: "p1" }), 50325)).toBe(
    false,
  );
  expect(fetched(notCdp)).toHaveLength(1);
});

test("CDP 校验:探测用的是短超时(母本 0.8s),且非 2xx 一律当作问不到", async () => {
  const fake = makeFake({ http: [{ match: "/json/version", status: 500, body: "Chrome/131" }] });

  expect(await devToolsPortMatchesProfile(fake.ports, config(), 50325)).toBe(false);

  const signal = (fake.calls[0]?.init?.signal ?? undefined) as AbortSignal | undefined;
  expect(signal).toBeInstanceOf(AbortSignal);
  // 数值本身是契约(母本 0.8s):改动它是一次决策,不该悄悄发生。
  expect(CDP_PROBE_TIMEOUT_MS).toBe(800);
});

test("找端口:去重升序逐个校验,取第一个对上的;一个都对不上就是 null", async () => {
  const fake = makeFake({
    run: {
      "/fake/ps": { stdout: ROXY_LINE },
      // 有意乱序 + 重复:输出必须是稳定的(否则"有时开到 A 窗口有时开到 B"没人查得出来)。
      "/fake/lsof": {
        stdout:
          "TCP 127.0.0.1:50999 (LISTEN)\nTCP 127.0.0.1:50325 (LISTEN)\nTCP 127.0.0.1:50325 (LISTEN)",
      },
    },
    http: [
      { match: ":50325/json/version", body: "Chrome/131" },
      { match: ":50325/json/list", body: "dashboard.html?id=p1" },
      { match: ":50999/json/version", body: "别的东西" },
    ],
  });

  expect(await findRoxyDevToolsPort(fake.ports, config({ roxyProfileID: "p1" }))).toBe(50325);
  // 升序 → 先问 50325,对上就收工,50999 一个字节都没发。
  expect(fetched(fake).some((url) => url.includes("50999"))).toBe(false);
});

test("找端口:一台没跑 Roxy 的机器上是 null,且**不会去问 lsof**", async () => {
  const fake = makeFake({ run: { "/fake/ps": { stdout: "" } } });

  expect(await findRoxyDevToolsPort(fake.ports, config())).toBeNull();
  expect(fake.calls).toHaveLength(1);
});

// MARK: - 开标签页(`#` 坑的活体断言)

test("开标签页:PUT /json/new,fragment 的 # 编成 %23(直译 encodeURI 会把 URL 截断)", async () => {
  const fake = makeFake({ http: [{ match: "/json/new", status: 200 }] });

  expect(await openInExistingRoxy(fake.ports, 50325, "https://claude.ai/x#frag")).toBe(true);

  const call = fake.calls[0] as FakeCall;
  expect(call.init?.method).toBe("PUT");
  expect(call.url).toBe("http://127.0.0.1:50325/json/new?https://claude.ai/x%23frag");
  // 整条 URL 必须完好地待在 query 里 —— 保留裸 `#` 的话 Chrome 只看 query,打开的是被截断的那一页。
  expect(call.url).not.toContain("#");
  expect(CDP_NEW_TAB_TIMEOUT_MS).toBe(2000);
});

test("开标签页:非 2xx 与连接被拒都是 false(不抛)—— 它是降级链的判据,不是异常", async () => {
  const refused = makeFake();
  expect(await openInExistingRoxy(refused.ports, 50325, "https://claude.ai/x")).toBe(false);

  const rejected = makeFake({ http: [{ match: "/json/new", status: 404 }] });
  expect(await openInExistingRoxy(rejected.ports, 50325, "https://claude.ai/x")).toBe(false);
});

// MARK: - Roxy API

test("API 端口解析:完整 URL 与裸 host:port 都认,顺序 http → driver → ws", () => {
  expect(extractPort("http://127.0.0.1:50325")).toBe(50325);
  expect(extractPort("127.0.0.1:50325")).toBe(50325);
  expect(extractPort("没有端口")).toBeUndefined();

  const noted: string[] = [];
  const note = (line: string) => noted.push(line);
  expect(roxyAPIPortFrom({ data: { ws: "ws://127.0.0.1:3", driver: "127.0.0.1:2", http: "127.0.0.1:1" } }, note)).toBe(1);
  expect(roxyAPIPortFrom({ data: { ws: "ws://127.0.0.1:3", driver: "127.0.0.1:2" } }, note)).toBe(2);
  expect(roxyAPIPortFrom({ data: { ws: "ws://127.0.0.1:3" } }, note)).toBe(3);
});

test("API 端口解析:code 非 0 即失败(留一行痕),data 不是对象也失败", () => {
  const noted: string[] = [];
  const note = (line: string) => noted.push(line);

  expect(roxyAPIPortFrom({ code: 1001, msg: "profile 不存在", data: { http: "127.0.0.1:1" } }, note)).toBeUndefined();
  expect(noted[0]).toContain("code=1001");
  expect(roxyAPIPortFrom({ code: 0, data: null }, note)).toBeUndefined();
  expect(roxyAPIPortFrom("不是对象", note)).toBeUndefined();
});

test("API:key 只进请求头,payload 是 workspaceId/dirId/forceOpen,拿到端口后重试开标签页", async () => {
  const fake = makeFake({
    http: [
      { match: "/browser/open", body: JSON.stringify({ code: 0, data: { http: "http://127.0.0.1:50325" } }) },
      { match: "/json/new", status: 200 },
    ],
  });

  const port = await openViaRoxyAPI(fake.ports, apiReadyConfig(), "https://claude.ai/x", () => {});

  expect(port).toBe(50325);
  const post = fake.calls[0] as FakeCall;
  expect(post.url).toBe("http://127.0.0.1:50000/browser/open");
  expect(post.init?.method).toBe("POST");
  expect(JSON.parse(post.init?.body as string)).toEqual({
    workspaceId: 7,
    dirId: "p1",
    forceOpen: false,
  });
  // 钥匙**只在请求头里**,且头名照配置(母本 roxyAPITokenHeader)。
  expect((post.init?.headers as Record<string, string>)["token"]).toBe(SECRET_KEY);
  expect(post.init?.body).not.toContain(SECRET_KEY);
});

test("API:三件套没配齐就直接不走这条路(拿半份配置去调只会白等一个超时)", async () => {
  const fake = makeFake();
  const noKey = apiReadyConfig({ roxyAPIKey: null });

  expect(await openViaRoxyAPI(fake.ports, noKey, "https://claude.ai/x", () => {})).toBeNull();
  expect(fake.calls).toHaveLength(0);
});

test("API:profile 开起来了但 CDP 还没就绪 —— 按 attempts 重试、按 delay 间隔,末次失败后不再白等", async () => {
  let newTabCalls = 0;
  const fake = makeFake({
    http: [
      { match: "/browser/open", body: JSON.stringify({ code: 0, data: { http: "127.0.0.1:50325" } }) },
    ],
  });
  // 前两次拒绝、第三次成功。
  const inner = fake.ports.fetch.bind(fake.ports);
  (fake.ports as { fetch: UrlRouterPorts["fetch"] }).fetch = async (url, init) => {
    if (url.includes("/json/new")) {
      newTabCalls += 1;
      fake.calls.push({ cmd: ["fetch"], url, init });
      return new Response("", { status: newTabCalls >= 3 ? 200 : 500 });
    }
    return await inner(url, init);
  };

  const port = await openViaRoxyAPI(
    fake.ports,
    apiReadyConfig({ roxyStartupAttempts: 5, roxyStartupDelaySeconds: 0.2 }),
    "https://claude.ai/x",
    () => {},
  );

  expect(port).toBe(50325);
  expect(newTabCalls).toBe(3);
  // 三次尝试之间睡两觉 —— 成功那次之后不再睡。
  expect(fake.slept).toEqual([200, 200]);
});

test("API:配置里的次数/间隔在**使用侧**钳制(0 次 → 至少试一次;0 间隔 → 至少 50ms)", async () => {
  const fake = makeFake({
    http: [
      { match: "/browser/open", body: JSON.stringify({ code: 0, data: { http: "127.0.0.1:1" } }) },
      { match: "/json/new", status: 500 },
    ],
  });

  const port = await openViaRoxyAPI(
    fake.ports,
    apiReadyConfig({ roxyStartupAttempts: 0, roxyStartupDelaySeconds: 0 }),
    "https://claude.ai/x",
    () => {},
  );

  expect(port).toBeNull();
  // `max(1, attempts)`:一次都不试等于这条路根本没走过。
  expect(fetched(fake).filter((url) => url.includes("/json/new"))).toHaveLength(1);
  expect(fake.slept).toEqual([]);
});

test("API:超大的超时/次数不会把这条能力挂死(上限钳制;1e300 连 AbortSignal 都收不下)", async () => {
  const fake = makeFake({
    http: [
      { match: "/browser/open", body: JSON.stringify({ code: 0, data: { http: "127.0.0.1:1" } }) },
      { match: "/json/new", status: 500 },
    ],
  });

  const port = await openViaRoxyAPI(
    fake.ports,
    apiReadyConfig({
      roxyAPITimeoutSeconds: 1e300,
      roxyStartupAttempts: 1_000_000_000,
      roxyStartupDelaySeconds: 1e9,
    }),
    "https://claude.ai/x",
    () => {},
  );

  expect(port).toBeNull();
  // 钳到上限:100 次尝试、每次 5s(假时钟不真睡),而不是十亿次。
  expect(fetched(fake).filter((url) => url.includes("/json/new"))).toHaveLength(100);
  expect(new Set(fake.slept)).toEqual(new Set([5000]));
});

// MARK: - route:决策 + 执行 + 降级

test("route:没命中分流域名 → `open -b <兜底浏览器> <url>`,URL 是独立 argv 且**不脱敏**", async () => {
  const fake = makeFake();

  const result = await routeUrl({
    ports: fake.ports,
    config: config(),
    url: "https://example.com/a?token=秘密#f",
  });

  expect(result.action).toBe("fallback-browser");
  expect(result.decision).toBe("fallback-browser");
  expect(result.fellBack).toBe(false);
  // 交给 open 的是**原文**(脱敏只针对报文;把 redacted 真开给用户等于打开了错误的页面)。
  expect(fake.calls[0]?.cmd).toEqual([
    "/fake/open",
    "-b",
    "com.apple.Safari",
    "https://example.com/a?token=秘密#f",
  ]);
  // 而报文里那条是脱敏过的。
  expect(result.url).toBe("https://example.com/a?redacted#redacted");
  expect(JSON.stringify(result)).not.toContain("秘密");
});

test("route:不是 http(s) 也交兜底浏览器,但报文里 decision 说得清是 unsupported", async () => {
  const fake = makeFake();

  const result = await routeUrl({ ports: fake.ports, config: config(), url: "ftp://x/y" });

  expect(result.decision).toBe("unsupported");
  expect(result.action).toBe("fallback-browser");
});

test("route:命中 + Roxy 开着 + CDP 通 → 就在那个窗口开标签页,不碰 open", async () => {
  const fake = makeFake({
    run: { "/fake/ps": { stdout: ROXY_LINE }, "/fake/lsof": { stdout: "TCP 127.0.0.1:50325 (LISTEN)" } },
    http: [
      { match: "/json/version", body: "Chrome/131" },
      { match: "/json/list", body: "dashboard.html?id=p1" },
      { match: "/json/new", status: 200 },
    ],
  });

  const result = await routeUrl({
    ports: fake.ports,
    config: config({ roxyProfileID: "p1" }),
    url: "https://claude.ai/chat",
  });

  expect(result.decision).toBe("roxy-cdp:50325");
  expect(result.action).toBe("cdp-new-tab");
  expect(result.target).toBe("127.0.0.1:50325");
  expect(result.fellBack).toBe(false);
  expect(fake.calls.some((call) => call.cmd[0] === "/fake/open")).toBe(false);
});

test("route:CDP 探到了却开不进去 → **降到 launcher**,fellBack 与 steps 如实说", async () => {
  const fake = makeFake({
    run: { "/fake/ps": { stdout: ROXY_LINE }, "/fake/lsof": { stdout: "TCP 127.0.0.1:50325 (LISTEN)" } },
    http: [
      { match: "/json/version", body: "Chrome/131" },
      { match: "/json/list", body: "dashboard.html?id=p1" },
      { match: "/json/new", status: 500 },
    ],
  });

  const result = await routeUrl({
    ports: fake.ports,
    config: config({ roxyProfileID: "p1" }),
    url: "https://claude.ai/chat",
  });

  expect(result.decision).toBe("roxy-cdp:50325");
  expect(result.action).toBe("roxy-launcher");
  expect(result.fellBack).toBe(true);
  expect(result.steps.join("\n")).toContain("cdp-failed port=50325");
  expect(fake.calls.at(-1)?.cmd).toEqual([
    "/fake/open",
    "-a",
    "/Applications/RoxyBrowser.app",
    "https://claude.ai/chat",
  ]);
});

test("route:命中但 Roxy 没跑、API 也没配 → 直接拉起 .app(三级里的最后一级)", async () => {
  const fake = makeFake({ run: { "/fake/ps": { stdout: "" } } });

  const result = await routeUrl({
    ports: fake.ports,
    config: config(),
    url: "https://claude.ai/chat",
  });

  expect(result.decision).toBe("roxy-launcher");
  expect(result.action).toBe("roxy-launcher");
  expect(result.fellBack).toBe(false);
});

test("route:API 那一级 —— 成了就报它开在哪个端口;没成就降到 launcher", async () => {
  const ok = makeFake({
    run: { "/fake/ps": { stdout: "" } },
    http: [
      { match: "/browser/open", body: JSON.stringify({ code: 0, data: { http: "127.0.0.1:50325" } }) },
      { match: "/json/new", status: 200 },
    ],
  });
  const opened = await routeUrl({
    ports: ok.ports,
    config: apiReadyConfig(),
    url: "https://claude.ai/chat",
  });
  expect(opened.decision).toBe("roxy-api");
  expect(opened.action).toBe("roxy-api");
  expect(opened.target).toBe("127.0.0.1:50325");

  const bad = makeFake({
    run: { "/fake/ps": { stdout: "" } },
    http: [{ match: "/browser/open", status: 500 }],
  });
  const fellBack = await routeUrl({
    ports: bad.ports,
    config: apiReadyConfig(),
    url: "https://claude.ai/chat",
  });
  expect(fellBack.decision).toBe("roxy-api");
  expect(fellBack.action).toBe("roxy-launcher");
  expect(fellBack.fellBack).toBe(true);
  // 那把钥匙一个字都不许进步骤(步骤是要进报文的)。
  expect(fellBack.steps.join("\n")).not.toContain(SECRET_KEY);
});

test("route:最后那步 open 非零退出 → 抛 UrlRouterOpenError(母本只写日志,这里必须说出来)", async () => {
  const fake = makeFake({
    run: { "/fake/open": { exitCode: 1, stderr: "LSCopyApplicationURLsForBundleIdentifier() failed" } },
  });

  const failure = routeUrl({
    ports: fake.ports,
    config: config({ fallbackBrowserBundleID: "com.不存在.浏览器" }),
    url: "https://example.com/a",
  });

  await expect(failure).rejects.toBeInstanceOf(UrlRouterOpenError);
  await failure.catch((error: UrlRouterOpenError) => {
    expect(error.target).toBe("com.不存在.浏览器");
    expect(error.detail).toContain("退出码 1");
    expect(error.detail).toContain("LSCopyApplicationURLsForBundleIdentifier");
  });
});
