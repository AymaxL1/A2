// `--purge` 那把 `rm -rf` 的护圈(17 票 CR 尾款)。
//
// ============================================================================
// 为什么这不是"防呆",是必需品
// ============================================================================
// `A2_HOME` 是**公开的覆写项**(写在 `a2 service --help` 里、写在 unit 里、agent 的命令模板里到处是它)。
// 而 `--purge` 会对它做 `rm -rf`。于是 `A2_HOME=/`、`A2_HOME=$HOME`、`A2_HOME=/Users` 这三种形状
// 就不是假想:模板展开丢了一段、环境变量没设成空串而是设成了 `/`、脚本里 `A2_HOME=$HOME/.a2` 少写一半 ——
// 每一种都会让"删掉 a2 自己的数据目录"变成"把用户可写的东西全清了"。
//
// 判据分两层,**顺序有意**:
//   ① `unsafeHomeShape` —— **纯函数**,只看路径字符串。测试因此可以把 `/`、`$HOME`、`/Users`
//      这些病态值原样喂进来验判据本身,而**绝不需要真的造一个 `A2_HOME=/` 去跑一次删除**;
//   ② `unsafeHomeOnDisk` —— 看盘上那个 home 的**形状**(是不是符号链接)。这一条非碰文件系统不可,
//      但它只 lstat/readlink,不写一个字节。
//
// 两层都返回「拒绝原因」而不是布尔值:调用方要把原因翻成人话与指引(拒绝即指引),
// 而机读面要拿它当分支依据 —— 一个 true/false 两头都不够用。

import { lstat, readlink, stat } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

/**
 * 拒绝原因(机读词表)。进 `guidance.context.reason`,agent 据此分支。
 *   * `not_absolute` —— 相对路径。正常路径上不可能(`resolvePaths` 会展开),留着是因为**删除的
 *     不变量不该依赖上游有没有替我做过某件事** —— 那种依赖迟早会被一次重构悄悄拿掉。
 *   * `filesystem_root` —— 就是 `/`(或 Windows 的盘符根)。
 *   * `home_directory` —— 就是用户家目录本身。
 *   * `home_ancestor` —— 家目录的祖先(`/Users`、`/home`)。删它等于把所有用户的东西一起端了。
 *   * `symlink` —— home 是个符号链接:`rm -rf` 只会删掉那根链,**数据一个字节都没动**
 *     (所有写路径都穿链写),却会报"删干净了"。那是假账,比删不掉更糟。
 *   * `dangling_symlink` —— 同上,而且链目标已经不在了。
 */
export type PurgeRefusalReason =
  | "not_absolute"
  | "filesystem_root"
  | "home_directory"
  | "home_ancestor"
  | "symlink"
  | "dangling_symlink";

export interface PurgeRefusal {
  reason: PurgeRefusalReason;
  /** 给人看的一句话:**这个路径**为什么不能删。 */
  detail: string;
  /** 符号链接那两档才有:链指向哪儿(用户得知道去哪儿收拾)。 */
  linkTarget?: string;
}

/**
 * 第①层:**纯判据**,只看字符串。
 *
 * 四条不变量,每一条都答同一个问题:「这个路径可能是 a2 自己的数据目录吗?」
 * 不可能的一律拒绝 —— 这里宁可误拒(把 home 设成家目录本身的人得自己改一下),
 * 也绝不误删(那是不可逆的)。
 *
 * `userHome` 可注入:测试要在不依赖跑测试的人的家目录的前提下验「home 是家目录 / 家目录的祖先」两档。
 */
export function unsafeHomeShape(
  home: string,
  userHome: string = homedir(),
): PurgeRefusal | undefined {
  if (!path.isAbsolute(home)) {
    return { reason: "not_absolute", detail: `${home} 不是绝对路径 —— 删除的目标必须是确定的。` };
  }
  // `path.parse('/').root === '/'`:根就是它自己的根。这一条同时挡住 Windows 的 `C:\`。
  const normalized = normalize(home);
  if (path.parse(normalized).root === normalized) {
    return { reason: "filesystem_root", detail: `${home} 是文件系统根。` };
  }
  const user = normalize(userHome);
  if (normalized === user) {
    return {
      reason: "home_directory",
      detail: `${home} 就是当前用户的家目录本身(a2 的数据目录应当是它下面的 .a2,不是它)。`,
    };
  }
  // 家目录在它下面 = 它是家目录的祖先(`/Users`、`/home`)。删它 = 把所有用户的东西一起端了。
  if (user.startsWith(`${normalized}${path.sep}`)) {
    return {
      reason: "home_ancestor",
      detail: `${home} 是家目录(${userHome})的上级目录。`,
    };
  }
  return undefined;
}

/**
 * 第②层:盘上那个 home **是不是一根符号链接**。
 *
 * 这一条是 CR 实测抓到的假账:`rm(home, { recursive: true, force: true })` 对符号链接
 * **只删链、不删树** —— 而 a2 的所有写路径(配置、插件、日志、`bin/a2`、接管快照)都是穿链写的,
 * 数据全在链目标那棵树里。于是一次 purge 会报 `home_purged` + 零残留,而数据分毫未动。
 *
 * 修法取仓风格:**如实拒绝并把真实目标告诉用户**,而不是替他决定"那我把链目标也删了吧" ——
 * 链目标是他自己指过去的地方(外置盘、别的卷、共享目录),那不是 a2 该替人做主的范围。
 *
 * home 不存在(`ENOENT`)不是错:那说明没什么可删的,交给调用方按幂等处理。
 */
export async function unsafeHomeOnDisk(home: string): Promise<PurgeRefusal | undefined> {
  const info = await lstat(home).catch(() => undefined);
  if (info === undefined || !info.isSymbolicLink()) return undefined;

  const linkTarget = await readlink(home).catch(() => undefined);
  const resolved = linkTarget === undefined
    ? undefined
    : path.resolve(path.dirname(home), linkTarget);
  const alive = resolved !== undefined && (await stat(resolved).catch(() => undefined)) !== undefined;
  const where = resolved ?? "(读不出链目标)";
  return {
    reason: alive ? "symlink" : "dangling_symlink",
    detail: alive
      ? `${home} 是一根指向 ${where} 的符号链接:删掉它只会删掉这根链,数据全在链目标那棵树里(a2 的一切都是穿链写的)。`
      : `${home} 是一根符号链接,而它指向的 ${where} 已经不在了 —— 删掉这根链既清不掉数据,也证明不了数据在哪。`,
    ...(resolved === undefined ? {} : { linkTarget: resolved }),
  };
}

/** 去掉尾随分隔符(`/Users/` 与 `/Users` 是同一个地方;根除外,那本来就是一个分隔符)。 */
function normalize(value: string): string {
  const resolved = path.resolve(value);
  return resolved.length > 1 && resolved.endsWith(path.sep) ? resolved.slice(0, -1) : resolved;
}
