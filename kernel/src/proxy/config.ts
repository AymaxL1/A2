// 自管配置的**编排**:可调项怎么存、期望内容怎么算、落盘与重载怎么做成一笔事务。
//
// 渲染本身在 `src/mihomo/config.ts`(纯函数);这里负责它的输入(settings + 激活订阅)与它的后果(写盘 + 重载)。
//
// **事务的形状**(旧实现用一次真事故换来的,原样继承):
//   写新的 → 让内核重载 → 重载失败就把旧字节写回去、再让内核重载一次旧的。
//   两条边界条件必须守住:
//     * 回滚的**写**也失败时,**不再发第二次 reload**(内核此刻跑的仍是旧配置,再 reload 一次没有意义,
//       只会把一次失败变成两次不明不白的失败);
//     * 重载失败时**状态不留半态** —— 磁盘上的配置与内核里跑的那份要么都是新的,要么都是旧的。

import { mkdir } from "node:fs/promises";
import path from "node:path";
import { CapabilityFailedError } from "../capability/registry.ts";
import { ErrorCode, ProxySettingsSchema, type ProxySettings } from "../contract/wire.ts";
import { ControllerError, reloadConfig } from "../mihomo/controller.ts";
import { defaultSettings, renderManagedConfig } from "../mihomo/config.ts";
import { currentSecret, ensureConfig } from "../mihomo/install.ts";
import type { MihomoLayout } from "../mihomo/paths.ts";
import { assertUsableBody, readCatalog, readSubscriptionBody } from "./subscriptions.ts";
import type { ProxyTarget } from "./endpoint.ts";

const DATA_DIR_MODE = 0o700;

// MARK: - 可调项

/**
 * 读可调项。**文件读不出来 / 不合契约就用默认值**(而不是报错):settings 是一份便利设置,
 * 不是用户攒的数据 —— 跟订阅清单那条「损坏就停手」是两种东西,处置也该不同。
 */
export async function readSettings(
  layout: MihomoLayout,
  env: Record<string, string | undefined> = process.env,
): Promise<ProxySettings> {
  const text = await Bun.file(layout.settingsPath)
    .text()
    .catch(() => undefined);
  if (text === undefined) return defaultSettings(env);
  try {
    const parsed = ProxySettingsSchema.safeParse(JSON.parse(text));
    return parsed.success ? parsed.data : defaultSettings(env);
  } catch {
    return defaultSettings(env);
  }
}

/** 写可调项(排序键 + 两空格缩进,确定性)。返回是否**本次**真改了(幂等的可观察面)。 */
export async function writeSettings(
  layout: MihomoLayout,
  settings: ProxySettings,
): Promise<boolean> {
  const wanted = `${JSON.stringify(orderedSettings(settings), null, 2)}\n`;
  const current = await Bun.file(layout.settingsPath)
    .text()
    .catch(() => undefined);
  if (current === wanted) return false;
  await mkdir(layout.dataDir, { recursive: true, mode: DATA_DIR_MODE });
  await Bun.write(layout.settingsPath, wanted);
  return true;
}

/** 键序固定 —— JSON.stringify 按插入序输出,这里把插入序钉死,免得两次写出字节不同的同一份设置。 */
function orderedSettings(settings: ProxySettings): ProxySettings {
  return {
    mixedPort: settings.mixedPort,
    allowLan: settings.allowLan,
    logLevel: settings.logLevel,
    mode: settings.mode,
    managedMode: settings.managedMode,
  };
}

// MARK: - 期望内容

export interface DesiredConfig {
  text: string;
  settings: ProxySettings;
  /** 当前激活的订阅 id(没有则 null)。 */
  activeSubscription: string | null;
  /** 订阅正文里被 a2 接管而摘掉的顶层键。 */
  strippedKeys: string[];
}

/**
 * 算出「此刻这份自管配置**应该**是什么内容」。
 * 激活订阅的正文读不到(文件被人删了)时,按**没有激活**渲染 —— 宁可回到直连骨架,
 * 也不要渲染出一份引用了不存在节点的配置。
 */
export async function resolveDesiredConfig(
  layout: MihomoLayout,
  env: Record<string, string | undefined> = process.env,
): Promise<DesiredConfig> {
  const settings = await readSettings(layout, env);
  const secret = await currentSecret(layout);
  const catalog = await readCatalog(layout);
  const activeId = catalog.activeId;
  const body = activeId ? await readSubscriptionBody(layout, activeId) : undefined;
  // 渲染之前的最后一道闸:正文若含 YAML 文档分隔符,拼出来的配置会让订阅整份静默失效。
  // add/update 落盘时已经查过一次,这里兜的是"有人在 a2 背后改了那个文件"。
  if (activeId && body !== undefined) assertUsableBody(body, `订阅 ${activeId} 的物化配置`);
  const rendered = renderManagedConfig({
    layout,
    secret,
    settings,
    ...(activeId && body !== undefined ? { subscription: { id: activeId, body } } : {}),
  });
  return {
    text: rendered.text,
    settings,
    activeSubscription: activeId && body !== undefined ? activeId : null,
    strippedKeys: rendered.strippedKeys,
  };
}

