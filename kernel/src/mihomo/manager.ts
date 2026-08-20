// `a2 mihomo status|enable|disable|restart` 的实体(14 票 / ADR 0014 重写)。
//
// 深模块的边界不变:调用方(CLI)只拿到一个 `OpOutcome`。检测、模式落盘、下载校验、
// 头部收敛、旧 unit 迁移与全部指引都在这一层里消化掉。
//
// **本文件里没有任何一条代码路径会去停/重启/杀/配置一个不属于 a2 的 mihomo。** 这不是靠自觉:
//   * 唯一的进程动作面是 `child.ts`,它只认"认尸文件里验明是 a2 自己拉起的那一个";
//   * 唯一的 supervisor 动作是拆**旧版 a2 自己装的** `com.a2.mihomo`(label 钉死在 plan 里);
//   * 对别人的实例只有 `controller.ts` 的只读 GET,产物只进 `foreign` 报告面与 guidance。
//
// 三值托管模式是**用户显式裁定、一次性落盘**的配置(`settings.json` 的 `managedMode`):
// daemon 每次启动照它办事,检测结果只进报告面、**永不**自动改模式。
//
// **08 票临时闸(2026-08-21 用户裁定)**:检测面临时停用 —— `statusResult` 里 `collectForeignFacts`
// 的调用点被注释,`foreign` 恒空,`observe` 的入口在 CLI 参数层拒绝。代码全部保留待修,
// 上面那几条红线的措辞因此暂时描述的是一条**没在跑**的路径(理由与解闸办法见调用点的注释)。

import { stat } from "node:fs/promises";
import {
  ErrorCode,
  opFailure,
  opSuccess,
  type Guidance,
  type MihomoAction,
  type MihomoChangeResult,
  type MihomoEmbedded,
  type MihomoForeign,
  type MihomoManagedMode,
  type MihomoStatusResult,
  type OpOutcome,
  type ProxySettings,
} from "../contract/wire.ts";
import { readSettings, writeSettings } from "../proxy/config.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { removeUnit } from "../service/converge.ts";
import { createSupervisor, SupervisorCommandError } from "../service/supervisor.ts";
import { legacyMihomoRemovalPlan, resolveSupervisorKind, MIHOMO_STDERR_LOG_NAME, LOG_DIR_NAME } from "../service/unit.ts";
import path from "node:path";
import { childSnapshot, type ChildSnapshot } from "./child.ts";
import { configHasProxies, DEFAULT_BODY, ensureOwnedHeader } from "./config.ts";
import { probeCapabilities, probeController } from "./controller.ts";
// `collectForeignFacts` 目前只被 statusResult 里那行**注释掉的**调用点引用(08 票临时闸:
// 检测面停用、代码保留待修)。留着这条 import 是有意的 —— 解闸只需解开那一行注释。
import { binaryVersion, collectForeignFacts, type ForeignFacts } from "./detect.ts";
import { currentSecret, downloadLockedBinary, ensureDataDir, MihomoOperationError } from "./install.ts";
import { mihomoLayout, readSecretOf, resolveScanInputs, type MihomoLayout } from "./paths.ts";
import { compareVersions, MIHOMO_LOCKED_VERSION } from "./pin.ts";

interface MihomoContext {
  paths: KernelPaths;
  layout: MihomoLayout;
  env: Record<string, string | undefined>;
}

// MARK: - 三条命令的实体

export async function mihomoStatus(paths: KernelPaths): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => opSuccess(await statusResult(ctx)));
}

