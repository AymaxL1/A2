// 订阅:清单、物化配置、拉取。**只管存与取,不管内核** —— 让内核重载是 `./config.ts` 的事。
//
// 落点(全在 a2 自己 home 里):
//   * `<home>/mihomo/subscriptions/catalog.json` —— 清单(有哪些订阅、哪条是激活的);
//   * `<home>/mihomo/subscriptions/configs/<id>.conf` —— 每条订阅拉到的**原始字节**(不解析、不改写)。
//
// 三条从旧实现原样继承的硬性质(它们各自修过一个真事故):
//   1. **id 由名字确定性派生**(FNV-1a 32 位):同名(大小写不敏感)→ 同 id ⇒ 「同名再 add = 换源」
//      是天然语义,不需要额外的 upsert 分支。刻意不用运行时哈希(那玩意每进程一个种子,
//      重启后同一个名字会算出不同 id)。纯非 ASCII 名也不会塌成同一个 id(哈希后缀兜底)。
//   2. **清单文件损坏就拒绝一切读写**(不当成空清单)。把用户攒了半年的订阅当成"空的"然后覆盖掉,
//      是这一族代码最容易犯、后果最不可逆的错。
//   3. **失败不留痕**:拉取失败/内容为空时,配置文件与清单都不动。

import { mkdir, rename, rm, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import type { Subscription } from "../contract/wire.ts";
import { findDocumentSeparator } from "../mihomo/config.ts";
import type { MihomoLayout } from "../mihomo/paths.ts";

const DIR_MODE = 0o700;
const FILE_MODE = 0o600;

/** 订阅体的大小上限(与旧实现同口径 10 MiB):机场配置再大也到不了这个量级。 */
export const SUBSCRIPTION_MAX_BYTES = 10 * 1024 * 1024;
/** 拉取超时(秒);旧实现同值。 */
export const SUBSCRIPTION_FETCH_TIMEOUT_MS = 15_000;

/** 清单落盘形状。`activeId` 为 null = 一条都没激活(合法状态,不是错误)。 */
export interface SubscriptionCatalog {
  subscriptions: Subscription[];
  activeId: string | null;
}

/** 这一层的可预期失败。上层翻成 `subscription_failed`(退出码 5)。 */
export class SubscriptionError extends Error {
  constructor(
    message: string,
    readonly detail?: string,
  ) {
    super(message);
    this.name = "SubscriptionError";
  }
}

/** 清单文件坏了 —— 单独一个类型,因为它的处置是**停手**,不是重试。 */
export class CatalogCorruptError extends SubscriptionError {
  constructor(readonly catalogPath: string, detail: string) {
    super("订阅清单文件损坏,已拒绝读写以免覆盖既有数据。", detail);
    this.name = "CatalogCorruptError";
  }
}

/**
 * 订阅正文本身 a2 用不了 —— 单独一个类型,因为它的处置是**告诉人第几行**,不是重试也不是替他改。
 * 目前唯一的成因是 YAML 文档分隔符(见 `mihomo/config.ts::findDocumentSeparator` 的长注释)。
 */
export class SubscriptionBodyError extends SubscriptionError {
  constructor(
    message: string,
    detail: string,
    readonly line: number,
  ) {
    super(message, detail);
    this.name = "SubscriptionBodyError";
  }
}

/**
 * 订阅正文能不能被 a2 拼进自管配置。**在落盘之前、在渲染之前**各查一次:
 * 前者拦住"坏东西进不了库",后者兜住"有人在 a2 背后改了那个文件"。
 */
export function assertUsableBody(body: string, origin: string): void {
  const separator = findDocumentSeparator(body);
  if (!separator) return;
  throw new SubscriptionBodyError(
    `这份订阅里有 YAML 文档分隔符(第 ${separator.line} 行 ${JSON.stringify(separator.text)}),a2 无法把它拼进自管配置。`,
    `a2 的自管配置是「a2 头部 + 订阅正文」拼成的**一份**文档;正文里有 ${JSON.stringify(separator.text.trim())} ` +
      `就成了多文档流,而 mihomo 只读第一个文档 —— 也就是只剩 a2 那几行头部。` +
      `重载会"成功",但这份订阅的节点与规则会整份静默失效。来源:${origin}`,
    separator.line,
  );
}

// MARK: - id

/**
 * FNV-1a 32 位。**刻意手写**:内建哈希(以及 JS 里任何 `Math.random` 味道的东西)都不保证跨进程稳定,
 * 而 id 是用户与 agent 的调用坐标,必须"同一个名字永远算出同一个 id"。
 */
export function fnv1a32(text: string): number {
  let hash = 0x811c_9dc5;
  for (const byte of new TextEncoder().encode(text)) {
    hash ^= byte;
    hash = Math.imul(hash, 0x0100_0193) >>> 0;
  }
  return hash >>> 0;
}

/**
 * 名字 → id。形如 `<slug>-<8 位十六进制>`;slug 抠不出来(纯非 ASCII 名)时只留哈希。
 * 空/纯空白名返回 undefined —— 调用方据此在**任何 I/O 之前**拒掉。
 */
export function subscriptionId(name: string): string | undefined {
  const trimmed = name.trim();
  if (trimmed.length === 0) return undefined;
  const lowered = trimmed.toLowerCase();
  const slug = lowered
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  const hash = fnv1a32(lowered).toString(16).padStart(8, "0");
  return slug.length > 0 ? `${slug}-${hash}` : hash;
}

// MARK: - 清单

export async function readCatalog(layout: MihomoLayout): Promise<SubscriptionCatalog> {
  const text = await Bun.file(layout.catalogPath)
    .text()
    .catch(() => undefined);
  if (text === undefined) return { subscriptions: [], activeId: null };

  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    throw new CatalogCorruptError(layout.catalogPath, `解析失败:${String(error)}`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new CatalogCorruptError(layout.catalogPath, "顶层不是 JSON 对象。");
  }
  const record = parsed as Record<string, unknown>;
  if (!Array.isArray(record["subscriptions"])) {
    throw new CatalogCorruptError(layout.catalogPath, "缺少 subscriptions 数组。");
  }
  const subscriptions: Subscription[] = [];
  for (const entry of record["subscriptions"] as unknown[]) {
    if (typeof entry !== "object" || entry === null) {
      throw new CatalogCorruptError(layout.catalogPath, "subscriptions 里有非对象条目。");
    }
    const item = entry as Record<string, unknown>;
    if (typeof item["id"] !== "string" || typeof item["name"] !== "string" || typeof item["source"] !== "string") {
      throw new CatalogCorruptError(layout.catalogPath, "订阅条目缺少 id/name/source。");
    }
    subscriptions.push({
      id: item["id"],
      name: item["name"],
      source: item["source"],
      ...(typeof item["lastUpdatedAt"] === "string" ? { lastUpdatedAt: item["lastUpdatedAt"] } : {}),
      ...(typeof item["bytes"] === "number" ? { bytes: item["bytes"] } : {}),
    });
  }
  const activeId = record["activeId"];
  return {
    subscriptions,
    activeId: typeof activeId === "string" && activeId.length > 0 ? activeId : null,
  };
}

/** 写清单。**排序键 + 两空格缩进**:确定性输出,人读得懂、diff 看得清。 */
export async function writeCatalog(
  layout: MihomoLayout,
  catalog: SubscriptionCatalog,
): Promise<void> {
  await mkdir(layout.subscriptionsDir, { recursive: true, mode: DIR_MODE });
  const ordered = {
    activeId: catalog.activeId,
    subscriptions: [...catalog.subscriptions].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)),
  };
  await writeAtomically(layout.catalogPath, `${JSON.stringify(ordered, null, 2)}\n`);
}

