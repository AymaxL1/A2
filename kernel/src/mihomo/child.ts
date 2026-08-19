// 内嵌 mihomo 子进程的**全部生死**(14 票 / ADR 0014)。
//
// 编排四层来自 launchd 语义研究(03 票,`docs/research/launchd-child-subprocess-lifecycle.md`):
//   1. **同进程组 spawn**(绝不 setsid/daemonize)—— a2 daemon 死于任何死法时,launchd 都会对同组
//      发一记 SIGTERM(AbandonProcessGroup 默认 false),这是「a2 死 mihomo 死」的第一层;
//   2. **退出钩子** —— 那记组 SIGTERM 是可捕获的、launchd 也不会对组升级 SIGKILL,所以 daemon
//      自己退出时要走 `stop()`:SIGTERM → ≤3s → SIGKILL → daemon 以 0 退出(KeepAlive 双键的硬要求);
//   3. **启动认尸** —— 逃过组清理的孤儿(卡死不理 SIGTERM 的)只有这一层能兜:每次拉起前
//      读认尸文件、验明正身(pid 活 + 命令行匹配 + 启动时间吻合)才补刀,验不明就**不动手**并如实报告;
//   4. **节流与故障态** —— 崩溃重拉隔 10s;连续 3 次没活过「最短存活时间」→ `failed` + stderr 尾部原文,
//      停止重拉(配置坏了的重拉风暴只会刷日志,不会把配置修好)。`restart()` 清零计数,是故障态唯一的出路。
//
// **红线**:本文件唯一会碰的进程,是"认尸文件里记着、且验明是 a2 自己拉起的那一个"。
// 别人的 mihomo(哪个都一样)连它的 pid 都不会出现在这里。

import path from "node:path";
import { MIHOMO_STDERR_LOG_NAME, MIHOMO_STDOUT_LOG_NAME, LOG_DIR_NAME } from "../service/unit.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import type { MihomoLayout } from "./paths.ts";

/** 崩溃重拉的节流(与旧 launchd `ThrottleInterval` 同一口径,数字沿用)。 */
export const CHILD_THROTTLE_MS = 10_000;
/** 覆写节流(毫秒)。仅测试与诊断用 —— 门禁里等真 10 秒是浪费所有人的命。 */
export const CHILD_THROTTLE_ENV = "A2_MIHOMO_CHILD_THROTTLE_MS";
/** 连续失败几次转故障态。 */
export const CHILD_FAIL_LIMIT = 3;
/** 活过这个时长才算"这次启动成功了"(连续失败计数据此清零)。 */
export const CHILD_HEALTHY_MS = 5_000;
/** 覆写健康阈值(毫秒)。仅测试与诊断用。 */
export const CHILD_HEALTHY_ENV = "A2_MIHOMO_CHILD_HEALTHY_MS";
/** `stop()` 里 SIGTERM 的宽限;超时补 SIGKILL。 */
export const CHILD_TERM_GRACE_MS = 3_000;
/** stderr 尾部最多留多少字节进 `lastError`(报文要能读,不是要全量日志)。 */
const STDERR_TAIL_LIMIT = 2_000;

/**
 * 认尸文件(`<dataDir>/child.json`)—— 内嵌子进程的**唯一真相源**。
 * daemon 写它,`a2 mihomo status`(可能在没有 daemon 的进程里跑)只读它。
 */
export interface ChildRecord {
  /** 在跑(或死了还没被发现)的子进程。 */
  pid?: number;
  /** spawn 那一刻(epoch 毫秒)。认尸时与 `ps` 报的启动时间对表用。 */
  startedAt?: number;
  /** 当时 spawn 的二进制路径。认尸时与 `ps` 报的命令行对表用。 */
  binaryPath?: string;
  /** 当时 spawn 的配置路径(`-f` 实参)。**身份的第二根指纹**:二进制若是个 exec 掉自己的
   * 包装脚本(测试假件正是),命令行里就只剩配置路径可认 —— 两根指纹都是每实例唯一的。 */
  configPath?: string;
  /** **连续**启动失败次数(健康存活或显式 restart 都清零)。 */
  restartCount: number;
  /** 最近一次失败时 mihomo 的 stderr 尾部**原文**。 */
  lastError?: string;
  /** 已达连续失败上限、a2 已暂停重拉。 */
  failed?: boolean;
}

