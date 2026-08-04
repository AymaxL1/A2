// 检测:把「本机 mihomo 是个什么现状」收集成一组**事实**(不做判断,判断在 ladder.ts)。
//
// 三个扫描面,全部只看被交给我的东西:
//   * 二进制面 —— 只在 `scan.binaryDirs` 里找名叫 `mihomo` 的可执行文件;
//   * 配置面 —— 只读 `scan.configFiles` 里那几份,且只读 `external-controller` / `secret` 两行;
//   * 实例面 —— 只对上一步读出来的**回环**地址发只读 GET(见 controller.ts)。
// 没有端口扫描,没有进程表遍历,没有"顺着 PATH 一路找过去"。这既是红线,也是让检测可测的前提。

import { lstat, readlink, stat } from "node:fs/promises";
import path from "node:path";
import type { MihomoBinaryKind } from "../contract/wire.ts";
import type { Supervisor, SupervisorState } from "../service/supervisor.ts";
import type { ServicePlan } from "../service/unit.ts";
import { probeController, type ControllerProbe } from "./controller.ts";
import { readAdoption, type MihomoAdoption } from "./install.ts";
import {
  loopbackTarget,
  readControllerFromConfig,
  type MihomoLayout,
  type MihomoScanInputs,
} from "./paths.ts";
import { parseVersion } from "./pin.ts";

/** 问一次 `mihomo -v` 的上限。它只是打印一行就退出,超过这个时间说明那个文件不是我们以为的东西。 */
const VERSION_TIMEOUT_MS = 3000;

export interface ForeignBinary {
  path: string;
  version?: string;
}

export interface ControllerFinding {
  /** 归一后的连接目标(恒 `127.0.0.1:<port>`)。 */
  target: string;
  /** 配置里原样写的地址(可能是 `0.0.0.0:9090` 之类)。 */
  address: string;
  secret?: string;
  configFile?: string;
  probe: ControllerProbe;
}

export interface ManagedFacts {
  binaryKind: MihomoBinaryKind;
  binaryPath: string;
  /** `reused` 时符号链接指向的真身。 */
  binaryTarget?: string;
  version?: string;
  unitInstalled: boolean;
  state: SupervisorState;
  /** a2 自管实例的控制端点探测结果(unit 没跑时也探一次:进程在不在与控制面通不通是两件事)。 */
  probe: ControllerProbe;
  secretConfigured: boolean;
}

export interface MihomoFacts {
  layout: MihomoLayout;
  scan: MihomoScanInputs;
  managed: ManagedFacts;
  /** 别人的二进制(a2 自管落点下的那个不算)。 */
  foreignBinary?: ForeignBinary;
  /** 别人的实例(可达与否都记下来 —— "配置里写着但连不上"本身就是要报告的事实)。 */
  foreign?: ControllerFinding;
  /** 配置里写着、但**不是回环**因而没去探的端点(如实报告,不静默丢弃)。 */
  skipped?: { address: string; configFile?: string };
  /** a2 记下的收编对象(有它才谈得上"我收编的那个实例死了")。 */
  adoption?: MihomoAdoption;
}

export async function collectFacts(
  layout: MihomoLayout,
  scan: MihomoScanInputs,
  plan: ServicePlan,
  supervisor: Supervisor,
): Promise<MihomoFacts> {
  const adoption = await readAdoption(layout);
  const [managed, foreignBinary, foreignConfig] = await Promise.all([
    collectManaged(layout, plan, supervisor),
    findForeignBinary(scan.binaryDirs, layout.binDir),
    findForeignController(scan, adoption),
  ]);

  const base = {
    layout,
    scan,
    managed,
    ...(foreignBinary ? { foreignBinary } : {}),
    ...(adoption ? { adoption } : {}),
  };
  if (!foreignConfig) return base;
  if ("skipped" in foreignConfig) return { ...base, skipped: foreignConfig.skipped };

  const probe = await probeController(foreignConfig.target, foreignConfig.secret);
  return { ...base, foreign: { ...foreignConfig, probe } };
}

async function collectManaged(
  layout: MihomoLayout,
  plan: ServicePlan,
  supervisor: Supervisor,
): Promise<ManagedFacts> {
  const [kind, state] = await Promise.all([
    classifyManagedBinary(layout.binaryPath),
    supervisor.query(),
  ]);
  const config = await Bun.file(layout.configPath)
    .text()
    .catch(() => undefined);
  const secret = config ? readControllerFromConfig(config)?.secret : undefined;
  const version =
    kind.binaryKind === "absent" ? undefined : await binaryVersion(layout.binaryPath);
  const probe = await probeController(layout.controller, secret);
  return {
    ...kind,
    binaryPath: layout.binaryPath,
    ...(version ? { version } : {}),
    unitInstalled: await exists(plan.unitPath),
    state,
    probe,
    secretConfigured: secret !== undefined,
  };
}

