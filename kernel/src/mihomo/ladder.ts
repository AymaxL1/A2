// 两档阶梯的**裁定**——纯计算:一组检测事实进,一个档位 + 兼容地板结论出。不碰文件、不发请求。
//
// 优先级(spec「共存 = 检测并优先复用」;2026-08-12 起复用**到二进制级为止**):
//   ① 盘上有二进制 → `reuse_binary`,只读复用它,配置/数据/unit 全套自建;
//   ② 全无 → `managed_install`,按锁定版下载校验落位。
//
// **原来还有一档 `adopt_instance`(收编跑着的实例),已按用户裁定废除**:
// 「本机已有在跑的 mihomo,应该只读状态,不用去接管」。别人的实例现在只进 `presence` 与 `instance`
// 供人读 —— 它不再影响档位,也不再有任何一条写路径通向它。「未就位时撞见别人的实例该怎么办」
// 不在本文件裁定(这里只算档位),而是 `manager.ts` 里那道闸:结构化拒绝 + 零改动。
//
// 一条压在优先级之上的规则,理由是「不让检测结果反复横跳把数据面掀了」:
//   * **a2 已就位(`com.a2.mihomo` 的 unit 文件在)就维持现状** —— 用户后来自己装了一份 mihomo,
//     不该让 a2 悄悄换掉自己那份正在跑的实例。这种情况下报文里两边的事实都在,由人类决定要不要切。

import type {
  MihomoCompatibility,
  MihomoInstance,
  MihomoPresence,
  MihomoRung,
  MihomoShortfall,
} from "../contract/wire.ts";
import { probeCapabilities } from "./controller.ts";
import type { MihomoFacts } from "./detect.ts";
import { MIHOMO_COMPAT_FLOOR, MIHOMO_LOCKED_VERSION, versionShortfall } from "./pin.ts";

export interface LadderDecision {
  presence: MihomoPresence;
  rung: MihomoRung;
  provisioned: boolean;
  instance?: MihomoInstance;
  compatibility: MihomoCompatibility;
  fallback?: { from: MihomoRung; shortfalls: MihomoShortfall[]; reason: string };
  /**
   * **别人的**实例此刻可达。档位算式里已经用不到它了(收编档废除),留在裁定结果里是因为
   * `manager.ts` 那道「未就位 + 别人在跑 → 拒绝」的闸要用,而闸的判据不该各写各的。
   */
  foreignInstanceRunning: boolean;
}

export interface LadderOptions {
  /**
   * 人类显式要求隔离安装:不复用盘上那份二进制,直接走 ② 档按锁定版下载。
   * 它同时是「别人的实例在跑」那道闸的唯一逃生门 —— 机器上要不要并存两份 mihomo,由人来定。
   */
  isolated?: boolean;
}

