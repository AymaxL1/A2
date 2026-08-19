// 自管配置渲染的**纯函数**面(07 票 CR 补)。
//
// 为什么这一族值得单独在函数缝上测(而不是只在 CLI 缝上验):`stripOwnedKeys` 与
// `findDocumentSeparator` 是「a2 还控不控得住那台 mihomo」的最后一道闸,而它们的失效**是静默的** ——
// 漏摘一个键,配置里就有两个 `external-controller`;漏掉一个 `---`,订阅整份失效而重载报"成功"。
// 这类 bug 在 CLI 缝上要靠"恰好构造出那种订阅"才撞得到,直接在函数缝上把边界写全更可靠。
// 端到端那一半仍在 `cli-subscriptions.test.ts`(两边都要有,不是二选一)。

import { expect, test } from "bun:test";
import {
  A2_OWNED_KEYS,
  defaultSettings,
  findDocumentSeparator,
  renderManagedConfig,
  stripOwnedKeys,
} from "../src/mihomo/config.ts";
import { mihomoLayout } from "../src/mihomo/paths.ts";

// MARK: - stripOwnedKeys

test("stripOwnedKeys:裸键、单引号键、双引号键**三种写法都摘**,记账用归一后的键名", () => {
  const body = [
    "proxies: []",
    "external-controller: 127.0.0.1:1",
    "'secret': 别人的钥匙",
    '"mixed-port": 1234',
    "rules:",
    "  - MATCH,DIRECT",
  ].join("\n");

  const { text, strippedKeys } = stripOwnedKeys(body);

  // 三条都没了 —— 只认裸键的话,加引号就能绕过摘除,与 a2 头部凑成重复键。
  expect(text).not.toContain("external-controller");
  expect(text).not.toContain("别人的钥匙");
  expect(text).not.toContain("1234");
  // 记的是归一后的键名(报文里出现 `'secret'` 与 `secret` 两条毫无意义)。
  expect(strippedKeys).toEqual(["external-controller", "secret", "mixed-port"]);
  // 不属于 a2 的原样留着。
  expect(text).toContain("proxies: []");
  expect(text).toContain("  - MATCH,DIRECT");
});

test("stripOwnedKeys:**不误伤前缀相同的键** —— port / secret-key / modeX 都留着", () => {
  const body = [
    "port: 7890",
    "socks-port: 7891",
    "secret-key: 留着",
    "modes: [a]",
    "log-levels: [x]",
    "mixed-port: 1234",
  ].join("\n");

  const { text, strippedKeys } = stripOwnedKeys(body);

  // 键名必须整段匹配到冒号,`port` 与 `mixed-port` 是两个不同的键。
  expect(text).toContain("port: 7890");
  expect(text).toContain("socks-port: 7891");
  expect(text).toContain("secret-key: 留着");
  expect(text).toContain("modes: [a]");
  expect(text).toContain("log-levels: [x]");
  expect(strippedKeys).toEqual(["mixed-port"]);
});

test("stripOwnedKeys:块标量(| 与 >)整段丢干净,不留半截孤儿正文", () => {
  const body = [
    "secret: |",
    "  第一行",
    "",
    "  第三行",
    "mode: >",
    "  折叠的",
    "  两行",
    "proxies: []",
  ].join("\n");

  const { text, strippedKeys } = stripOwnedKeys(body);

  expect(strippedKeys).toEqual(["secret", "mode"]);
  // 块标量的内容行(含中间那个空行)一条都没剩下 —— 剩下就是一段没有主人的 YAML。
  expect(text).not.toContain("第一行");
  expect(text).not.toContain("第三行");
  expect(text).not.toContain("折叠的");
  expect(text.trim()).toBe("proxies: []");
});