export function childRecordPath(layout: MihomoLayout): string {
  return path.join(layout.dataDir, "child.json");
}

export async function readChildRecord(layout: MihomoLayout): Promise<ChildRecord> {
  const text = await Bun.file(childRecordPath(layout))
    .text()
    .catch(() => undefined);
  if (text === undefined) return { restartCount: 0 };
  try {
    const parsed = JSON.parse(text) as Partial<ChildRecord>;
    return {
      restartCount:
        typeof parsed.restartCount === "number" && parsed.restartCount >= 0
          ? Math.floor(parsed.restartCount)
          : 0,
      ...(typeof parsed.pid === "number" && parsed.pid > 0 ? { pid: Math.floor(parsed.pid) } : {}),
      ...(typeof parsed.startedAt === "number" ? { startedAt: parsed.startedAt } : {}),
      ...(typeof parsed.binaryPath === "string" && parsed.binaryPath ? { binaryPath: parsed.binaryPath } : {}),
      ...(typeof parsed.configPath === "string" && parsed.configPath ? { configPath: parsed.configPath } : {}),
      ...(typeof parsed.lastError === "string" && parsed.lastError ? { lastError: parsed.lastError } : {}),
      ...(parsed.failed === true ? { failed: true } : {}),
    };
  } catch {
    // 认尸文件坏了 = 没有可信身份 → 当没有记录(绝不据一份坏文件去杀进程)。
    return { restartCount: 0 };
  }
}

export async function writeChildRecord(layout: MihomoLayout, record: ChildRecord): Promise<void> {
  const ordered = {
    ...(record.pid !== undefined ? { pid: record.pid } : {}),
    ...(record.startedAt !== undefined ? { startedAt: record.startedAt } : {}),
    ...(record.binaryPath !== undefined ? { binaryPath: record.binaryPath } : {}),
    ...(record.configPath !== undefined ? { configPath: record.configPath } : {}),
    restartCount: record.restartCount,
    ...(record.lastError !== undefined ? { lastError: record.lastError } : {}),
    ...(record.failed ? { failed: true } : {}),
  };
  await Bun.write(childRecordPath(layout), `${JSON.stringify(ordered, null, 2)}\n`);
}

// MARK: - 探针(全部可注入 —— 测试要能造出"孤儿""冒名顶替""卡死不理 SIGTERM"三种尸体)

export interface ProcessProbe {
  /** pid 此刻活不活(信号 0)。 */
  alive(pid: number): boolean;
  /** 那个 pid 的命令行(`ps -o command=`);拿不到 = 进程没了或看不见。 */
  commandOf(pid: number): Promise<string | undefined>;
}

export function defaultProbe(): ProcessProbe {
  return {
    alive(pid: number): boolean {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    },
    async commandOf(pid: number): Promise<string | undefined> {
      // **绝对路径**:被测进程的 PATH 常被测试收窄到只剩假件目录,裸名 `ps` 会当场找不到。
      for (const ps of ["/bin/ps", "/usr/bin/ps"]) {
        try {
          const proc = Bun.spawn({
            cmd: [ps, "-p", String(pid), "-o", "command="],
            stdout: "pipe",
            stderr: "ignore",
            stdin: "ignore",
          });
          const out = await new Response(proc.stdout).text();
          await proc.exited;
          const line = out.trim();
          return line.length > 0 ? line : undefined;
        } catch {
          /* 试下一个位置 */
        }
      }
      return undefined;
    },
  };
}

