// URL 分流的配置模块(施工 01 票):`<A2_HOME>/url-router.json` 的读取与缺省合并。
//
// 三件事在这儿钉死:
//   * **缺省即产品意图** —— 没有配置文件的机器照样分流,缺省表逐字对上 spec §8;
//   * **合并的粒度是字段** —— 只想改一行的人写一行就够;写歪了则整份退回缺省(不留半态),
//     并且说得出是哪一项歪了;
//   * **`roxyAPIKey` 一个字都不许漏出来** —— 出错文本、脱敏视图两条路各验一次。
//     这条纪律的测法是"把钥匙写进文件,再断言产物里搜不到它",而不是读一遍代码觉得没问题。
//
// 纪律:每条用例自带临时 A2_HOME(/tmp),绝不碰用户真实 `~/.a2`。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { resolvePaths } from "../src/runtime/paths.ts";
import {
  URL_ROUTER_CONFIG_NAME,
  defaultUrlRouterConfig,
  hasRoxyAPIConfig,
  loadUrlRouterConfig,
  redactUrlRouterConfig,
  urlRouterConfigPath,
  type UrlRouterConfigLoad,
} from "../src/url-router/config.ts";

/** 这台测试机上永远不会被读到的一把钥匙 —— 谁把它漏进报文,断言就该红。 */
const SECRET_KEY = "roxy-key-绝密-8f3a91";

let home: string;

beforeEach(async () => {
  home = await mkdtemp("/tmp/a2url-");
});

afterEach(async () => {
  await rm(home, { recursive: true, force: true });
});

/** 把一段原文写进那台 home 的 url-router.json(有意收原文而非对象:坏 JSON 也要写得进去)。 */
async function writeConfigFile(text: string): Promise<void> {
  await writeFile(path.join(home, URL_ROUTER_CONFIG_NAME), text, "utf8");
}

async function load(): Promise<UrlRouterConfigLoad> {
  return await loadUrlRouterConfig(resolvePaths({ A2_HOME: home }));
}

// MARK: - 落点

test("落点:`<A2_HOME>/url-router.json`,A2_HOME 覆写照旧", () => {
  expect(urlRouterConfigPath(resolvePaths({ A2_HOME: "/tmp/whatever" }))).toBe(
    "/tmp/whatever/url-router.json",
  );
});

// MARK: - 缺省

test("缺省表逐字对上 spec §8(兜底浏览器改名 + RoxyBrowser 的本机实况值)", () => {
  expect(defaultUrlRouterConfig()).toEqual({
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
  });
  // 母本那两个名字必须已经消失(改名不是加了个别名了事)。
  expect(defaultUrlRouterConfig()).not.toHaveProperty("defaultBrowserBundleID");
  expect(defaultUrlRouterConfig()).not.toHaveProperty("logPath");
});

test("缺省每次新造一份 —— 谁动了返回的域名表,都动不到下一次的缺省", () => {
  defaultUrlRouterConfig().routedDomains.push("evil.com");
  expect(defaultUrlRouterConfig().routedDomains).toEqual(["claude.ai", "claude.com", "anthropic.com"]);
});

test("无文件 = 全缺省,且这不是错(source=defaults,没有 problem)", async () => {
  const loaded = await load();
  expect(loaded.source).toBe("defaults");
  expect(loaded.problem).toBeUndefined();
  expect(loaded.config).toEqual(defaultUrlRouterConfig());
});

// MARK: - 合并

test("部分字段:只写一行也成立,其余逐项退回缺省", async () => {
  await writeConfigFile(JSON.stringify({ fallbackBrowserBundleID: "com.google.Chrome" }));

  const loaded = await load();

  expect(loaded.source).toBe("file");
  expect(loaded.config.fallbackBrowserBundleID).toBe("com.google.Chrome");
  expect(loaded.config).toEqual({
    ...defaultUrlRouterConfig(),
    fallbackBrowserBundleID: "com.google.Chrome",
  });
});