test("stripOwnedKeys:嵌套层里的同名键**不动**(a2 只拥有顶层)", () => {
  const body = [
    "proxy-providers:",
    "  机场甲:",
    "    secret: 这是人家 provider 的字段",
    "    mode: rule",
    "proxies: []",
  ].join("\n");

  const { text, strippedKeys } = stripOwnedKeys(body);

  expect(strippedKeys).toEqual([]);
  expect(text).toContain("secret: 这是人家 provider 的字段");
  expect(text).toContain("    mode: rule");
});

test("stripOwnedKeys:A2_OWNED_KEYS 里的每一个键都真的会被摘(表与实现不许脱节)", () => {
  for (const key of A2_OWNED_KEYS) {
    const { strippedKeys } = stripOwnedKeys(`${key}: 随便什么值\nproxies: []`);
    expect(strippedKeys).toEqual([key]);
  }
});

// MARK: - findDocumentSeparator

test("findDocumentSeparator:开头 / 中间的 `---` 与 `...` 都认得,给出行号", () => {
  expect(findDocumentSeparator("---\nproxies: []")).toEqual({ line: 1, text: "---" });
  expect(findDocumentSeparator("proxies: []\n---\nrules: []")).toEqual({ line: 2, text: "---" });
  expect(findDocumentSeparator("proxies: []\n...\n")).toEqual({ line: 2, text: "..." });
  // 文档开始标记后面可以跟内容(`--- !!map`),照样是分隔符。
  expect(findDocumentSeparator("a: 1\n--- !!map\nb: 2")?.line).toBe(2);
});

test("findDocumentSeparator:缩进过的 `---` 与字符串里的 `---` 都不算(不误报)", () => {
  expect(findDocumentSeparator("proxies: []\n  ---\nrules: []")).toBeUndefined();
  expect(findDocumentSeparator("name: a---b\nrules: []")).toBeUndefined();
  expect(findDocumentSeparator("note: |\n  ---\nrules: []")).toBeUndefined();
  // 三个以上的连字符不是分隔符(YAML 只认恰好三个)。
  expect(findDocumentSeparator("----\nrules: []")).toBeUndefined();
  expect(findDocumentSeparator("proxies: []\nrules: []")).toBeUndefined();
});

// MARK: - renderManagedConfig

test("renderManagedConfig:确定性(同输入必同字节)—— 幂等判定就靠这一条", () => {
  const layout = mihomoLayout({ home: "/tmp/x", runDir: "/tmp/x/run", socketPath: "/tmp/x/run/s" }, {});
  const input = {
    layout,
    secret: "k",
    settings: defaultSettings({}),
    subscription: { id: "sub-1", body: "proxies: []\nrules:\n  - MATCH,DIRECT" },
  };

  expect(renderManagedConfig(input).text).toBe(renderManagedConfig(input).text);
});

test("renderManagedConfig:a2 头部恒在最前,且**订阅赢不了头部里的任何一个键**", () => {
  const layout = mihomoLayout({ home: "/tmp/x", runDir: "/tmp/x/run", socketPath: "/tmp/x/run/s" }, {});
  const rendered = renderManagedConfig({
    layout,
    secret: "a2-的钥匙",
    settings: { mixedPort: 7897, allowLan: false, logLevel: "info", mode: "rule", managedMode: "embedded" },
    subscription: {
      id: "sub-1",
      body: ["'external-controller': 10.0.0.1:9090", '"secret": 别人的', "proxies: []"].join("\n"),
    },
  });

  expect(rendered.text).toContain(`external-controller: ${layout.controller}`);
  expect(rendered.text).toContain("secret: a2-的钥匙");
  expect(rendered.text).not.toContain("10.0.0.1:9090");
  expect(rendered.text).not.toContain("别人的");
  // 头部里每个键**恰好出现一次**:重复键会让 yaml.v3 直接拒掉整份配置。
  for (const key of A2_OWNED_KEYS) {
    const occurrences = rendered.text.split("\n").filter((line) => line.startsWith(`${key}:`));
    expect(occurrences.length).toBe(1);
  }
});
