// 与系统 supervisor 说话的那一层:launchctl / systemctl 怎么问、怎么使唤、怎么读它的回答。
//
// **红线**:所有目标都由 `SERVICE_LABEL`(`com.a2.kernel`)拼出,domain 恒为 `gui/<uid>` /  `--user`。
// 本文件里没有任何一条命令的目标来自参数或环境 —— 内核只碰自己那一个 unit,别人的服务一概不动。
//
// 两个平台的差异只在这里露头(manager 那层只认「查一下 / 装上 / 拉起 / 卸掉」四件事):
//   * launchd:bootstrap = 装载 + 自启一体,没有独立的 enable 开关;改了 plist 必须 bootout 再 bootstrap;
//   * systemd:unit 文件与 enable/start 是三件独立的事,改了文件要 daemon-reload。

import type { ServiceAction, SupervisorKind } from "../contract/wire.ts";
import { SERVICE_LABEL, type ServicePlan } from "./unit.ts";

/** supervisor 眼里的 unit 状态。 */
export interface SupervisorState {
  /** 认不认识这个 unit(launchd:已 bootstrap;systemd:LoadState ≠ not-found)。 */
  registered: boolean;
  /** 开机自启开关。**仅 systemd 有**;launchd 的 bootstrap 本身即含自启,恒 undefined。 */
  enabled?: boolean;
  /** 运行中才有。 */
  pid?: number;
}

/** supervisor 命令没按预期成功 —— 原始命令行与输出原样带出,好让指引能说"你自己敲这条看看"。 */
export class SupervisorCommandError extends Error {
  constructor(
    readonly command: string,
    readonly exitCode: number,
    readonly output: string,
  ) {
    super(`命令失败(退出码 ${exitCode}):${command}`);
    this.name = "SupervisorCommandError";
  }
}

export interface Supervisor {
  readonly kind: SupervisorKind;
  /**
   * 装载这个动作本身会不会顺带把进程拉起来。launchd 会(`RunAtLoad`,所以 bootstrap 之后要等一下再判断);
   * systemd 不会(`enable` 只管开机自启这个开关,拉起要另外 `start`)—— manager 据此决定要不要空等。
   */
  readonly loadStartsProcess: boolean;
  /** 查当前状态(只读)。 */
  query(): Promise<SupervisorState>;
  /** unit 文件刚被写或删之后,让 supervisor 重读(systemd daemon-reload;launchd 无此步)。 */
  syncUnitFiles(unitChanged: boolean): Promise<ServiceAction[]>;
  /** 收敛到「已装载 + 开机自启」。`unitChanged` = 本次 unit 内容有变(launchd 据此决定要不要先 bootout)。 */
  load(state: SupervisorState, unitChanged: boolean): Promise<ServiceAction[]>;
  /** 显式拉起进程(装载了但没在跑时用)。 */
  start(): Promise<void>;
  /**
   * 显式重启进程 —— **unit 内容漂了而服务正跑着**时用:重写文件只收敛了「磁盘上写的是什么」,
   * 已经在跑的那个进程仍在用旧的 ExecStart/环境变量。只有 `loadStartsProcess` 为假的 supervisor
   * (systemd)才需要走这一步;launchd 的 bootout + bootstrap 本身就把进程换了。
   */
  restart(): Promise<void>;
  /** 停 + 取消自启 + 从 supervisor 卸下(unit 文件由 manager 删)。 */
  unload(state: SupervisorState): Promise<ServiceAction[]>;
}

export function createSupervisor(plan: ServicePlan): Supervisor {
  return plan.kind === "launchd" ? new LaunchdSupervisor(plan) : new SystemdSupervisor(plan);
}

interface CommandResult {
  command: string;
  exitCode: number;
  stdout: string;
  stderr: string;
}

/**
 * 跑一条外部命令。非零退出即抛(`allowExitCodes` 里的除外 —— 那些是"这本来就可能没有"的良性失败)。
 * 命令本身找不到(launchctl/systemctl 不在 PATH)也翻成同一种错误,调用方不必分两种 catch。
 */
