// 三档阶梯的**裁定**——纯计算:一组检测事实进,一个档位 + 兼容地板结论出。不碰文件、不发请求。
//
// 优先级(spec「共存 = 检测并优先复用,复用到实例级」):
//   ① 跑着的实例(external-controller 可达)→ `adopt_instance`,进程生死归原托管方;
//   ② 只有二进制 → `reuse_binary`,只读复用它,配置/数据/unit 全套自建;
//   ③ 全无 → `managed_install`,按锁定版下载校验落位。
//
// 两条压在优先级之上的规则,理由都是「不让检测结果反复横跳把数据面掀了」:
//   * **a2 已就位(`com.a2.mihomo` 的 unit 文件在)就维持现状** —— 用户后来自己装了一份 mihomo,
//     不该让 a2 悄悄放弃自己那份正在跑的实例。这种情况下报文里两边的事实都在,由人类决定要不要切。
//   * **收编档不因不达地板而自动回退** —— 回退等于在用户实例旁边再起一份,端口必打架。
//     那一档只出结构化降级报告 + 指引(`--isolated` 是人类显式选择的逃生门)。

import type {
  MihomoCompatibility,
  MihomoInstance,
  MihomoPresence,
  MihomoRung,
  MihomoShortfall,
} from "../contract/wire.ts";
import { probeCapabilities, type ControllerProbe } from "./controller.ts";
import type { MihomoFacts } from "./detect.ts";
import { MIHOMO_COMPAT_FLOOR, MIHOMO_LOCKED_VERSION, versionShortfall } from "./pin.ts";

export interface LadderDecision {
  presence: MihomoPresence;
  rung: MihomoRung;
  provisioned: boolean;
  instance?: MihomoInstance;
  compatibility: MihomoCompatibility;
  fallback?: { from: MihomoRung; shortfalls: MihomoShortfall[]; reason: string };
}

export interface LadderOptions {
  /** 人类显式要求隔离安装:忽略别人那份,直接走 ③ 档(不达地板时的逃生门)。 */
  isolated?: boolean;
}

export function decideLadder(facts: MihomoFacts, options: LadderOptions = {}): LadderDecision {
  const managedRunning = facts.managed.probe.reachable || facts.managed.state.pid !== undefined;
  const foreignRunning = facts.foreign?.probe.reachable === true;
  // 「就位」= a2 这边做过一次决定并留了痕:要么装了自己的 unit,要么记下了收编对象。
  const adopted = facts.adoption !== undefined && !options.isolated;
  const provisioned = facts.managed.unitInstalled || adopted;

  const presence: MihomoPresence = managedRunning || foreignRunning
    ? "running_instance"
    : facts.managed.binaryKind !== "absent" || facts.foreignBinary
      ? "binary_only"
      : "absent";

  // 收编档下,那个实例**探不通也照样报出来**:它是"我收编的那一个",不可达本身就是要说的话。
  const instance = managedRunning
    ? managedInstance(facts)
    : adopted || foreignRunning
      ? foreignInstance(facts)
      : undefined;

  // 档位。已就位就维持现状(自管形态由二进制是不是符号链接决定 —— 见 detect.ts 的 classifyManagedBinary)。
  const baseRung: MihomoRung = options.isolated
    ? "managed_install"
    : adopted
      ? "adopt_instance"
      : facts.managed.unitInstalled
        ? facts.managed.binaryKind === "reused"
          ? "reuse_binary"
          : "managed_install"
        : foreignRunning
          ? "adopt_instance"
          : facts.foreignBinary
            ? "reuse_binary"
            : "managed_install";

  const compatibility = compatibilityFor(baseRung, facts, provisioned);

  // 复用档不达地板 → 回退隔离安装并说明原因(收编档不回退,理由见文件头)。
  if (baseRung === "reuse_binary" && !provisioned && !compatibility.meets) {
    return {
      presence,
      rung: "managed_install",
      provisioned,
      ...(instance ? { instance } : {}),
      compatibility: lockedCompatibility(),
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

/** 能力位为空数组 = 一条都没探出来(通常就是这个实例此刻不在了)。 */
function foreignInstance(facts: MihomoFacts): MihomoInstance {
  const found = facts.foreign;
  if (!found) {
    return {
      owner: "foreign",
      controller: facts.adoption?.controller ?? "(未知)",
      secretConfigured: false,
      capabilities: [],
      ...(facts.adoption?.configFile ? { configFile: facts.adoption.configFile } : {}),
    };
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
 *   * 收编档 → 那个实例(版本 + 三个能力位都要);
 *   * 复用档 → 那个二进制(**只判版本**:能力位得跑起来才问得出,没起来就不当作不达标);
 *   * 安装档 → 锁定版本身,恒达标。
 */
function compatibilityFor(
  rung: MihomoRung,
  facts: MihomoFacts,
  provisioned: boolean,
): MihomoCompatibility {
  if (rung === "managed_install") return lockedCompatibility();

  if (rung === "adopt_instance") {
    const probe = facts.foreign?.probe;
    return fromProbe(probe, probe?.version);
  }

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

function fromProbe(probe: ControllerProbe | undefined, version: string | undefined): MihomoCompatibility {
  const shortfalls: MihomoShortfall[] = [];
  if (!probe?.reachable) shortfalls.push("rest_api_unreachable");
  const shortfall = versionShortfall(version);
  if (shortfall) shortfalls.push(shortfall);
  if (probe?.reachable && !probe.meta) shortfalls.push("not_meta_core");
  if (probe?.reachable && !probe.configsReadable) shortfalls.push("configs_unreadable");
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