export async function mihomoEnable(paths: KernelPaths, mode: MihomoManagedMode): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => {
    const actions: MihomoAction[] = [];
    // 建目录要在写 settings 之前看现状:writeSettings 自己也会 mkdir,晚了就问不出「这次是不是我建的」。
    if (mode === "embedded" && (await ensureDataDir(ctx.layout))) actions.push("data_dir_created");
    const settings = await readSettings(ctx.layout, ctx.env);
    if (settings.managedMode !== mode) {
      await writeSettings(ctx.layout, { ...settings, managedMode: mode });
      actions.push("mode_set");
    }

    if (mode === "embedded") {
      actions.push(...(await provisionEmbedded(ctx, { ...settings, managedMode: mode })));
      actions.push(...(await removeLegacyUnit(ctx)));
    }

    const status = await statusResult(ctx);
    const result: MihomoChangeResult = { status, actions };
    return opSuccess(result);
  });
}

export async function mihomoDisable(paths: KernelPaths): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => {
    const actions: MihomoAction[] = [];
    const settings = await readSettings(ctx.layout, ctx.env);
    if (settings.managedMode !== "off") {
      await writeSettings(ctx.layout, { ...settings, managedMode: "off" });
      actions.push("mode_set");
    }
    const status = await statusResult(ctx);
    const result: MihomoChangeResult = { status, actions };
    return opSuccess(result);
  });
}

// MARK: - daemon 侧的两条内部命令(`mihomo.apply` / `mihomo.restart` 的实体)

/**
 * 按落盘的托管模式收敛内嵌子进程:embedded → 确保在跑(故障态不硬闯);其余 → 确保停了。
 * daemon 启动、以及 CLI enable/disable 落盘后的"立即照办"都走这一条。
 */
export async function mihomoApplyOp(
  paths: KernelPaths,
  child: import("./child.ts").MihomoChild,
): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => {
    const actions: MihomoAction[] = [];
    const settings = await readSettings(ctx.layout, ctx.env);
    if (settings.managedMode === "embedded") {
      // **拉起前对表**(spec §2 / ADR 0014 D6,CR 补):「升级随 a2 走」的另一半在这里 ——
      // a2 升级后锁定版变了,daemon 首次 apply 就把二进制换到锁定版,不等人重跑 enable。
      // 无二进制同样在此补齐(enable 落盘后下载失败的半启用态,自愈的唯一机会就是 apply)。
      actions.push(...(await ensureBinaryCurrent(ctx)));
      if (await child.start()) actions.push("child_started");
    } else if (await child.stop()) {
      actions.push("child_stopped");
    }
    const status = await statusResult(ctx);
    const result: MihomoChangeResult = { status, actions };
    return opSuccess(result);
  });
}

/** 显式重启内嵌子进程(故障计数清零)。只在 embedded 模式下有意义。 */
export async function mihomoRestartOp(
  paths: KernelPaths,
  child: import("./child.ts").MihomoChild,
): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => {
    const settings = await readSettings(ctx.layout, ctx.env);
    if (settings.managedMode !== "embedded") {
      return opFailure({
        code: ErrorCode.mihomoNotEnabled,
        message: "内置代理内核未启用,没有可重启的子进程。",
        detail: `当前托管模式:${settings.managedMode}。restart 只作用于 embedded 模式的内置子进程。`,
        guidance: {
          summary: "先与用户确认启用内置代理内核,再重启才有对象。",
          steps: [
            { description: "看本机现状与两种模式的说明", command: "a2 mihomo status --json" },
            { description: "与用户确认后启用内置代理内核", command: "a2 mihomo enable --mode=embedded --json" },
          ],
          context: { mode: settings.managedMode },
        },
      });
    }
    const wasRunning = await child.restart();
    const actions: MihomoAction[] = wasRunning ? ["child_stopped", "child_started"] : ["child_started"];
    const status = await statusResult(ctx);
    const result: MihomoChangeResult = { status, actions };
    return opSuccess(result);
  });
}

// MARK: - embedded 的就位(下载/升级、数据目录、头部收敛)

/**
 * 让 embedded 的三样东西就位:数据目录、配置(**只钉头部,正文归用户与 agent**)、锁定版二进制。
 * 「升级随 a2 走」的落点就在这里:盘上版本 ≠ 锁定版(或问不出来)→ 换成锁定版,没有独立的 upgrade 命令。
 */
