// a2 运行时路径(单一来源)。ADR 0008 第 7 条:`~/.a2`,`A2_HOME` 可覆写,socket 落 `<home>/run/kernel.sock`。
//
// 为什么 socket 在 `run/` 子目录:该目录整体 0700,是 socket 权限之外的第二道门
// (即便某个 bind 后 chmod 失手,外人也进不了这一层)。

import { homedir } from "node:os";
import path from "node:path";

export interface KernelPaths {
  /** A2_HOME 展开后的绝对路径。 */
  home: string;
  /** 运行时目录 `<home>/run`(0700)。 */
  runDir: string;
  /** UDS socket `<home>/run/kernel.sock`。 */
  socketPath: string;
}

/** 运行时目录与 socket 的权限位(bind 后显式收紧,不信任 umask —— 见 ADR 0010 Consequences)。 */
export const RUN_DIR_MODE = 0o700;
export const SOCKET_MODE = 0o600;

/** 目录名/文件名常量,禁止各处各拼。 */
export const HOME_DIR_NAME = ".a2";
export const RUN_DIR_NAME = "run";
export const SOCKET_FILE_NAME = "kernel.sock";

/**
 * 解析运行时路径。`A2_HOME` 非空即覆写(相对路径按 cwd 展开成绝对路径),否则 `~/.a2`。
 * 全进程唯一入口:daemon bind 与 CLI connect 都从这里取,天然不会各算各的。
 */
export function resolvePaths(env: Record<string, string | undefined> = process.env): KernelPaths {
  const override = env.A2_HOME?.trim();
  const home = override ? path.resolve(override) : path.join(homedir(), HOME_DIR_NAME);
  const runDir = path.join(home, RUN_DIR_NAME);
  return { home, runDir, socketPath: path.join(runDir, SOCKET_FILE_NAME) };
}