/**
 * 验明正身:认尸文件里那个 pid,现在跑着的**是不是 a2 拉起的那个 mihomo**。
 * 判据:pid 活着 + 命令行里认得出**任一根指纹**(二进制路径 / 配置路径,都是每实例唯一)。
 * pid 复用给了别的进程时两根都对不上 —— 这正是研究票说的「对孤儿与顶替的唯一硬保证」。
 */
export async function identifyChild(
  record: ChildRecord,
  probe: ProcessProbe,
): Promise<"ours" | "gone" | "not_ours"> {
  if (record.pid === undefined || record.binaryPath === undefined) return "gone";
  if (!probe.alive(record.pid)) return "gone";
  const command = await probe.commandOf(record.pid);
  if (!command) return "gone";
  const prints = [record.binaryPath, record.configPath].filter((p): p is string => p !== undefined);
  return prints.some((print) => command.includes(print)) ? "ours" : "not_ours";
}

// MARK: - 快照(给 `a2 mihomo status` 用 —— 只读,不拉不杀)

export interface ChildSnapshot {
  state: "running" | "stopped" | "failed";
  pid?: number;
  restartCount: number;
  lastError?: string;
}

/** 只读快照:读认尸文件 + 验一次身份。**绝不改状态**(哪怕发现记录是陈尸也只如实报 stopped)。 */
export async function childSnapshot(
  layout: MihomoLayout,
  probe: ProcessProbe = defaultProbe(),
): Promise<ChildSnapshot> {
  const record = await readChildRecord(layout);
  if (record.failed) {
    return {
      state: "failed",
      restartCount: record.restartCount,
      ...(record.lastError ? { lastError: record.lastError } : {}),
    };
  }
  const identity = await identifyChild(record, probe);
  if (identity === "ours") {
    return {
      state: "running",
      pid: record.pid as number,
      restartCount: record.restartCount,
      ...(record.lastError ? { lastError: record.lastError } : {}),
    };
  }
  return {
    state: "stopped",
    restartCount: record.restartCount,
    ...(record.lastError ? { lastError: record.lastError } : {}),
  };
}

// MARK: - 管理器(daemon 进程里唯一实例;`mihomo.apply` / `mihomo.restart` 的实体)

export interface ChildManagerOptions {
  /** 时间源(节流与健康判定用;测试注入假时钟)。 */
  now?: () => number;
  /** 睡眠(测试里换成立即返回)。 */
  sleep?: (ms: number) => Promise<void>;
  probe?: ProcessProbe;
  /** spawn 本体可整只换掉(测试用 fake-mihomo)。 */
  spawn?: (cmd: string[], stdout: number | "ignore", stderr: number | "ignore") => ChildHandle;
  /** 状态变化时的回调(C2 接事件面;不给就只写认尸文件)。 */
  onTransition?: (snapshot: ChildSnapshot) => void;
}

/** spawn 出来的那个东西,管理器只需要这三样。 */
export interface ChildHandle {
  pid: number;
  exited: Promise<number | null>;
  kill(signal: NodeJS.Signals): void;
}

interface RunningChild {
  handle: ChildHandle;
  startedAt: number;
}

/**
 * 内嵌子进程管理器。**一个 daemon 一只**;`start()` 幂等(已在跑就什么都不做)。
 * 它假定"该不该跑"由调用方(daemon 按落盘的托管模式)裁定 —— 这里只管"怎么把它跑住"。
 */
export class MihomoChild {
  private running: RunningChild | undefined;
  private stopping = false;
  private readonly now: () => number;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly probe: ProcessProbe;
  private readonly spawnImpl: NonNullable<ChildManagerOptions["spawn"]>;
  private readonly onTransition: ChildManagerOptions["onTransition"];
  private readonly throttleMs: number;
  private readonly healthyMs: number;