test("显式 null 与缺键同义:都退回缺省(母本 `??` 的语义)", async () => {
  await writeConfigFile(
    JSON.stringify({ fallbackBrowserBundleID: null, routedDomains: null, roxyForceOpen: null }),
  );

  const loaded = await load();

  expect(loaded.source).toBe("file");
  expect(loaded.config).toEqual(defaultUrlRouterConfig());
});

test("假值是用户写的值、不是「没写」:false / 0 / 空串 / 空表都原样留着", async () => {
  await writeConfigFile(
    JSON.stringify({
      routedDomains: [],
      roxyProfileID: "",
      roxyForceOpen: false,
      roxyStartupAttempts: 0,
      roxyStartupDelaySeconds: 0,
      roxyWorkspaceID: 0,
    }),
  );

  const loaded = await load();

  expect(loaded.source).toBe("file");
  // 空域名表 = "一条都不分流",是合法配置,不该被当成"没配"而退回三条缺省域名。
  expect(loaded.config.routedDomains).toEqual([]);
  expect(loaded.config.roxyForceOpen).toBe(false);
  expect(loaded.config.roxyStartupAttempts).toBe(0);
  expect(loaded.config.roxyStartupDelaySeconds).toBe(0);
  expect(loaded.config.roxyWorkspaceID).toBe(0);
});

test("不认识的键忽略(留注释键、留将来的字段,不是错)", async () => {
  await writeConfigFile(
    JSON.stringify({ "//": "这行是给人看的", futureField: 1, roxyProfileID: "p-1" }),
  );

  const loaded = await load();

  expect(loaded.source).toBe("file");
  expect(loaded.config.roxyProfileID).toBe("p-1");
  expect(loaded.config).not.toHaveProperty("futureField");
});

test("全表都写:每一项都能被覆写(表与实现不许脱节)", async () => {
  const full = {
    fallbackBrowserBundleID: "com.microsoft.edgemac",
    routedDomains: ["example.com"],
    roxyApplicationPath: "/Applications/别的.app",
    roxyProcessMatch: "/别的.app/Contents/MacOS/别的",
    roxyProfilePathMarker: "/cache/",
    roxyProfileID: "p-9",
    roxyAPIHost: "http://127.0.0.1:50000",
    roxyAPIOpenPath: "/open",
    roxyAPITokenHeader: "x-token",
    roxyAPIKey: SECRET_KEY,
    roxyWorkspaceID: 42,
    roxyForceOpen: true,
    roxyAPITimeoutSeconds: 1.5,
    roxyStartupAttempts: 3,
    roxyStartupDelaySeconds: 0.05,
  };
  await writeConfigFile(JSON.stringify(full));

  const loaded = await load();

  expect(loaded.source).toBe("file");
  expect(loaded.config).toEqual(full);
});

// MARK: - 文件用不了

test("坏 JSON = 整份退回缺省,并说得出毛病(source=unusable)", async () => {
  await writeConfigFile(`{"fallbackBrowserBundleID": "com.google.Chrome",`);

  const loaded = await load();

  expect(loaded.source).toBe("unusable");
  expect(loaded.problem).toContain("不是合法 JSON");
  expect(loaded.config).toEqual(defaultUrlRouterConfig());
});

test("顶层不是对象(数组 / 裸标量)= 用不了,不是「空配置」", async () => {
  for (const text of ["[1,2,3]", '"claude.ai"', "null", "42"]) {
    await writeConfigFile(text);
    const loaded = await load();
    expect(loaded.source).toBe("unusable");
    expect(loaded.problem).toContain("顶层");
    expect(loaded.config).toEqual(defaultUrlRouterConfig());
  }
});

test("字段类型不合契约 = 整份退回缺省,并**指名道姓**是哪几项", async () => {
  await writeConfigFile(
    JSON.stringify({
      fallbackBrowserBundleID: 42,
      routedDomains: "claude.ai",
      roxyStartupAttempts: 1.5,
    }),
  );

  const loaded = await load();

  expect(loaded.source).toBe("unusable");
  expect(loaded.problem).toContain("fallbackBrowserBundleID");
  expect(loaded.problem).toContain("routedDomains");
  expect(loaded.problem).toContain("roxyStartupAttempts");
  // 不留半态:写对的那些字段也不生效,整份就是缺省。
  expect(loaded.config).toEqual(defaultUrlRouterConfig());
});