export function decideLadder(facts: MihomoFacts, options: LadderOptions = {}): LadderDecision {
  const managedRunning = facts.managed.probe.reachable || facts.managed.state.pid !== undefined;
  const foreignInstanceRunning = facts.foreign?.probe.reachable === true;
  // 「就位」= a2 这边装过自己那套 unit。(收编记录曾经也算一种就位,随收编档一并退场。)
  const provisioned = facts.managed.unitInstalled;

  const presence: MihomoPresence = managedRunning || foreignInstanceRunning
    ? "running_instance"
    : facts.managed.binaryKind !== "absent" || facts.foreignBinary
      ? "binary_only"
      : "absent";

  // 自管那份优先报;它不在时,别人那份**可达才报**(不可达 = 这台机器上没有跑着的实例可说)。
  const instance = managedRunning
    ? managedInstance(facts)
    : foreignInstanceRunning
      ? foreignInstance(facts)
      : undefined;

  // 档位。已就位就维持现状(自管形态由二进制是不是符号链接决定 —— 见 detect.ts 的 classifyManagedBinary)。
  const baseRung: MihomoRung = options.isolated
    ? "managed_install"
    : provisioned
      ? facts.managed.binaryKind === "reused"
        ? "reuse_binary"
        : "managed_install"
      : facts.foreignBinary
        ? "reuse_binary"
        : "managed_install";

  const compatibility = compatibilityFor(baseRung, facts, provisioned);

  // 复用档不达地板 → 回退隔离安装并说明原因。
  if (baseRung === "reuse_binary" && !provisioned && !compatibility.meets) {
    return {
      presence,
      rung: "managed_install",
      provisioned,
      ...(instance ? { instance } : {}),
      compatibility: lockedCompatibility(),
      foreignInstanceRunning,
      fallback: {
        from: "reuse_binary",
        shortfalls: compatibility.shortfalls,
        reason:
          `盘上那份 mihomo(${facts.foreignBinary?.path ?? "路径未知"},版本 ` +
          `${compatibility.version ?? "问不出"})不达兼容地板 ${MIHOMO_COMPAT_FLOOR},` +
          `已回退为按锁定版 ${MIHOMO_LOCKED_VERSION} 隔离安装 —— 内核不会去升级不属于它的二进制。`,
      },
    };
  }

  return {
    presence,
    rung: baseRung,
    provisioned,
    ...(instance ? { instance } : {}),
    compatibility,
    foreignInstanceRunning,
  };
}

function managedInstance(facts: MihomoFacts): MihomoInstance {
  const version = facts.managed.probe.version ?? facts.managed.version;
  return {
    owner: "a2",
    controller: facts.layout.controller,
    secretConfigured: facts.managed.secretConfigured,
    ...(version ? { version } : {}),
    capabilities: probeCapabilities(facts.managed.probe),
    configFile: facts.layout.configPath,
  };
}

/** 只在 `facts.foreign` 可达时被调用 —— 别人的实例只报「此刻确实在跑的那一个」。 */
function foreignInstance(facts: MihomoFacts): MihomoInstance {
  const found = facts.foreign;
  if (!found) {
    return { owner: "foreign", controller: "(未知)", secretConfigured: false, capabilities: [] };
  }
  return {
    owner: "foreign",
    controller: found.target,
    secretConfigured: found.secret !== undefined,
    ...(found.probe.version ? { version: found.probe.version } : {}),
    capabilities: probeCapabilities(found.probe),
    ...(found.configFile ? { configFile: found.configFile } : {}),
  };
}

/**
 * 兼容地板判定,判的是**这一档将要用的那份东西**:
 *   * 复用档 → 那个二进制(**只判版本**:能力位得跑起来才问得出,没起来就不当作不达标);
 *   * 安装档 → 锁定版本身,恒达标。
 *
 * (收编档废除后,「判别人那个实例够不够格」这件事没有了对象 —— 内核不接管它,也就无需为它设门槛。
 * 它的版本与能力位仍如实出现在 `status` 的 `instance` 里,那是报告,不是判据。)
 */
function compatibilityFor(
  rung: MihomoRung,
  facts: MihomoFacts,
  provisioned: boolean,
): MihomoCompatibility {
  if (rung === "managed_install") return lockedCompatibility();

  // 复用档:未就位时看盘上那份;已就位时看 a2 落点上那个符号链接指向的那份。
  const version = provisioned ? facts.managed.version : facts.foreignBinary?.version;
  const shortfalls: MihomoShortfall[] = [];
  const shortfall = versionShortfall(version);
  if (shortfall) shortfalls.push(shortfall);
  return {
    floor: MIHOMO_COMPAT_FLOOR,
    meets: shortfalls.length === 0,
    ...(version ? { version } : {}),
    shortfalls,
  };
}

function lockedCompatibility(): MihomoCompatibility {
  return { floor: MIHOMO_COMPAT_FLOOR, meets: true, version: MIHOMO_LOCKED_VERSION, shortfalls: [] };
}
