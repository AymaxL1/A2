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
import { readCatalog, readSubscriptionBody } from "./subscriptions.ts";
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
    // rollback 自己不抛就说明"已经回到旧配置了",但这次操作仍然是失败的。
    await rollback(target, before, error);
    throw reloadFailure(target, error, true);
  }
}

/**
 * 回滚:把旧字节写回去,并**再让内核重载一次旧的**。
 * 写回失败时不发第二次 reload —— 内核此刻跑的就是旧配置,再 reload 只会把一次失败变成两次。
 */
async function rollback(
  target: ProxyTarget,
  before: string | undefined,
  cause: unknown,
): Promise<void> {
  if (before === undefined) return;
  try {
    await ensureConfig(target.layout, before);
  } catch (writeError) {
    throw reloadFailure(target, cause, false, `回滚写回旧配置也失败了:${String(writeError)}`);
  }
  await reloadConfig(target.controller, target.layout.configPath).catch(() => {});
}

function reloadFailure(
  target: ProxyTarget,
  cause: unknown,
  rolledBack: boolean,
  extra?: string,
): CapabilityFailedError {
  const detail =
    cause instanceof ControllerError ? cause.message : String(cause);
  return new CapabilityFailedError(
    rolledBack
      ? "内核拒绝重载新配置,已回滚到上一份配置。"
      : "内核拒绝重载新配置,且回滚未能完成。",
    `${detail}${extra ? `\n${extra}` : ""}`,
    {
      code: ErrorCode.proxyOperationFailed,
      guidance: {
        summary: rolledBack
          ? "内核仍在跑上一份配置。多半是新配置本身内核解析不了(订阅格式不对、字段非法)。"
          : "磁盘上的配置可能与内核里跑的那份不一致,先看清楚再动手。",
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