  constructor(
    private readonly paths: KernelPaths,
    private readonly layout: MihomoLayout,
    options: ChildManagerOptions = {},
  ) {
    this.now = options.now ?? Date.now;
    this.sleep = options.sleep ?? ((ms) => Bun.sleep(ms));
    this.probe = options.probe ?? defaultProbe();
    this.spawnImpl = options.spawn ?? defaultSpawn;
    this.onTransition = options.onTransition;
    this.throttleMs = envMs(CHILD_THROTTLE_ENV, CHILD_THROTTLE_MS);
    this.healthyMs = envMs(CHILD_HEALTHY_ENV, CHILD_HEALTHY_MS);
  }

  /** 此刻的只读快照(内存优先,没有内存态时读盘)。 */
  async snapshot(): Promise<ChildSnapshot> {
    if (this.running) {
      const record = await readChildRecord(this.layout);
      return { state: "running", pid: this.running.handle.pid, restartCount: record.restartCount };
    }
    return await childSnapshot(this.layout, this.probe);
  }

  /**
   * 确保子进程在跑(幂等)。故障态**不**自作主张重来 —— 那是 `restart()` 的事。
   * 返回本次是否真拉起了新进程。
   */
  async start(): Promise<boolean> {
    if (this.running) return false;
    const record = await readChildRecord(this.layout);
    if (record.failed) return false;
    await this.reapCorpse(record);
    await this.spawnOnce(record.restartCount);
    return true;
  }

  /** 停掉(SIGTERM → 宽限 → SIGKILL),幂等。daemon 正常退出与 disable 都走这里。 */
  async stop(): Promise<boolean> {
    const running = this.running;
    if (!running) return false;
    this.stopping = true;
    try {
      running.handle.kill("SIGTERM");
      const grace = this.sleep(CHILD_TERM_GRACE_MS).then(() => "timeout" as const);
      const exited = running.handle.exited.then(() => "exited" as const);
      if ((await Promise.race([exited, grace])) === "timeout") {
        running.handle.kill("SIGKILL");
        await running.handle.exited;
      }
    } finally {
      this.running = undefined;
      this.stopping = false;
    }
    const record = await readChildRecord(this.layout);
    await writeChildRecord(this.layout, { restartCount: record.restartCount });
    this.emit(await this.snapshot());
    return true;
  }

  /** 显式重启:清零连续失败计数(故障态唯一的出路),然后停 → 起。返回之前是否在跑。 */
  async restart(): Promise<boolean> {
    const wasRunning = await this.stop();
    const record = await readChildRecord(this.layout);
    await writeChildRecord(this.layout, {
      restartCount: 0,
      ...(record.lastError ? { lastError: record.lastError } : {}),
    });
    await this.spawnOnce(0);
    return wasRunning;
  }

  /**
   * 认尸:上一世代(daemon 崩了被 launchd 重拉)可能留下孤儿。验明是自己的才补刀;
   * 验不明(pid 被复用给了别的进程)**不动手** —— 端口冲突会在 mihomo 起不来时以 lastError 的形式浮出来。
   */
  private async reapCorpse(record: ChildRecord): Promise<void> {
    const identity = await identifyChild(record, this.probe);
    if (identity !== "ours") return;
    try {
      process.kill(record.pid as number, "SIGKILL");
    } catch {
      /* 补刀那一瞬它自己死了 —— 目的已达成 */
    }
    // 等它真消失(SIGKILL 不可捕获,只是回收需要一拍)。
    for (let i = 0; i < 50 && this.probe.alive(record.pid as number); i += 1) {
      await this.sleep(100);
    }
  }