// MARK: - 事务

export interface ApplyOutcome {
  /** 磁盘上的配置本次有没有被改。 */
  written: boolean;
  /** 本次有没有真的让内核重载。 */
  reloaded: boolean;
}

/**
 * 把期望内容落盘,并在**确实改了**且控制面可达时让内核整份重载。
 *
 * 三条判据都是有意的:
 *   * **没改就不重载** —— 这就是幂等(「已经是激活项了,再激活一次」不该打扰内核);
 *   * **控制面不可达就只落盘**,并如实报告 `reloaded: false` —— 内核下次起来按 `-f` 读这份文件,
 *     不算丢事,但也绝不谎报"已生效";
 *   * 重载失败即回滚(见 `rollback`)。
 */
export async function applyManagedConfig(
  target: ProxyTarget,
  desired: DesiredConfig,
): Promise<ApplyOutcome> {
  const layout = target.layout;
  const before = await Bun.file(layout.configPath)
    .text()
    .catch(() => undefined);
  const written = await ensureConfig(layout, desired.text);
  if (!written) return { written: false, reloaded: false };
  if (!target.apiReachable) return { written, reloaded: false };

  try {
    await reloadConfig(target.controller, layout.configPath);
    return { written, reloaded: true };
  } catch (error) {
    // rollback 自己不抛就说明"该回滚的都回滚了";它返回**这次到底有没有旧配置可回滚**,
    // 因为那句话要原样出现在报文里 —— 说"已回滚"而实际没有可回滚的东西,是在骗读报文的人。
    const rolledBack = await rollback(target, before, error);
    throw reloadFailure(target, error, rolledBack ? "rolled_back" : "nothing_to_roll_back");
  }
}

/**
 * 回滚:把旧字节写回去,并**再让内核重载一次旧的**。返回本次是否真的回滚了。
 *
 * 两种"没回滚"要分清:
 *   * `before === undefined` —— 这次之前**根本没有配置文件**(第一次落盘就被内核拒了)。
 *     没有可回滚的东西,磁盘上留下的就是这次写的那一份;报文必须照实说,不能谎称"已回滚"。
 *   * 写回本身失败 —— 抛出去,并且**不发第二次 reload**:内核此刻跑的就是旧配置,
 *     再 reload 一次只会把一次失败变成两次不明不白的失败。
 */
async function rollback(
  target: ProxyTarget,
  before: string | undefined,
  cause: unknown,
): Promise<boolean> {
  if (before === undefined) return false;
  try {
    await ensureConfig(target.layout, before);
  } catch (writeError) {
    throw reloadFailure(
      target,
      cause,
      "rollback_failed",
      `回滚写回旧配置也失败了:${String(writeError)}`,
    );
  }
  await reloadConfig(target.controller, target.layout.configPath).catch(() => {});
  return true;
}

/** 重载失败的三种收场 —— 文案与实际发生的事一一对应,不共用一句含糊的话。 */
type RollbackOutcome = "rolled_back" | "nothing_to_roll_back" | "rollback_failed";

const ROLLBACK_MESSAGE: Record<RollbackOutcome, string> = {
  rolled_back: "内核拒绝重载新配置,已回滚到上一份配置。",
  nothing_to_roll_back:
    "内核拒绝重载新配置;这之前没有旧配置可回滚,磁盘上留下的是这次写的那一份。",
  rollback_failed: "内核拒绝重载新配置,且回滚未能完成。",
};

const ROLLBACK_SUMMARY: Record<RollbackOutcome, string> = {
  rolled_back: "内核仍在跑上一份配置。多半是新配置本身内核解析不了(订阅格式不对、字段非法)。",
  nothing_to_roll_back:
    "内核跑的还是它启动时那份配置。磁盘上这份是新写的、内核不认 —— 先看它错在哪,再决定改还是删。",
  rollback_failed: "磁盘上的配置可能与内核里跑的那份不一致,先看清楚再动手。",
};

function reloadFailure(
  target: ProxyTarget,
  cause: unknown,
  outcome: RollbackOutcome,
  extra?: string,
): CapabilityFailedError {
  const detail =
    cause instanceof ControllerError ? cause.message : String(cause);
  return new CapabilityFailedError(
    ROLLBACK_MESSAGE[outcome],
    `${detail}${extra ? `\n${extra}` : ""}`,
    {
      code: ErrorCode.proxyOperationFailed,
      guidance: {
        summary: ROLLBACK_SUMMARY[outcome],
        steps: [
          { description: "看那份自管配置", command: `cat ${target.layout.configPath}` },
          {
            description: "看 mihomo 的错误日志",
            command: `tail -n 50 ${path.join(path.dirname(target.layout.dataDir), "log", "mihomo.err.log")}`,
          },
          { description: "确认当前实况", command: "a2 proxy status --json" },
        ],
        context: { configPath: target.layout.configPath, controller: target.endpoint.controller },
      },
    },
  );
}