test("空文件也是「用不了」(处置仍是全缺省,但 status 得说得出话)", async () => {
  await writeConfigFile("");

  const loaded = await load();

  expect(loaded.source).toBe("unusable");
  expect(loaded.config).toEqual(defaultUrlRouterConfig());
});

// MARK: - roxyAPIKey 敏感纪律

test("坏 JSON 的报错里**没有文件原文** —— 钥匙就在那半行里", async () => {
  // 解析器的错误消息会引用出错处附近的原文。这份文件里紧挨着语法错的就是那把钥匙。
  await writeConfigFile(`{"roxyAPIKey": "${SECRET_KEY}", "routedDomains": [ }`);

  const loaded = await load();

  expect(loaded.source).toBe("unusable");
  expect(JSON.stringify(loaded)).not.toContain(SECRET_KEY);
});

test("字段报错只报字段名,不报值", async () => {
  await writeConfigFile(JSON.stringify({ roxyAPIKey: SECRET_KEY, roxyWorkspaceID: SECRET_KEY }));

  const loaded = await load();

  expect(loaded.source).toBe("unusable");
  expect(loaded.problem).toContain("roxyWorkspaceID");
  expect(JSON.stringify(loaded)).not.toContain(SECRET_KEY);
});

test("脱敏视图:钥匙只剩「设过没设过」,值不出现在序列化结果里", async () => {
  await writeConfigFile(JSON.stringify({ roxyAPIKey: SECRET_KEY, roxyProfileID: "p-1" }));

  const loaded = await load();
  // 生效配置里当然有真值(执行侧要拿它发请求)——
  expect(loaded.config.roxyAPIKey).toBe(SECRET_KEY);
  // —— 但凡要说给别人听的,都过脱敏这一道。
  const redacted = redactUrlRouterConfig(loaded.config);
  expect(redacted.roxyAPIKeyConfigured).toBe(true);
  expect(redacted).not.toHaveProperty("roxyAPIKey");
  expect(JSON.stringify(redacted)).not.toContain(SECRET_KEY);
  // 其余字段一个不少地留着(脱敏不是删一半)。
  expect(redacted.roxyProfileID).toBe("p-1");
  expect(redacted.fallbackBrowserBundleID).toBe("com.apple.Safari");
});

test("脱敏视图:没设过 / 只写了空白 都是 configured=false", () => {
  expect(redactUrlRouterConfig(defaultUrlRouterConfig()).roxyAPIKeyConfigured).toBe(false);
  expect(
    redactUrlRouterConfig({ ...defaultUrlRouterConfig(), roxyAPIKey: "   " }).roxyAPIKeyConfigured,
  ).toBe(false);
});

// MARK: - API 配置齐备(降级判据的输入)

test("hasRoxyAPIConfig:host + key + workspaceID 三者齐备才算,空白串不算", () => {
  const ready = {
    ...defaultUrlRouterConfig(),
    roxyAPIHost: "http://127.0.0.1:50000",
    roxyAPIKey: SECRET_KEY,
    roxyWorkspaceID: 7,
  };
  expect(hasRoxyAPIConfig(ready)).toBe(true);
  expect(hasRoxyAPIConfig({ ...ready, roxyAPIHost: null })).toBe(false);
  expect(hasRoxyAPIConfig({ ...ready, roxyAPIKey: null })).toBe(false);
  expect(hasRoxyAPIConfig({ ...ready, roxyWorkspaceID: null })).toBe(false);
  expect(hasRoxyAPIConfig({ ...ready, roxyAPIHost: "  " })).toBe(false);
  expect(hasRoxyAPIConfig({ ...ready, roxyAPIKey: "\t" })).toBe(false);
  // workspaceID = 0 是**设过**,不是"没配"。
  expect(hasRoxyAPIConfig({ ...ready, roxyWorkspaceID: 0 })).toBe(true);
  expect(hasRoxyAPIConfig(defaultUrlRouterConfig())).toBe(false);
});
