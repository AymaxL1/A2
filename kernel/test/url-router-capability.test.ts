// URL 分流的能力面(施工 02 票):五条 manifest、三种 result、接管的幂等判据,
// 以及系统默认 handler 的只读读取。
//
// 三件事在这儿钉死:
//   * **manifest 就是契约** —— id / risk / cliAlias 一个字都不许漂:risk 定错了,dangerous 那道
//     默拒的门就形同虚设(`route` 若被写成 safe,一条命令就能在用户脸上开窗口而不经任何把关);
//   * **报文形状对得上登记契约** —— 每条 result 都拿 wire.ts 的 schema 现场校一遍(活体对照,
//     与金标样本互为独立事实源:样本是手写的期望,这里是代码真产出的东西);
//   * **接管的幂等判据 fail-closed** —— 读不出 handler 时按「不是目标」处理。猜"大概已经是了"
//     会让一次真正需要人点头的接管被静默跳过,那是安全模型上的洞,不是体验问题。
//
// 纪律:临时 A2_HOME(/tmp),外部世界全是假件 —— 不真开浏览器、不读真进程表、不出回环外网络。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { urlRouterCapabilities } from "../src/capability/url-router.ts";
import type { Capability } from "../src/capability/registry.ts";
import { CapabilityFailedError } from "../src/capability/registry.ts";
import { exitCodeForErrorCode } from "../src/contract/exit-codes.ts";
import {
  ErrorCode,
  UrlRouterDecideResultSchema,
  UrlRouterHandoffResultSchema,
  UrlRouterRouteResultSchema,
  UrlRouterStatusResultSchema,
  type JsonValue,
} from "../src/contract/wire.ts";
import { resolvePaths } from "../src/runtime/paths.ts";
import { URL_ROUTER_CONFIG_NAME } from "../src/url-router/config.ts";
import type { CommandResult, UrlRouterPorts } from "../src/url-router/execute.ts";
import {
  A2_PANEL_BUNDLE_ID,
  parseLaunchServicesHandler,
  type DefaultHandlerReader,
  type HandlerScheme,
} from "../src/url-router/handler.ts";

const SECRET_KEY = "roxy-key-绝密-能力面";

let home: string;

beforeEach(async () => {
  home = await mkdtemp("/tmp/a2urlcap-");
});

afterEach(async () => {
  await rm(home, { recursive: true, force: true });
});

// MARK: - 夹具

/** 什么都不肯做的进程/HTTP/时钟口:默认世界里 Roxy 没跑、网络不通、open 成功。 */
function fakePorts(overrides: Partial<UrlRouterPorts> = {}): UrlRouterPorts {
  return {
    bin: { ps: "/fake/ps", lsof: "/fake/lsof", open: "/fake/open", defaults: "/fake/defaults" },
    async run(): Promise<CommandResult> {
      return { exitCode: 0, stdout: "", stderr: "" };
    },
    async fetch(): Promise<Response> {
      throw new Error("fake:这条测试不该发任何 HTTP");
    },
    async sleep(): Promise<void> {},
    ...overrides,
  };
}

/** 两个 scheme 各报一个 bundle id(`null` = 读不出来)。 */
function fakeHandlers(http: string | null, https: string | null): DefaultHandlerReader {
  return { async read(scheme: HandlerScheme) { return scheme === "http" ? http : https; } };
}

function capabilities(options: {
  ports?: UrlRouterPorts;
  handlers?: DefaultHandlerReader;
} = {}): Map<string, Capability> {
  const list = urlRouterCapabilities({
    paths: resolvePaths({ A2_HOME: home }),
    env: {},
    ports: options.ports ?? fakePorts(),
    handlers: options.handlers ?? fakeHandlers(null, null),
  });
  return new Map(list.map((capability) => [capability.descriptor.id, capability]));
}

async function call(
  id: string,
  input: Record<string, JsonValue> = {},
  options: Parameters<typeof capabilities>[0] = {},
): Promise<JsonValue> {
  const capability = capabilities(options).get(id);
  if (!capability) throw new Error(`没有这条能力:${id}`);
  return await capability.handler(input);
}

async function writeConfigFile(text: string): Promise<void> {
  await writeFile(path.join(home, URL_ROUTER_CONFIG_NAME), text, "utf8");
}

// MARK: - manifest

test("五条能力齐、id 与风险档逐字对上 spec §3 那张表", () => {
  const all = [...capabilities().values()].map((capability) => capability.descriptor);

  expect(all.map((descriptor) => [descriptor.id, descriptor.risk])).toEqual([
    ["url-router.status", "safe"],
    ["url-router.decide", "safe"],
    ["url-router.route", "normal"],
    ["url-router.takeover", "dangerous"],
    ["url-router.restore", "dangerous"],
  ]);
});

