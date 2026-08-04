// mihomo 的**锁版事实**:装哪个版本、从哪儿拿、拿到之后拿什么校验、以及"低于多少就不认"。
//
// 为什么单独一个文件:这几个值是 06 票唯一会被人问「凭什么是这个数」的地方,必须一处成文、一处可改。
// 「升级永远显式」这条决策的技术含义就是:**没有任何代码路径会绕过这里的 `MIHOMO_LOCKED_VERSION`**——
// 下载只下这一版,升级也只升到这一版,想换版本得改这个常量并重新发布内核。
//
// mihomo **不随任何分发物打包**(ADR 0007 修订版 / spec):这里只有元数据,仓库里没有那 42MiB 的二进制。

import type { MihomoShortfall } from "../contract/wire.ts";

/**
 * 锁定版本。
 *
 * **出处**:`Sources/PluginProxy/Resources/MIHOMO-VERSION.txt` 首行 `Mihomo Meta v1.19.28 darwin arm64` ——
 * 那是旧仓随包分发过、且被旧门禁逐字节校验过的那一份,是本仓库里唯一一个**有实测背书**的版本。
 * (研究文档 `docs/research/mihomo-integration.md` §7 记录 v1.19.29 是当时的最新稳定版,但我们没有它的
 * 校验和实测背书 —— 锁版必须锁到能验的那一版,而不是最新的那一版。换版是一次显式决策,连同下面的摘要表一起改。)
 */
export const MIHOMO_LOCKED_VERSION = "v1.19.28";

/**
 * 兼容地板。低于它的实例/二进制内核**不接管、不复用**,只出结构化降级报告 —— 而不是擅自升级别人的东西。
 *
 * **凭什么是 1.19**:07 票要用的控制面端点(`PATCH /configs` 运行时改 mode、`PUT /configs` 从路径重载、
 * `GET /group/<n>/delay` 整组测速)在 1.19.x 上是我们唯一实测过的组合(旧仓 `MihomoRESTClient` +
 * `Scripts/check/mihomo-real-e2e.sh` 跑的就是 v1.19.28)。再往下没有实测背书,不承诺。
 */
export const MIHOMO_COMPAT_FLOOR = "1.19.0";

/** 官方发布渠道(`A2_MIHOMO_RELEASE_BASE` 可覆写 —— 镜像源与测试都靠它)。 */
export const MIHOMO_RELEASE_BASE = "https://github.com/MetaCubeX/mihomo/releases";

/**
 * 锁定版各平台资产的 **SHA-256(解压后的可执行本体)**。
 *
 * `darwin-arm64` 那条是本机 `shasum -a 256 Sources/PluginProxy/Resources/mihomo-darwin-arm64` 现场核对过的,
 * 与 `MIHOMO-VERSION.txt` 的 `SHA-256:` 行一致。**其余平台留空是有意的**:没有可信摘要就没有可信安装 ——
 * 内核在那些平台上 fail-closed 拒绝下载并给出指引,而不是"先装了再说"。补表的方式写在拒绝报文里。
 */
export const MIHOMO_ASSET_DIGESTS: Readonly<Record<string, string>> = {
  "darwin-arm64": "55b7286331cb30a54b2564013b02b84a0c280e8b690bd1e5da4b9d4f4ca007ac",
};

/** 本机的资产键(`<os>-<arch>`,官方资产命名口径:amd64 而非 x64)。 */
export function assetKey(
  platform: string = process.platform,
  arch: string = process.arch,
): string {
  const os = platform === "darwin" ? "darwin" : platform === "linux" ? "linux" : platform;
  const cpu = arch === "x64" ? "amd64" : arch === "arm64" ? "arm64" : arch;
  return `${os}-${cpu}`;
}

/** 官方资产文件名:`mihomo-darwin-arm64-v1.19.28.gz`。 */
export function assetFileName(key: string, version: string = MIHOMO_LOCKED_VERSION): string {
  return `mihomo-${key}-${version}.gz`;
}

/** 完整下载地址。 */
export function assetUrl(
  key: string,
  version: string = MIHOMO_LOCKED_VERSION,
  base: string = MIHOMO_RELEASE_BASE,
): string {
  return `${base.replace(/\/+$/, "")}/download/${version}/${assetFileName(key, version)}`;
}

/**
 * 从 `mihomo -v` 或 `/version` 的应答里抠出版本号,统一成 `v1.19.28` 形态。
 * 认得的两种形态:`Mihomo Meta v1.19.28 darwin arm64 with gc go1.24.5 …` 与裸的 `v1.19.28` / `1.19.28`。
 */
export function parseVersion(text: string): string | undefined {
  const match = /v?(\d+\.\d+(?:\.\d+)?(?:[-.\w]*)?)/.exec(text.trim());
  return match ? `v${match[1]}` : undefined;
}

/** 版本比较:a < b → 负,a > b → 正。只比数字段,预发布后缀(`-alpha` 等)忽略。 */
export function compareVersions(a: string, b: string): number {
  const parts = (v: string) =>
    v.replace(/^v/, "").split(/[-+]/)[0]!.split(".").map((n) => Number.parseInt(n, 10) || 0);
  const left = parts(a);
  const right = parts(b);
  for (let i = 0; i < Math.max(left.length, right.length); i += 1) {
    const diff = (left[i] ?? 0) - (right[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

/** 版本够不够地板。问不出版本时**不当作达标**(未知不等于没问题)。 */
export function versionShortfall(version: string | undefined): MihomoShortfall | undefined {
  if (!version) return "version_unknown";
  return compareVersions(version, MIHOMO_COMPAT_FLOOR) < 0 ? "version_below_floor" : undefined;
}
