// 检测:把「本机上**不归 a2 管**的那些 mihomo」收集成一组**事实**(不做判断,判断在 manager.ts)。
//
// 三个扫描面,全部只看被交给我的东西:
//   * 二进制面 —— 只在 `scan.binaryDirs` 里找名叫 `mihomo` 的可执行文件;
//   * 配置面 —— 只读 `scan.configFiles` 里那几份,且只读 `external-controller` / `secret` 两行;
//   * 实例面 —— 只对上一步读出来的**回环**地址发只读 GET(见 controller.ts)。
// 没有端口扫描,没有进程表遍历,没有"顺着 PATH 一路找过去"。这既是红线,也是让检测可测的前提。
//
// **14 票起本文件只剩「别人那份」**:a2 自己那份不再靠检测拼凑(它是 daemon 的子进程,
// 事实来自认尸文件 + 那个 pid 活不活,见 `child.ts`)。检测的产物只进报告面与 guidance ——
// 没有任何一条写路径从这里通向别人的实例。

import { stat } from "node:fs/promises";
import path from "node:path";
import { probeController, type ControllerProbe } from "./controller.ts";
import {
  loopbackTarget,
  readControllerFromConfig,
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

export interface ForeignFacts {
  /** 别人的二进制(a2 自管落点下的那个不算)。 */
  binary?: ForeignBinary;
  /** 别人的实例(可达与否都记下来 —— "配置里写着但连不上"本身就是要报告的事实)。 */
  instance?: ControllerFinding;
  /** 配置里写着、但**不是回环**因而没去探的端点(如实报告,不静默丢弃)。 */
  skipped?: { address: string; configFile?: string };
}

/**
 * 收集「别人那份」的全部事实。`managedBinDir` 只用来**排除自己**:a2 自己的落点不算别人的,
 * 否则 embedded 一装上,内核就会把自己认成"检测到一份外来二进制"。
 */
export async function collectForeignFacts(
  scan: MihomoScanInputs,
  managedBinDir: string,
): Promise<ForeignFacts> {
  const [binary, config] = await Promise.all([
    findForeignBinary(scan.binaryDirs, managedBinDir),
    findForeignController(scan),
  ]);

  const base: ForeignFacts = { ...(binary ? { binary } : {}) };
  if (!config) return base;
  if ("skipped" in config) return { ...base, skipped: config.skipped };

  const probe = await probeController(config.target, config.secret);
  return { ...base, instance: { ...config, probe } };
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
 * 显式指定优先,否则按顺序读候选配置(第一份解析出地址的即用)。
 *
 * 找到的东西**只用来报告**:收编档废除后,内核对别人的实例除了两条只读 GET 之外什么都不做。
 */
async function findForeignController(
  scan: MihomoScanInputs,
): Promise<ControllerCandidate | undefined> {
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