// MARK: - 物化配置

export function subscriptionConfigPath(layout: MihomoLayout, id: string): string {
  return path.join(layout.subscriptionConfigDir, `${id}.conf`);
}

export async function readSubscriptionBody(
  layout: MihomoLayout,
  id: string,
): Promise<string | undefined> {
  return await Bun.file(subscriptionConfigPath(layout, id))
    .text()
    .catch(() => undefined);
}

export async function writeSubscriptionBody(
  layout: MihomoLayout,
  id: string,
  body: string,
): Promise<void> {
  await mkdir(layout.subscriptionConfigDir, { recursive: true, mode: DIR_MODE });
  await writeAtomically(subscriptionConfigPath(layout, id), body);
}

export async function removeSubscriptionBody(layout: MihomoLayout, id: string): Promise<void> {
  await unlink(subscriptionConfigPath(layout, id)).catch(() => {});
}

// MARK: - 拉取

/** 拉一个订阅源。**可注入**:测试给一个纯内存的假件,门禁里一个字节都不出网。 */
export type SubscriptionFetcher = (source: string) => Promise<string>;

/**
 * 真实现:`file://` / 绝对路径读盘,`http(s)://` 走一次 GET。
 *
 * 三条与旧实现同口径的性质:**禁缓存**(订阅就是要拿最新的)、**大小上限**、**非 2xx 即失败**。
 * 另加一条旧实现没有的:**只认 file/http/https 三种 scheme** —— 别的(`ftp:`、`data:`……)当场拒掉,
 * 而不是交给 fetch 去猜。
 */