/**
 * a2 自管落点上那个文件是什么形态。**判据是文件类型本身**,不是另存一份"我当初是怎么装的"状态:
 * 符号链接 = 只读复用别人的二进制,真文件 = 我自己下载的锁定版。少一份会漂移的状态。
 */
async function classifyManagedBinary(
  binaryPath: string,
): Promise<{ binaryKind: MihomoBinaryKind; binaryTarget?: string }> {
  try {
    const info = await lstat(binaryPath);
    if (info.isSymbolicLink()) {
      const target = await readlink(binaryPath);
      return { binaryKind: "reused", binaryTarget: path.resolve(path.dirname(binaryPath), target) };
    }
    return { binaryKind: "downloaded" };
  } catch {
    return { binaryKind: "absent" };
  }
}

/** 在被交给我的那几个目录里找 `mihomo`。**a2 自己的落点不算别人的** —— 否则自管会被认成"复用自己"。 */
async function findForeignBinary(
  dirs: string[],
  managedBinDir: string,
): Promise<ForeignBinary | undefined> {
  for (const dir of dirs) {
    if (path.resolve(dir) === path.resolve(managedBinDir)) continue;
    const candidate = path.join(dir, "mihomo");
    if (!(await isExecutableFile(candidate))) continue;
    const version = await binaryVersion(candidate);
    return version ? { path: candidate, version } : { path: candidate };
  }
  return undefined;
}

type ControllerCandidate =
  | { target: string; address: string; secret?: string; configFile?: string }
  | { skipped: { address: string; configFile?: string } };

/**
 * 收编记录优先(**已经收编的那个端点就是要盯的那个**,哪怕它此刻连不上),
 * 其次是显式指定,最后才按顺序读候选配置(第一份解析出地址的即用)。
 */
async function findForeignController(
  scan: MihomoScanInputs,
  adoption: MihomoAdoption | undefined,
): Promise<ControllerCandidate | undefined> {
  if (adoption) {
    const target = loopbackTarget(adoption.controller);
    if (!target) return { skipped: { address: adoption.controller, ...(adoption.configFile ? { configFile: adoption.configFile } : {}) } };
    const secret = adoption.configFile ? await secretOf(adoption.configFile) : undefined;
    return {
      target,
      address: adoption.controller,
      ...(secret ? { secret } : {}),
      ...(adoption.configFile ? { configFile: adoption.configFile } : {}),
    };
  }
  if (scan.explicit) {
    const target = loopbackTarget(scan.explicit.controller);
    if (!target) return { skipped: { address: scan.explicit.controller } };
    return {
      target,
      address: scan.explicit.controller,
      ...(scan.explicit.secret ? { secret: scan.explicit.secret } : {}),
    };
  }

  for (const file of scan.configFiles) {
    const text = await Bun.file(file)
      .text()
      .catch(() => undefined);
    if (text === undefined) continue;
    const found = readControllerFromConfig(text);
    if (!found) continue;
    const target = loopbackTarget(found.controller);
    if (!target) return { skipped: { address: found.controller, configFile: file } };
    return {
      target,
      address: found.controller,
      ...(found.secret ? { secret: found.secret } : {}),
      configFile: file,
    };
  }
  return undefined;
}

/** 从一份配置里只把 secret 读出来(收编记录只存地址,钥匙每次现读 —— 它随时可能被主人改)。 */
async function secretOf(configFile: string): Promise<string | undefined> {
  const text = await Bun.file(configFile).text().catch(() => undefined);
  return text ? readControllerFromConfig(text)?.secret : undefined;
}

/** 跑一次 `<bin> -v` 问版本。**这是只读操作**:mihomo 的 `-v` 打印一行就退出,不碰配置、不开端口。 */
export async function binaryVersion(binaryPath: string): Promise<string | undefined> {
  let proc;
  try {
    proc = Bun.spawn({ cmd: [binaryPath, "-v"], stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  } catch {
    return undefined;
  }
  const timer = setTimeout(() => proc.kill(), VERSION_TIMEOUT_MS);
  try {
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    await proc.exited;
    return parseVersion(`${stdout}${stderr}`);
  } catch {
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}

async function isExecutableFile(candidate: string): Promise<boolean> {
  try {
    const info = await stat(candidate);
    return info.isFile() && (info.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

async function exists(file: string): Promise<boolean> {
  try {
    await stat(file);
    return true;
  } catch {
    return false;
  }
}