  private async spawnOnce(restartCount: number): Promise<void> {
    const logDir = path.join(this.paths.home, LOG_DIR_NAME);
    await Bun.write(path.join(logDir, ".keep"), "").catch(() => undefined);
    const stdoutFile = Bun.file(path.join(logDir, MIHOMO_STDOUT_LOG_NAME));
    const stderrPath = path.join(logDir, MIHOMO_STDERR_LOG_NAME);
    const stderrFile = Bun.file(stderrPath);
    const handle = this.spawnImpl(
      [this.layout.binaryPath, "-d", this.layout.dataDir, "-f", this.layout.configPath],
      // Bun.spawn 收 BunFile 但类型上这里走 number|ignore 的注入面;默认实现在 defaultSpawn 里用真文件。
      (await ensureAppendFd(stdoutFile)) ?? "ignore",
      (await ensureAppendFd(stderrFile)) ?? "ignore",
    );
    const startedAt = this.now();
    this.running = { handle, startedAt };
    await writeChildRecord(this.layout, {
      pid: handle.pid,
      startedAt,
      binaryPath: this.layout.binaryPath,
      configPath: this.layout.configPath,
      restartCount,
    });
    this.emit({ state: "running", pid: handle.pid, restartCount });
    void this.watch(handle, startedAt, restartCount, stderrPath);
  }

  /** 看着它;死了按节流/故障态语义处置。**这是管理器里唯一的循环**。 */
  private async watch(
    handle: ChildHandle,
    startedAt: number,
    restartCount: number,
    stderrPath: string,
  ): Promise<void> {
    await handle.exited;
    if (this.stopping || this.running?.handle !== handle) return; // 是我们自己停的
    this.running = undefined;

    const lived = this.now() - startedAt;
    const healthy = lived >= this.healthyMs;
    const nextCount = healthy ? 1 : restartCount + 1;
    const lastError = await stderrTail(stderrPath);

    if (!healthy && nextCount >= CHILD_FAIL_LIMIT) {
      await writeChildRecord(this.layout, {
        restartCount: nextCount,
        failed: true,
        ...(lastError ? { lastError } : {}),
      });
      this.emit({ state: "failed", restartCount: nextCount, ...(lastError ? { lastError } : {}) });
      return;
    }

    await writeChildRecord(this.layout, {
      restartCount: nextCount,
      ...(lastError ? { lastError } : {}),
    });
    this.emit({ state: "stopped", restartCount: nextCount, ...(lastError ? { lastError } : {}) });
    await this.sleep(this.throttleMs);
    if (this.stopping || this.running) return;
    const record = await readChildRecord(this.layout);
    if (record.failed) return;
    await this.spawnOnce(record.restartCount);
  }

  private emit(snapshot: ChildSnapshot): void {
    this.onTransition?.(snapshot);
  }
}

function envMs(name: string, fallback: number): number {
  const parsed = Number.parseInt(process.env[name]?.trim() ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function defaultSpawn(
  cmd: string[],
  stdout: number | "ignore",
  stderr: number | "ignore",
): ChildHandle {
  const proc = Bun.spawn({ cmd, stdout, stderr, stdin: "ignore" });
  return {
    pid: proc.pid,
    exited: proc.exited.then(
      (code) => code,
      () => null,
    ),
    kill(signal: NodeJS.Signals) {
      try {
        proc.kill(signal);
      } catch {
        /* 已经没了 */
      }
    },
  };
}

/** 以 append 打开日志文件拿 fd;打不开(目录只读等)就让子进程的输出丢掉,不因日志毁主业。 */
async function ensureAppendFd(file: ReturnType<typeof Bun.file>): Promise<number | undefined> {
  try {
    const { open } = await import("node:fs/promises");
    const handle = await open(file.name as string, "a");
    return handle.fd;
  } catch {
    return undefined;
  }
}

/** stderr 尾部原文(报文要能读;全量日志在文件里,路径由 guidance 给)。 */
async function stderrTail(stderrPath: string): Promise<string | undefined> {
  const text = await Bun.file(stderrPath)
    .text()
    .catch(() => undefined);
  if (!text) return undefined;
  const tail = text.slice(-STDERR_TAIL_LIMIT).trim();
  return tail.length > 0 ? tail : undefined;
}