export async function fetchSubscription(source: string): Promise<string> {
  const trimmed = source.trim();
  if (trimmed.length === 0) throw new SubscriptionError("订阅源为空。");

  if (trimmed.startsWith("/") || trimmed.startsWith("file://")) {
    const file = trimmed.startsWith("file://")
      ? decodeURIComponent(trimmed.slice("file://".length))
      : trimmed;
    const text = await Bun.file(file)
      .text()
      .catch((error: unknown) => {
        throw new SubscriptionError(`读不到订阅源文件:${file}`, String(error));
      });
    return guardSize(text, file);
  }

  if (!trimmed.startsWith("http://") && !trimmed.startsWith("https://")) {
    throw new SubscriptionError(
      `不认识的订阅源:${trimmed}`,
      "只支持 http(s):// 与 file://(或绝对路径)。",
    );
  }

  let response: Response;
  try {
    response = await fetch(trimmed, {
      // 订阅要的就是"最新的那一份",缓存在这里只会带来说不清的陈旧。
      cache: "no-store",
      signal: AbortSignal.timeout(SUBSCRIPTION_FETCH_TIMEOUT_MS),
    });
  } catch (error) {
    throw new SubscriptionError(`拉取订阅源失败:${trimmed}`, String(error));
  }
  if (!response.ok) {
    throw new SubscriptionError(`拉取订阅源失败:${trimmed}`, `HTTP ${response.status}`);
  }
  return guardSize(await response.text(), trimmed);
}

function guardSize(text: string, origin: string): string {
  const bytes = new TextEncoder().encode(text).byteLength;
  if (bytes > SUBSCRIPTION_MAX_BYTES) {
    throw new SubscriptionError(
      `订阅内容超过上限(${SUBSCRIPTION_MAX_BYTES} 字节)。`,
      `${origin} 返回 ${bytes} 字节。`,
    );
  }
  if (text.trim().length === 0) {
    throw new SubscriptionError("订阅内容为空,已拒绝落盘。", `来源:${origin}`);
  }
  return text;
}

// MARK: - 原子写

/** 先写临时文件再改名:中途失败也不会留下一个"看起来写好了"的半截文件。 */
async function writeAtomically(target: string, content: string): Promise<void> {
  const staging = path.join(path.dirname(target), `.${path.basename(target)}.tmp-${process.pid}`);
  await writeFile(staging, content, { mode: FILE_MODE });
  try {
    await rename(staging, target);
  } catch (error) {
    await rm(staging, { force: true });
    throw error;
  }
}