async function provisionEmbedded(ctx: MihomoContext, settings: ProxySettings): Promise<MihomoAction[]> {
  const actions: MihomoAction[] = [];
  const secret = await currentSecret(ctx.layout);
  const current = await Bun.file(ctx.layout.configPath)
    .text()
    .catch(() => undefined);
  const base = current ?? `${DEFAULT_BODY}\n`;
  const converged = ensureOwnedHeader(base, { layout: ctx.layout, secret, settings });
  if (current === undefined || converged.changed) {
    await Bun.write(ctx.layout.configPath, converged.text.endsWith("\n") ? converged.text : `${converged.text}\n`);
    actions.push("config_written");
  }
  actions.push(...(await ensureBinaryCurrent(ctx)));
  return actions;
}

/**
 * 二进制对表:无 → 下载;版本 ≠ 锁定版(或问不出来)→ 换成锁定版。
 * enable 与 daemon 的 apply **共用这一条**(spec §2:embedded 拉起前对表),
 * 「升级随 a2 走」才不至于停在"重跑 enable 的人才享有"。
 */
async function ensureBinaryCurrent(ctx: MihomoContext): Promise<MihomoAction[]> {
  const onDisk = await fileExists(ctx.layout.binaryPath);
  if (!onDisk) {
    await downloadLockedBinary(ctx.layout, ctx.env);
    return ["binary_downloaded"];
  }
  const version = await binaryVersion(ctx.layout.binaryPath);
  if (!version || compareVersions(version, MIHOMO_LOCKED_VERSION) !== 0) {
    await downloadLockedBinary(ctx.layout, ctx.env);
    return ["binary_upgraded"];
  }
  return [];
}

/**
 * 旧版 a2 自装的 `com.a2.mihomo` unit:检出即拆(bootout + 删 plist)。**自己的遗产自己收** ——
 * 这是全内核唯一主动拆 unit 的迁移路径,label 钉死,别人的 unit 在任何分支下都进不来。
 */
async function removeLegacyUnit(ctx: MihomoContext): Promise<MihomoAction[]> {
  const plan = legacyPlan(ctx);
  if (!plan) return [];
  if (!(await fileExists(plan.unitPath))) return [];
  await removeUnit(plan, createSupervisor(plan));
  return ["legacy_unit_removed"];
}

function legacyPlan(ctx: MihomoContext) {
  const choice = resolveSupervisorKind();
  if (!choice.ok) return undefined;
  return legacyMihomoRemovalPlan(choice.kind, ctx.paths, {
    binaryPath: ctx.layout.binaryPath,
    dataDir: ctx.layout.dataDir,
    configPath: ctx.layout.configPath,
  });
}

// MARK: - status 拼装

