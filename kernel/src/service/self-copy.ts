// 「面板自足」的内核侧机制(15 票 / ADR 0012):把**本 bin 自己**原子拷进 `$A2_HOME/bin/a2`,
// 让 unit 指向那份拷贝而不是调用者所在的那个位置。
//
// 为什么 unit 不直接指进 `.app`:
//   * **translocation** —— macOS 从下载来源第一次打开 app 时会把它挂到一个随机只读路径上,
//     那条路径下次就不存在了,写进 unit 等于写了个一次性地址;
//   * **挪包/删包不该断服** —— 用户把 app 从下载目录拖进 /Applications 是最普通不过的动作,
//     而常驻服务在那一刻不该消失。拷贝落在数据同侧(`$A2_HOME`),与 app 的去留解耦。
//
// 为什么允许**自拷贝正在跑的自己**:落位靠 `rename` 换目录项,inode 不动 —— 跑着的旧进程攥着旧 inode
// 照常活到它自己退出为止(macOS/Linux 均如此;Windows 才有"跑着的文件不许改"那回事)。
// 于是"换了文件"与"换了进程"是两件事:后者由服务面显式重启完成(见 `manager.ts` 的收敛升级语义)。
//
// 卸载**有意不删这份拷贝**:`a2 service uninstall` 只拆 unit。它落在数据同侧,与配置、日志、
// 插件登记区同类 —— 数据的删除永远是另一个显式动作,不搭在"停服"这一条上顺手做掉。

import { chmod, mkdir, rename, unlink } from "node:fs/promises";
import path from "node:path";
import type { KernelPaths } from "../runtime/paths.ts";
import { isCompiledBin } from "./unit.ts";

/**
 * 覆写「本 bin 的可分发单文件在哪」。**仅供测试与诊断**(与 `A2_SERVICE_SUPERVISOR` 同一档):
 * 开发态压根没有编译产物,给它指一个等价的可执行,拷贝-收敛这条链才能在源码态被完整驱动。
 * 生产路径上没人会设它 —— 设了也只是把"拷谁"换成另一个本机文件,unit 名与域仍然写死。
 */
export const SELF_BIN_ENV = "A2_SELF_BIN";

/** 拷贝落点:`$A2_HOME/bin/a2`(目录名与文件名禁止各处各拼)。 */
export const HOME_BIN_DIR_NAME = "bin";
export const HOME_BIN_NAME = "a2";

/** 目录 0700:与 `run/`、`log/` 同档 —— `$A2_HOME` 底下的东西不给外人看。 */
export const HOME_BIN_DIR_MODE = 0o700;
/** 文件 0755:supervisor 要 exec 它;可执行位必须显式给(写文件的 mode 会被 umask 削)。 */
export const HOME_BIN_MODE = 0o755;

/** 落位前的暂存件后缀(与 `plugin/store.ts` 同一口径:先写临时件,再原子改名)。 */
export const STAGING_SUFFIX = ".staging";

/** `$A2_HOME/bin/a2` —— 全进程唯一入口。 */
export function homeBinPath(paths: KernelPaths): string {
  return path.join(paths.home, HOME_BIN_DIR_NAME, HOME_BIN_NAME);
}

/**
 * 本 bin 自己那份**可分发单文件**。开发态(源码跑)没有这种东西 —— 返回 undefined,
 * 由调用方翻成结构化拒绝(`process.execPath` 那时是 bun 自己,拷过去等于装了个跑不起来的空壳)。
 */
export function resolveSelfBin(
  env: Record<string, string | undefined> = process.env,
): string | undefined {
  const override = env[SELF_BIN_ENV]?.trim();
  if (override) return path.resolve(override);
  return isCompiledBin() ? process.execPath : undefined;
}

/** 拷了 = 内容真的变了(或本来就不在);没拷 = 目标已经逐字节是它了。 */
export type SelfCopyOutcome = "copied" | "unchanged";

/**
 * 把 `source` 原子落位到 `target`(0755)。
 *
 * **幂等判据是内容,不是 mtime**:同一份 bin 反复 install 不该每次都报"拷了一次" ——
 * 那会让 `actions` 这个"本次真改了什么"的可观察面失真,也会让收敛升级白白重启一次服务。
 * (mtime 不是内容的代理:checkout、复制、时钟回拨都能骗过它。)
 */
export async function copySelfToHome(source: string, target: string): Promise<SelfCopyOutcome> {
  if (await sameBytes(source, target)) return "unchanged";

  const dir = path.dirname(target);
  await mkdir(dir, { recursive: true, mode: HOME_BIN_DIR_MODE });
  await chmod(dir, HOME_BIN_DIR_MODE);

  // 暂存件与目标**同目录**:rename 只有在同一文件系统内才是原子的。
  const staging = `${target}${STAGING_SUFFIX}`;
  try {
    await Bun.write(staging, Bun.file(source));
    await chmod(staging, HOME_BIN_MODE);
    // 落位不必先删旧的:rename 覆盖是原子的,而先删会开一个"两个都不在"的窗口。
    await rename(staging, target);
  } catch (error) {
    await unlink(staging).catch(() => {});
    throw error;
  }
  return "copied";
}

/** 两个文件是不是同一批字节。先比大小(便宜地否掉绝大多数),再比 SHA-256。 */
async function sameBytes(source: string, target: string): Promise<boolean> {
  const left = Bun.file(source);
  const right = Bun.file(target);
  if (!(await right.exists())) return false;
  if (left.size !== right.size) return false;
  return (await sha256(left)) === (await sha256(right));
}

/** 流式摘要 —— 编译产物有 60MiB 上下,不整份读进内存。 */
async function sha256(file: Bun.BunFile): Promise<string> {
  const hasher = new Bun.CryptoHasher("sha256");
  for await (const chunk of file.stream()) hasher.update(chunk);
  return hasher.digest("hex");
}