test("每条都带 cliAlias —— `a2 url-router …` 的写法全靠它,漏一条那个子命令就凭空消失", () => {
  const aliases = [...capabilities().values()].map((capability) => capability.descriptor.cliAlias);

  expect(aliases).toEqual([
    ["url-router", "status"],
    ["url-router", "decide"],
    ["url-router", "route"],
    ["url-router", "takeover"],
    ["url-router", "restore"],
  ]);
});

test("URL 是必填参数(`decide` / `route` 各一份声明,类型 string)", () => {
  for (const id of ["url-router.decide", "url-router.route"]) {
    const parameters = capabilities().get(id)?.descriptor.parameters ?? [];
    expect(parameters.map((spec) => [spec.name, spec.type, spec.required])).toEqual([
      ["url", "string", true],
    ]);
  }
  // restore 的 `--to` 是可选覆写。
  expect(capabilities().get("url-router.restore")?.descriptor.parameters).toEqual([
    expect.objectContaining({ name: "to", type: "string", required: false }),
  ]);
});

// MARK: - status

test("status:没有配置文件 = 全缺省(合法状态),handler 读不出来就如实说未能判定", async () => {
  const result = await call("url-router.status");
  const parsed = UrlRouterStatusResultSchema.parse(result);

  expect(parsed.configSource).toBe("defaults");
  expect(parsed.problem).toBeUndefined();
  expect(parsed.configPath).toBe(path.join(home, URL_ROUTER_CONFIG_NAME));
  expect(parsed.panelBundleID).toBe(A2_PANEL_BUNDLE_ID);
  expect(parsed.handler).toEqual({
    http: null,
    https: null,
    matchesTarget: null,
    undetermined: expect.stringContaining("未能判定"),
  });
});

test("status:配置文件用不了 → 整份退回缺省 + problem 指名道姓,**绝不带原文片段**", async () => {
  await writeConfigFile(`{ 坏掉的 JSON,里面躺着 "${SECRET_KEY}" `);

  const parsed = UrlRouterStatusResultSchema.parse(await call("url-router.status"));

  expect(parsed.configSource).toBe("unusable");
  expect(parsed.problem).toBeTruthy();
  // 缺省仍然完整可用 —— 配歪了的机器照样分流。
  expect(parsed.config.routedDomains).toEqual(["claude.ai", "claude.com", "anthropic.com"]);
  expect(JSON.stringify(parsed)).not.toContain(SECRET_KEY);
});

test("status:roxyAPIKey 一个字都不进报文,只剩「设过没设过」这一个事实", async () => {
  await writeConfigFile(JSON.stringify({ roxyAPIKey: SECRET_KEY, roxyWorkspaceID: 7 }));

  const result = await call("url-router.status");
  const parsed = UrlRouterStatusResultSchema.parse(result);

  expect(parsed.configSource).toBe("file");
  expect(parsed.config.roxyAPIKeyConfigured).toBe(true);
  // 断言的是"整份报文里搜不到它",而不是"某个字段没带它" —— 后者挡不住将来新加的字段。
  expect(JSON.stringify(result)).not.toContain(SECRET_KEY);
  expect(Object.keys(parsed.config)).not.toContain("roxyAPIKey");
});

test("status:两个 scheme 都是 com.a2.panel 才算接管(大小写不敏感 —— LaunchServices 存小写)", async () => {
  const takenOver = UrlRouterStatusResultSchema.parse(
    await call("url-router.status", {}, { handlers: fakeHandlers("com.a2.panel", "COM.A2.PANEL") }),
  );
  expect(takenOver.handler.matchesTarget).toBe(true);

  // 只接管了一半(http 是我们、https 还是 Safari)—— 那不叫接管。
  const half = UrlRouterStatusResultSchema.parse(
    await call("url-router.status", {}, { handlers: fakeHandlers("com.a2.panel", "com.apple.safari") }),
  );
  expect(half.handler.matchesTarget).toBe(false);

  // 有一个读不出来 → null(未能判定),**不是 false**:那两件事的下一步完全不同。
  const partial = UrlRouterStatusResultSchema.parse(
    await call("url-router.status", {}, { handlers: fakeHandlers("com.a2.panel", null) }),
  );
  expect(partial.handler.matchesTarget).toBeNull();
});

// MARK: - decide / route