async function statusResult(ctx: MihomoContext): Promise<MihomoStatusResult> {
  const settings = await readSettings(ctx.layout, ctx.env);
  const mode = settings.managedMode;

  const [snapshot, configText] = await Promise.all([
    childSnapshot(ctx.layout),
    // 08 票临时闸(2026-08-21 用户裁定):**检测面停用,代码保留待修** —— 下面这行是唯一的入口,
    // 注释掉它,`foreign` 从此恒为 undefined。真因不是实现 bug,是检测设计的可见性天花板:
    // a2 唯一的证据源是「配置里写了 external-controller」(红线不许扫进程表/launchd),
    // 于是一个没开控制端点的实例**天然不可见** —— 真机上用户明明跑着 mihomo,却只能得到场景 A。
    // 修它要改设计,而小白主流程等不起。detect.ts / controller.ts 与它们的单测原样保留、照常绿;
    // guidance 的 B/E 两支自然休眠(见下)。修好之后解开这行即可(详见 .scratch/mihomo-embedded/issues/08)。
    // collectForeignFacts(resolveScanInputs(ctx.env), ctx.layout.binDir),
    Bun.file(ctx.layout.configPath)
      .text()
      .catch(() => undefined),
  ]);

  const version = (await fileExists(ctx.layout.binaryPath))
    ? await binaryVersion(ctx.layout.binaryPath)
    : undefined;
  const secret = await readSecretOf(ctx.layout.configPath);
  const probe =
    snapshot.state === "running" ? await probeController(ctx.layout.controller, secret) : undefined;

  const embedded: MihomoEmbedded = {
    state: snapshot.state,
    ...(snapshot.pid !== undefined ? { pid: snapshot.pid } : {}),
    binaryPath: ctx.layout.binaryPath,
    ...(version ? { binaryVersion: version } : {}),
    lockedVersion: MIHOMO_LOCKED_VERSION,
    configPath: ctx.layout.configPath,
    dataDir: ctx.layout.dataDir,
    controller: ctx.layout.controller,
    controllerReachable: probe?.reachable ?? false,
    hasProxies: configText !== undefined && configHasProxies(configText),
    restartCount: snapshot.restartCount,
    ...(snapshot.lastError ? { lastError: snapshot.lastError } : {}),
  };

  // 检测停用期间恒空(08 票临时闸)。字段在契约里仍是 optional,报文形状一个字节没改 ——
  // 变的只是「本内核此刻答不答得出外来实例」,而它现在诚实地答"不知道"。
  const foreign: MihomoForeign | undefined = undefined; // = foreignResult(foreignFacts);
  const legacy = await legacyUnitPresent(ctx);

  const guidance = guidanceFor({ mode, embedded, foreign, legacy, hasProxies: embedded.hasProxies });
  return {
    mode,
    embedded,
    ...(foreign ? { foreign } : {}),
    ...(legacy ? { legacyUnit: true } : {}),
    ...(guidance ? { guidance } : {}),
    home: ctx.paths.home,
  };
}

/** 检测事实 → 报文的外来实例面。**08 票起休眠**(唯一调用点在 statusResult 里被注释掉),解闸即复用。 */
function foreignResult(facts: ForeignFacts): MihomoForeign | undefined {
  const instance = facts.instance
    ? {
        controller: facts.instance.target,
        address: facts.instance.address,
        secretConfigured: facts.instance.secret !== undefined,
        ...(facts.instance.configFile ? { configFile: facts.instance.configFile } : {}),
        reachable: facts.instance.probe.reachable,
        ...(facts.instance.probe.version ? { version: facts.instance.probe.version } : {}),
        capabilities: probeCapabilities(facts.instance.probe),
      }
    : undefined;
  const result: MihomoForeign = {
    ...(facts.binary ? { binary: facts.binary } : {}),
    ...(instance ? { instance } : {}),
    ...(facts.skipped ? { skippedController: facts.skipped.address } : {}),
  };
  return Object.keys(result).length > 0 ? result : undefined;
}

async function legacyUnitPresent(ctx: MihomoContext): Promise<boolean> {
  const plan = legacyPlan(ctx);
  return plan !== undefined && (await fileExists(plan.unitPath));
}

// MARK: - guidance 六态(05 票逐字定稿;第一读者是 agent,人以第三人称出现)

interface GuidanceInput {
  mode: MihomoManagedMode;
  embedded: MihomoEmbedded;
  foreign?: MihomoForeign;
  legacy: boolean;
  hasProxies: boolean;
}

/**
 * 态的优先序(一次只给一段,agent 不该同时收到两种"下一步"):
 * C(embedded 故障)> G(embedded 没在跑)> B(off·有外来)> A(off·无外来)>
 * D(observe 读不到 controller)> F(embedded 跑着但没节点)> E(并跑提醒)。
 * G 不在 05 票的六态里 —— 它是「enable 落了盘但 daemon 还没把孩子拉起来」这个真实处境的补位。
 *
 * **08 票临时闸**:`foreign` 恒空之后,B(off·有外来)与 E(并跑提醒)两支**永不再命中** ——
 * 代码原样留着(它们本身没错,错的是喂给它们的检测),off 态从此恒落 A,并跑提醒暂时消失。
 */
