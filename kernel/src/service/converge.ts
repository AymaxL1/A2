// unit 收敛骨架 —— **与"这是哪个 unit"无关**的那一半:写文件、让 supervisor 重读、装载、拉起、确认。
//
// 为什么单拎出来:内核(`com.a2.kernel`)与 a2 自管的 mihomo(`com.a2.mihomo`)是两条命、两个 unit,
// 但"怎么把一个 unit 收敛到目标态"是同一件事。分开写两遍的代价不是行数,是**两份会各自漂移的语义**
// (幂等判据、漂移处置、等 pid 的时机)。所以这里只留一份,各面各自把动作词表翻成自己的话。
//
// 收敛语义(与服务面同一口径):说的是"我要它是这个样子",不是"执行这几步"。已经是那个样子就什么都不做,
// 返回的 `actions` 为空 —— 这就是幂等的可观察面。

import { existsSync } from "node:fs";
import { chmod, mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { loadImpliesStart, type Supervisor, type SupervisorState, type UnitAction } from "./supervisor.ts";
import { LOG_DIR_MODE, UNIT_FILE_MODE, type ServicePlan } from "./unit.ts";

/** 等"进程真的起来/真的没了"的上限。systemd/launchd 的动作是异步的,状态不会在命令返回的那一刻就位。 */
export const SETTLE_TIMEOUT_MS = 2000;
export const SETTLE_POLL_MS = 50;

export interface ConvergeResult {
  actions: UnitAction[];
  /** 收敛之后最后一次看到的 supervisor 状态(有没有 pid 由调用方按自己的承诺判断)。 */
  state: SupervisorState;
}

/**
 * 把一个 unit 收敛到「文件是这份内容 + supervisor 装载了 + 进程跑着」。
 *
 * 三处不显然的地方:
 *   1. **日志目录必须先于 job 存在** —— launchd 不会替你创建 `StandardOutPath` 的父目录,目录不在则 job 起不来;
 *   2. **漂移要收敛到进程,不只是收敛到文件** —— unit 内容变了而进程正跑着时,那个进程仍在用旧的 ExecStart;
 *      launchd 的 bootout+bootstrap 顺带把进程换了,systemd 则必须显式 restart;
 *   3. **装载 ≠ 跑起来** —— unit 内容没变时 launchd 根本不会重启它,所以要显式拉一把再验。
 */
export async function convergeUnit(
  plan: ServicePlan,
  supervisor: Supervisor,
): Promise<ConvergeResult> {
  const actions: UnitAction[] = [];

  await mkdir(plan.logDir, { recursive: true, mode: LOG_DIR_MODE });
  await chmod(plan.logDir, LOG_DIR_MODE);

  const unitChanged = (await readIfExists(plan.unitPath)) !== plan.unitContent;
  if (unitChanged) {
    await mkdir(path.dirname(plan.unitPath), { recursive: true });
    await writeFile(plan.unitPath, plan.unitContent, { mode: UNIT_FILE_MODE });
    await chmod(plan.unitPath, UNIT_FILE_MODE);
    actions.push("unit_written");
  }

  const before = await supervisor.query();
  actions.push(...(await supervisor.syncUnitFiles(unitChanged)));
  actions.push(...(await supervisor.load(before, unitChanged)));

  let restarted = false;
  if (unitChanged && before.pid !== undefined && !supervisor.loadStartsProcess) {
    await supervisor.restart();
    actions.push("process_restarted");
    restarted = true;
  }

  // 只有"刚 bootstrap 过 + 该 supervisor 的装载含拉起"或"刚 restart 过"这两种情形值得空等 ——
  // 其余情形直接问一次就够,空等只会让"装了但起不来"的排障多花几秒。
  // (前一半判据与 `service/manager.ts` 的"要不要为换了的 bin 再重启一次"是同一件事,故共用一份。)
  let state = await supervisor.query();
  const worthWaiting = restarted || loadImpliesStart(supervisor, actions);
  if (state.pid === undefined && worthWaiting) {
    state = await settle(supervisor, (current) => current.pid !== undefined);
  }
  if (state.pid === undefined) {
    await supervisor.start();
    actions.push("process_started");
    state = await settle(supervisor, (current) => current.pid !== undefined);
  }

  return { actions, state };
}

/**
 * 把一个 unit 收敛到「从 supervisor 卸下 + 文件不在 + 进程真的没了」。
 * 最后那一步不能省:否则下一次 install 会撞上一个野生实例。
 */
export async function removeUnit(
  plan: ServicePlan,
  supervisor: Supervisor,
): Promise<ConvergeResult> {
  const actions: UnitAction[] = [];
  actions.push(...(await supervisor.unload(await supervisor.query())));

  // 名字说的是**赋值那一刻**的事实(unit 文件还在),而不是"已经删掉了"——
  // 它同时是"要不要删"与"删完要不要让 supervisor 重读目录"两处判据。
  const unitPresent = existsSync(plan.unitPath);
  if (unitPresent) {
    await unlink(plan.unitPath);
    actions.push("unit_removed");
  }
  actions.push(...(await supervisor.syncUnitFiles(unitPresent)));

  const state = await settle(supervisor, (current) => current.pid === undefined);
  return { actions, state };
}

/** 轮询到条件成立(或超时)。返回最后一次看到的状态 —— 超时与否由调用方按 pid 自己判断。 */
export async function settle(
  supervisor: { query(): Promise<SupervisorState> },
  done: (state: SupervisorState) => boolean,
): Promise<SupervisorState> {
  const deadline = Date.now() + SETTLE_TIMEOUT_MS;
  let state = await supervisor.query();
  while (!done(state) && Date.now() < deadline) {
    await Bun.sleep(SETTLE_POLL_MS);
    state = await supervisor.query();
  }
  return state;
}

async function readIfExists(file: string): Promise<string | undefined> {
  try {
    return await readFile(file, "utf8");
  } catch {
    return undefined;
  }
}