test("decide:只判不开 —— 没命中分流域名时一个外部程序都不调", async () => {
  let ran = 0;
  const ports = fakePorts({
    async run() {
      ran += 1;
      return { exitCode: 0, stdout: "", stderr: "" };
    },
  });

  const parsed = UrlRouterDecideResultSchema.parse(
    await call("url-router.decide", { url: "https://example.com/x?q=1#f" }, { ports }),
  );

  expect(parsed.decision).toBe("fallback-browser");
  expect(parsed.url).toBe("https://example.com/x?redacted#redacted");
  expect(parsed.roxyDevToolsPort).toBeUndefined();
  // 域名没命中就不必知道 Roxy 在不在跑 —— 探测是有代价的(02 研究票实测 ps+lsof ≈ 40ms)。
  expect(ran).toBe(0);
});

test("decide:命中分流域名才去探端口;探到了就带上它(没探到绝不写 0)", async () => {
  const ports = fakePorts({
    async run(cmd) {
      if (cmd[0] === "/fake/ps") {
        return {
          exitCode: 0,
          stdout: " 4321 /Applications/RoxyBrowser.app/Contents/MacOS/RoxyBrowser --user-data-dir=/browser-cache/",
          stderr: "",
        };
      }
      return { exitCode: 0, stdout: "TCP 127.0.0.1:50325 (LISTEN)", stderr: "" };
    },
    async fetch(url) {
      if (url.includes("/json/version")) return new Response("Chrome/131");
      return new Response("dashboard.html?id=");
    },
  });

  const parsed = UrlRouterDecideResultSchema.parse(
    await call("url-router.decide", { url: "https://claude.ai/chat" }, { ports }),
  );

  expect(parsed.decision).toBe("roxy-cdp:50325");
  expect(parsed.roxyDevToolsPort).toBe(50325);
});

test("route:报文形状合契约,且 URL 原文只交给 open、脱敏那份才进报文", async () => {
  const argv: string[][] = [];
  const ports = fakePorts({
    async run(cmd) {
      argv.push([...cmd]);
      return { exitCode: 0, stdout: "", stderr: "" };
    },
  });

  const result = await call("url-router.route", { url: "https://example.com/a?t=秘密" }, { ports });
  const parsed = UrlRouterRouteResultSchema.parse(result);

  expect(parsed.action).toBe("fallback-browser");
  expect(parsed.target).toBe("com.apple.Safari");
  expect(parsed.fellBack).toBe(false);
  expect(argv[0]?.at(-1)).toBe("https://example.com/a?t=秘密");
  expect(JSON.stringify(result)).not.toContain("秘密");
});

test("route:open 没把链接交出去 → url_router_open_failed(退出码 5)+ 一条能自纠的指引", async () => {
  const ports = fakePorts({
    async run() {
      return { exitCode: 1, stdout: "", stderr: "LSCopyApplicationURLsForBundleIdentifier() failed" };
    },
  });

  const failure = call("url-router.route", { url: "https://example.com/a" }, { ports });

  await expect(failure).rejects.toBeInstanceOf(CapabilityFailedError);
  await failure.catch((error: CapabilityFailedError) => {
    expect(error.code).toBe(ErrorCode.urlRouterOpenFailed);
    // 「路走通了、事没办成」——参数一个字都不用改。
    expect(exitCodeForErrorCode(error.code)).toBe(5);
    expect(error.guidance?.steps.some((step) => step.command === "a2 url-router status --json")).toBe(true);
  });
});

// MARK: - takeover / restore:幂等判据

test("takeover:已经是 com.a2.panel → 幂等直通 already:true,**一个系统调用都不发**", async () => {
  let ran = 0;
  const ports = fakePorts({
    async run() {
      ran += 1;
      return { exitCode: 0, stdout: "", stderr: "" };
    },
  });

  const result = await call(
    "url-router.takeover",
    {},
    { ports, handlers: fakeHandlers("com.a2.panel", "com.a2.panel") },
  );
  const parsed = UrlRouterHandoffResultSchema.parse(result);

  expect(parsed).toEqual({
    target: A2_PANEL_BUNDLE_ID,
    already: true,
    handler: { http: "com.a2.panel", https: "com.a2.panel", matchesTarget: true },
  });
  expect(ran).toBe(0);
});

test("takeover:还不是目标 → url_router_executor_unwired(退出码 5),什么都没改", async () => {
  const failure = call(
    "url-router.takeover",
    {},
    { handlers: fakeHandlers("com.apple.safari", "com.apple.safari") },
  );

  await expect(failure).rejects.toBeInstanceOf(CapabilityFailedError);
  await failure.catch((error: CapabilityFailedError) => {
    expect(error.code).toBe(ErrorCode.urlRouterExecutorUnwired);
    expect(exitCodeForErrorCode(error.code)).toBe(5);
    expect(error.guidance?.context?.["target"]).toBe(A2_PANEL_BUNDLE_ID);
    // 指引必须给出人类此刻真能走的那条路(系统设置里手选),而不是"再试一次"。
    expect(JSON.stringify(error.guidance)).toContain("系统设置");
  });
});