async function run(argv: string[], allowExitCodes: number[] = []): Promise<CommandResult> {
  const command = argv.join(" ");
  let proc;
  try {
    proc = Bun.spawn({ cmd: argv, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  } catch (error) {
    throw new SupervisorCommandError(command, -1, `无法执行:${String(error)}`);
  }
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  await proc.exited;
  const exitCode = proc.exitCode ?? -1;
  if (exitCode !== 0 && !allowExitCodes.includes(exitCode)) {
    throw new SupervisorCommandError(command, exitCode, `${stdout}${stderr}`.trim());
  }
  return { command, exitCode, stdout, stderr };
}

// MARK: - launchd(macOS user 域 agent)

/** `launchctl print` 在服务未登记时的退出码(本机 macOS 15 实测:113)。 */
const LAUNCHCTL_NOT_FOUND = 113;
/** `launchctl bootout` 在服务本就不在时的退出码(ESRCH:No such process)。 */
const LAUNCHCTL_NO_SUCH_PROCESS = 3;

class LaunchdSupervisor implements Supervisor {
  readonly kind = "launchd" as const;
  readonly loadStartsProcess = true;

  constructor(private readonly plan: ServicePlan) {}

  /** `gui/<uid>` —— user 域(不需要 root,不依赖 GUI 登录会话之外的东西)。 */
  #domain(): string {
    return `gui/${process.getuid?.() ?? 0}`;
  }

  /** `gui/<uid>/com.a2.kernel` —— 本内核唯一会碰的 service target。 */
  #target(): string {
    return `${this.#domain()}/${SERVICE_LABEL}`;
  }

  async query(): Promise<SupervisorState> {
    const result = await run(["launchctl", "print", this.#target()], [LAUNCHCTL_NOT_FOUND]);
    if (result.exitCode === LAUNCHCTL_NOT_FOUND) return { registered: false };
    const pid = /^\s*pid = (\d+)\s*$/m.exec(result.stdout)?.[1];
    return pid === undefined
      ? { registered: true }
      : { registered: true, pid: Number.parseInt(pid, 10) };
  }

  /** launchd 直接吃 plist 文件路径,没有"重读目录"这一步。 */
  async syncUnitFiles(): Promise<ServiceAction[]> {
    return [];
  }

  async load(state: SupervisorState, unitChanged: boolean): Promise<ServiceAction[]> {
    const actions: ServiceAction[] = [];
    let registered = state.registered;
    // 已装载的 job 不会自己发现 plist 变了:必须先卸下再装回来,否则跑的还是旧内容。
    if (registered && unitChanged) {
      await run(["launchctl", "bootout", this.#target()], [LAUNCHCTL_NO_SUCH_PROCESS]);
      actions.push("supervisor_unloaded");
      registered = false;
    }
    if (!registered) {
      await run(["launchctl", "bootstrap", this.#domain(), this.plan.unitPath]);
      actions.push("supervisor_loaded");
    }
    return actions;
  }

  async start(): Promise<void> {
    await run(["launchctl", "kickstart", this.#target()]);
  }

  /** `-k` = 先杀再拉。**本 supervisor 上走不到这条路**(load 就已经换了进程),留着是为了接口完整。 */
  async restart(): Promise<void> {
    await run(["launchctl", "kickstart", "-k", this.#target()]);
  }

  async unload(state: SupervisorState): Promise<ServiceAction[]> {
    if (!state.registered) return [];
    await run(["launchctl", "bootout", this.#target()], [LAUNCHCTL_NO_SUCH_PROCESS]);
    return ["supervisor_unloaded"];
  }
}

// MARK: - systemd(Linux user 单元)

class SystemdSupervisor implements Supervisor {
  readonly kind = "systemd" as const;
  readonly loadStartsProcess = false;

  constructor(private readonly plan: ServicePlan) {}

  /** `com.a2.kernel.service`。 */
  #unit(): string {
    return `${SERVICE_LABEL}.service`;
  }

  #systemctl(...args: string[]): string[] {
    return ["systemctl", "--user", ...args];
  }

  async query(): Promise<SupervisorState> {
    // 一条命令问全三件事;unit 不存在时 systemctl 照样 exit 0,只是 LoadState=not-found。
    const result = await run(
      this.#systemctl(
        "show",
        this.#unit(),
        "--property=LoadState",
        "--property=UnitFileState",
        "--property=MainPID",
        "--property=ActiveState",
      ),
    );
    const properties = new Map<string, string>();
    for (const line of result.stdout.split("\n")) {
      const separator = line.indexOf("=");
      if (separator > 0) properties.set(line.slice(0, separator), line.slice(separator + 1).trim());
    }
    const registered = properties.get("LoadState") === "loaded";
    const enabled = properties.get("UnitFileState") === "enabled";
    const mainPid = Number.parseInt(properties.get("MainPID") ?? "0", 10);
    const running = properties.get("ActiveState") === "active" && mainPid > 0;
    return running
      ? { registered, enabled, pid: mainPid }
      : { registered, enabled };
  }

  async syncUnitFiles(unitChanged: boolean): Promise<ServiceAction[]> {
    if (!unitChanged) return [];
    await run(this.#systemctl("daemon-reload"));
    return ["supervisor_reloaded"];
  }

  async load(state: SupervisorState, unitChanged: boolean): Promise<ServiceAction[]> {
    // daemon-reload 之后 LoadState/UnitFileState 才是新的,重查一次再决定要不要 enable。
    const current = unitChanged ? await this.query() : state;
    if (current.enabled) return [];
    await run(this.#systemctl("enable", this.#unit()));
    return ["supervisor_loaded"];
  }

  async start(): Promise<void> {
    await run(this.#systemctl("start", this.#unit()));
  }

  async restart(): Promise<void> {
    await run(this.#systemctl("restart", this.#unit()));
  }

  async unload(state: SupervisorState): Promise<ServiceAction[]> {
    const actions: ServiceAction[] = [];
    if (state.pid !== undefined) await run(this.#systemctl("stop", this.#unit()));
    if (state.enabled) await run(this.#systemctl("disable", this.#unit()));
    if (state.pid !== undefined || state.enabled) actions.push("supervisor_unloaded");
    return actions;
  }
}