function guidanceFor(input: GuidanceInput): Guidance | undefined {
  const { mode, embedded, foreign, legacy, hasProxies } = input;
  const legacyStep = legacy
    ? [
        {
          description:
            "检测到旧版 A2 的 mihomo 服务(com.a2.mihomo),启用 embedded 时会自动移除(审计留痕),无需手工处理。",
        },
      ]
    : [];

  if (mode === "embedded" && embedded.state === "failed") {
    return {
      summary:
        `内置 mihomo 连续 ${embedded.restartCount} 次启动失败,A2 已暂停重拉。最近一次错误输出附在 ` +
        "result.embedded.lastError(原文)。常见原因:配置 YAML 语法错误、端口被占用。",
      steps: [
        {
          description: `检查配置文件(路径 ${embedded.configPath}),对照 lastError 修复`,
        },
        { description: "修好后重启内置内核", command: "a2 mihomo restart --json" },
      ],
      context: { configPath: embedded.configPath, lockedVersion: embedded.lockedVersion },
    };
  }

  if (mode === "embedded" && embedded.state === "stopped" && embedded.binaryVersion === undefined) {
    // 半启用态(enable 落盘后下载失败/二进制被删):真因是二进制缺位,别把人支去查 service。
    return {
      summary:
        "已启用内置代理内核,但它的二进制尚未就位(下载未完成或被移走)。重跑启用即可补齐(幂等);内核服务在跑时也会在启动时自动补。",
      steps: [
        { description: "重跑启用补齐二进制(幂等)", command: "a2 mihomo enable --mode=embedded --json" },
        { description: "看本机现状", command: "a2 mihomo status --json" },
      ],
      context: { binaryPath: embedded.binaryPath, lockedVersion: embedded.lockedVersion },
    };
  }

  if (mode === "embedded" && embedded.state === "stopped") {
    return {
      summary:
        "已启用内置代理内核,但它此刻没在运行 —— 内嵌 mihomo 由 A2 内核服务托管,服务在跑它才会被拉起。",
      steps: [
        { description: "看内核服务在不在跑", command: "a2 service status --json" },
        { description: "服务没装则先安装(含开机自启)", command: "a2 service install --json" },
        { description: "服务在跑的话,重启内置内核", command: "a2 mihomo restart --json" },
      ],
      context: { controller: embedded.controller },
    };
  }

  if (mode === "off" && foreign?.instance) {
    return {
      summary:
        `mihomo 功能未启用。本机检测到一份在跑的 mihomo(${foreign.instance.controller},非 A2 管理)。` +
        "请把两种模式讲给用户、由用户选择:observe = 只读旁观它,A2 不改动不接管;" +
        "embedded = A2 另跑一份内置的,与现有并行、端口自动错开,建议之后停掉原来那份。",
      steps: [
        {
          description: "用户选 observe(只读旁观)时执行",
          command: "a2 mihomo enable --mode=observe --json",
        },
        {
          description: `用户选 embedded(内置内核)时执行(将下载 mihomo ${MIHOMO_LOCKED_VERSION},约 15 MB)`,
          command: "a2 mihomo enable --mode=embedded --json",
        },
        ...legacyStep,
      ],
      context: { foreignController: foreign.instance.controller },
    };
  }

  if (mode === "off") {
    return {
      summary:
        "mihomo 功能未启用。两种模式:embedded(A2 管理内置 mihomo,推荐)/" +
        "observe(只读旁观本机已有 mihomo)。本机未检测到在跑的 mihomo,推荐 embedded。",
      steps: [
        {
          description: `与用户确认后启用内置代理内核(将下载 mihomo ${MIHOMO_LOCKED_VERSION},约 15 MB,校验后启用)`,
          command: "a2 mihomo enable --mode=embedded --json",
        },
        ...legacyStep,
      ],
      context: { lockedVersion: MIHOMO_LOCKED_VERSION },
    };
  }

  if (mode === "observe" && (!foreign?.instance || !foreign.instance.reachable)) {
    return {
      summary:
        "observe 模式:读不到 mihomo 的 external-controller(它未开放、不可达,或配置里压根没写),仅能报告有限事实。",
      steps: [
        {
          description: "如需接管系统代理,先向用户问到 mihomo 的混入端口,再显式带参执行",
          command: "a2 proxy on --port <端口> --json",
        },
      ],
      context: {
        ...(foreign?.skippedController ? { skippedController: foreign.skippedController } : {}),
      },
    };
  }

  if (mode === "embedded" && embedded.state === "running" && !hasProxies) {
    return {
      summary:
        "内置 mihomo 运行中,但配置里没有任何代理节点(当前为空配置、全部直连)。需要把用户的订阅或节点写进配置才真正可用。",
      steps: [
        { description: "向用户要订阅链接(机场订阅 URL)或节点信息" },
        {
          description:
            `读取订阅内容,把其中的节点(proxies)合并写进配置文件(${embedded.configPath})` +
            "——这是你(agent)直接读改 YAML 的活;只搬 proxies 与所需分组,不要把订阅里的 rules 整份搬来覆盖已有策略",
        },
        { description: "重启内置内核使配置生效", command: "a2 mihomo restart --json" },
        { description: "确认代理已可用", command: "a2 proxy status --json" },
      ],
      context: { configPath: embedded.configPath },
    };
  }

  if (mode === "embedded" && embedded.state === "running" && foreign?.instance?.reachable) {
    return {
      summary:
        `内置 mihomo 运行中。另检测到一份非 A2 管理的 mihomo 也在跑(${foreign.instance.controller})。` +
        "系统代理同一时间只能指向一家,两边的开关会互相覆盖——建议与用户确认后停掉那一份。",
      steps: [
        {
          description:
            '经用户同意后停掉外来 mihomo(命令取决于它怎么装的:brew 装的用 "brew services stop mihomo";' +
            'launchd 装的用 "launchctl bootout gui/$UID/<它的 label>")。未经用户同意不要执行。',
        },
      ],
      context: { foreignController: foreign.instance.controller },
    };
  }

  return undefined;
}