test("takeover:handler 读不出来时按「不是目标」处理(fail-closed:绝不猜「大概已经是了」)", async () => {
  const failure = call("url-router.takeover", {}, { handlers: fakeHandlers(null, null) });

  await expect(failure).rejects.toBeInstanceOf(CapabilityFailedError);
  await failure.catch((error: CapabilityFailedError) => {
    expect(error.code).toBe(ErrorCode.urlRouterExecutorUnwired);
    expect(error.guidance?.context?.["http"]).toBe("(未能判定)");
  });
});

test("restore:目标缺省取配置里的兜底浏览器,`to` 可显式覆写", async () => {
  await writeConfigFile(JSON.stringify({ fallbackBrowserBundleID: "com.google.chrome" }));

  const byConfig = UrlRouterHandoffResultSchema.parse(
    await call("url-router.restore", {}, { handlers: fakeHandlers("com.google.chrome", "com.google.chrome") }),
  );
  expect(byConfig).toEqual({
    target: "com.google.chrome",
    already: true,
    handler: { http: "com.google.chrome", https: "com.google.chrome", matchesTarget: true },
  });

  const byOverride = UrlRouterHandoffResultSchema.parse(
    await call(
      "url-router.restore",
      { to: "org.mozilla.firefox" },
      { handlers: fakeHandlers("org.mozilla.firefox", "org.mozilla.firefox") },
    ),
  );
  expect(byOverride.target).toBe("org.mozilla.firefox");
});

test("restore:`to` 给了个空白串 → invalid_params(退出码 6),在读任何东西之前就拒", async () => {
  const failure = call("url-router.restore", { to: "   " });

  await failure.catch((error: CapabilityFailedError) => {
    expect(error.code).toBe(ErrorCode.invalidParams);
    expect(exitCodeForErrorCode(error.code)).toBe(6);
  });
  await expect(failure).rejects.toBeInstanceOf(CapabilityFailedError);
});

// MARK: - LaunchServices 那份 plist 的解析

/** `defaults export com.apple.LaunchServices/… -` 的形状(含**嵌套子字典**,裸切 `<dict>` 会切歪)。 */
const LS_PLIST = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>LSHandlers</key>
  <array>
    <dict>
      <key>LSHandlerContentType</key>
      <string>public.html</string>
      <key>LSHandlerRoleAll</key>
      <string>com.apple.safari</string>
    </dict>
    <dict>
      <key>LSHandlerPreferredVersions</key>
      <dict>
        <key>LSHandlerRoleAll</key>
        <string>-</string>
      </dict>
      <key>LSHandlerRoleAll</key>
      <string>com.google.chrome</string>
      <key>LSHandlerURLScheme</key>
      <string>http</string>
    </dict>
    <dict>
      <key>LSHandlerRoleAll</key>
      <string>com.a2.panel</string>
      <key>LSHandlerURLScheme</key>
      <string>https</string>
    </dict>
  </array>
  <key>LSHandlersAreCertUIDisabled</key>
  <false/>
</dict>
</plist>`;

test("plist 解析:嵌套子字典不会把条目切歪(LSHandlerPreferredVersions 里也有个 LSHandlerRoleAll)", () => {
  expect(parseLaunchServicesHandler(LS_PLIST, "http")).toBe("com.google.chrome");
  expect(parseLaunchServicesHandler(LS_PLIST, "https")).toBe("com.a2.panel");
});

test("plist 解析:没有对应条目就是 null(从没换过默认浏览器的机器就是这样,不是故障)", () => {
  const onlyContentTypes = LS_PLIST.replace(/<key>LSHandlerURLScheme<\/key>\s*<string>http<\/string>/, "");
  expect(parseLaunchServicesHandler(onlyContentTypes, "http")).toBeNull();
  expect(parseLaunchServicesHandler("", "http")).toBeNull();
  expect(parseLaunchServicesHandler("<plist><dict/></plist>", "https")).toBeNull();
});

test("plist 解析:同一个 scheme 有多条时取**最后一条**(LaunchServices 追加写,后写的才生效)", () => {
  const appended = LS_PLIST.replace(
    "</array>",
    `<dict>
      <key>LSHandlerRoleAll</key>
      <string>com.a2.panel</string>
      <key>LSHandlerURLScheme</key>
      <string>http</string>
    </dict>
  </array>`,
  );
  expect(parseLaunchServicesHandler(appended, "http")).toBe("com.a2.panel");
});