// MARK: - 骨架

async function withMihomo(
  paths: KernelPaths,
  body: (ctx: MihomoContext) => Promise<OpOutcome>,
): Promise<OpOutcome> {
  const env = process.env;
  const ctx: MihomoContext = { paths, layout: mihomoLayout(paths, env), env };
  try {
    return await body(ctx);
  } catch (error) {
    if (error instanceof MihomoOperationError) return opFailure(error.toWireError());
    if (error instanceof SupervisorCommandError) {
      return opFailure({
        code: ErrorCode.mihomoOperationFailed,
        message: "拆除旧版 com.a2.mihomo unit 时 supervisor 命令失败。",
        detail: `${error.message}\n${error.output}`,
        guidance: {
          summary: "原样重跑那条命令看完整输出;拆干净之后重跑 enable(幂等)。",
          steps: [
            { description: "重跑失败的那条命令", command: error.command },
            { description: "重跑启用(幂等)", command: "a2 mihomo enable --mode=embedded --json" },
          ],
          context: { home: paths.home },
        },
      });
    }
    return opFailure({
      code: ErrorCode.mihomoOperationFailed,
      message: "mihomo 操作失败。",
      detail: String(error),
      guidance: {
        summary: "确认 A2_HOME 可写后重试(幂等)。",
        steps: [
          { description: "看当前现状", command: "a2 mihomo status --json" },
          {
            description: "看 mihomo 的错误日志",
            command: `tail -n 50 ${path.join(paths.home, LOG_DIR_NAME, MIHOMO_STDERR_LOG_NAME)}`,
          },
        ],
        context: { home: paths.home, dataDir: ctx.layout.dataDir },
      },
    });
  }
}

async function fileExists(file: string): Promise<boolean> {
  try {
    return (await stat(file)).isFile();
  } catch {
    return false;
  }
}
