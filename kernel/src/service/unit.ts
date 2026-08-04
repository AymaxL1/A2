// 服务「单元」层:unit 文件长什么样、落在哪儿、里面跑哪条命令。
//
// **纯计算**:只产出字符串与路径,不碰 launchctl/systemctl(那是 supervisor.ts 的事),也不写盘。
// 这样"内容对不对""路径对不对"两件事在测试里可以逐字断言,而不必真的装一次服务。
//
// 自愈与自启全在这份内容里(ADR 0008 第 6 条):launchd `KeepAlive.Crashed` + `RunAtLoad`,
// systemd `Restart=on-failure` + `WantedBy=default.target`。应用层不造看门狗 —— 内核崩了由系统重拉,
// 内核被显式停掉(SIGTERM)则**不**重拉(两种 supervisor 的语义在这一点上恰好一致)。

import { homedir } from "node:os";
import path from "node:path";
import type { SupervisorKind } from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";

/**
 * 唯一的 unit 名。**内核只碰这一个 label** —— launchctl/systemctl 的所有目标都由它拼出来,
 * 任何命令行参数都改不了它(`a2 service` 不接受 label 参数,这是有意的边界)。
 */
export const SERVICE_LABEL = "com.a2.kernel";

/** 覆写 supervisor 选择。**仅供测试与诊断**:在 macOS 上跑一遍 Linux 代码路径(实机验收顺延)。 */
export const SUPERVISOR_ENV = "A2_SERVICE_SUPERVISOR";

/** 日志目录与两个重定向文件(launchd 必须显式指定,否则输出去向不可依赖;systemd 走 journal)。 */
export const LOG_DIR_NAME = "log";
export const STDOUT_LOG_NAME = "kernel.out.log";
export const STDERR_LOG_NAME = "kernel.err.log";

/** unit 文件权限:plist 需 0644(launchd 对宽松权限的 plist 会拒绝装载)。 */
export const UNIT_FILE_MODE = 0o644;
/** 日志目录权限:与 `<home>/run` 同档,不给外人看内核日志。 */
export const LOG_DIR_MODE = 0o700;

export interface ServicePlan {
  kind: SupervisorKind;
  label: string;
  /** unit 文件绝对路径。 */
  unitPath: string;
  /** unit 文件的完整内容(确定性:同输入必同字节 —— 幂等判定就靠它逐字比较)。 */
  unitContent: string;
  /** unit 里写的启动命令(argv 形式)。 */
  programArguments: string[];
  /** 日志目录(install 时自建;launchd 不会替你创建,目录不在则 job 起不来)。 */
  logDir: string;
  paths: KernelPaths;
}

export type SupervisorChoice =
  | { ok: true; kind: SupervisorKind }
  | { ok: false; reason: string };

/**
 * 本机该用哪个 supervisor。macOS → launchd,Linux → systemd,其余平台没有已支持的路径。
 * `A2_SERVICE_SUPERVISOR` 可覆写(测试/诊断);写了个不认识的值当错处理,不静默忽略。
 */
export function resolveSupervisorKind(
  env: Record<string, string | undefined> = process.env,
  platform: string = process.platform,
): SupervisorChoice {
  const override = env[SUPERVISOR_ENV]?.trim();
  if (override) {
    if (override === "launchd" || override === "systemd") return { ok: true, kind: override };
    return { ok: false, reason: `${SUPERVISOR_ENV}=${override} 不是已知的 supervisor(只认 launchd / systemd)` };
  }
  if (platform === "darwin") return { ok: true, kind: "launchd" };
  if (platform === "linux") return { ok: true, kind: "systemd" };
  return { ok: false, reason: `平台 ${platform} 没有已支持的 supervisor(当下承诺 macOS + Linux)` };
}

/**
 * unit 里要跑的那条命令。两种被测/被装形态各一条:
 *   * 编译产物(`bun build --compile`)→ `<bin> daemon run`;
 *   * 源码跑(开发/测试)→ `<bun> run <入口> daemon run`。
 * 判据用 Bun 编译产物特有的虚拟文件系统前缀(实测:编译后 `Bun.main` = `/$bunfs/root/<名字>`)。
 */
export function resolveProgramArguments(): string[] {
  const compiled = Bun.main.startsWith("/$bunfs/");
  return compiled
    ? [process.execPath, "daemon", "run"]
    : [process.execPath, "run", Bun.main, "daemon", "run"];
}

function userHome(env: Record<string, string | undefined>): string {
  const home = env.HOME?.trim();
  return home ? path.resolve(home) : homedir();
}

/** `~/Library/LaunchAgents` —— user 域 agent 的标准位置(不需要 root,不依赖 GUI 登录)。 */
export function launchAgentsDir(env: Record<string, string | undefined> = process.env): string {
  return path.join(userHome(env), "Library", "LaunchAgents");
}

/** `$XDG_CONFIG_HOME/systemd/user`(缺省 `~/.config/systemd/user`)—— systemd user 单元的标准位置。 */
export function systemdUserDir(env: Record<string, string | undefined> = process.env): string {
  const xdg = env.XDG_CONFIG_HOME?.trim();
  const base = xdg ? path.resolve(xdg) : path.join(userHome(env), ".config");
  return path.join(base, "systemd", "user");
}

/** 把「装哪个 unit」这件事一次算清:路径、内容、启动命令、日志目录。 */
export function servicePlan(
  kind: SupervisorKind,
  paths: KernelPaths,
  env: Record<string, string | undefined> = process.env,
): ServicePlan {
  const programArguments = resolveProgramArguments();
  const logDir = path.join(paths.home, LOG_DIR_NAME);
  // launchd 不读 shell profile(launchd/systemd 都一样),A2_HOME 必须写进 unit ——
  // 否则系统托管的实例会去管 `~/.a2`,而不是你安装时指定的那个 home。
  const environment = { A2_HOME: paths.home };

  if (kind === "launchd") {
    return {
      kind,
      label: SERVICE_LABEL,
      unitPath: path.join(launchAgentsDir(env), `${SERVICE_LABEL}.plist`),
      unitContent: renderLaunchdPlist({
        label: SERVICE_LABEL,
        programArguments,
        environment,
        stdoutPath: path.join(logDir, STDOUT_LOG_NAME),
        stderrPath: path.join(logDir, STDERR_LOG_NAME),
      }),
      programArguments,
      logDir,
      paths,
    };
  }

  return {
    kind,
    label: SERVICE_LABEL,
    unitPath: path.join(systemdUserDir(env), `${SERVICE_LABEL}.service`),
    unitContent: renderSystemdUnit({ programArguments, environment }),
    programArguments,
    logDir,
    paths,
  };
}

export interface UnitSpec {
  label: string;
  programArguments: string[];
  environment: Record<string, string>;
  stdoutPath?: string;
  stderrPath?: string;
}

/** XML 文本转义(路径里出现 `&` 之类不是奇谈:home 目录名什么都可能有)。 */
function xmlEscape(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

/**
 * launchd user 域 plist。
 *
 * `KeepAlive` 只给 `Crashed`(而不是 `true`):崩溃(SIGSEGV 等)由 launchd 重拉,
 * 而**显式停服(SIGTERM)不重拉** —— 否则 `a2 service uninstall` 之外的任何停都会被系统顶回来。
 * `ThrottleInterval` 写成默认值 10s,是为了让"崩溃循环会被节流"这件事在文件里看得见。
 *
 * **两端语义的一处不对称(实测,已知并接受)**:launchd 的 `Crashed` 按 man page 只认"典型崩溃信号"
 * —— 本机实测 SIGSEGV / SIGABRT 会重拉(各约 9s,即 ThrottleInterval),而 **`kill -9`(SIGKILL)不会**
 * (launchd 视之为"有人存心弄死它");systemd 的 `Restart=on-failure` 则把任何信号致死都算 failure,
 * 因此 Linux 那边 `kill -9` 也会重拉。两边都符合各自的"崩溃自愈"承诺,差别只在 SIGKILL 这一格。
 */
export function renderLaunchdPlist(spec: UnitSpec): string {
  const lines: string[] = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    "<dict>",
    "\t<key>Label</key>",
    `\t<string>${xmlEscape(spec.label)}</string>`,
    "\t<key>ProgramArguments</key>",
    "\t<array>",
    ...spec.programArguments.map((arg) => `\t\t<string>${xmlEscape(arg)}</string>`),
    "\t</array>",
  ];

  const environmentKeys = Object.keys(spec.environment).sort();
  if (environmentKeys.length > 0) {
    lines.push("\t<key>EnvironmentVariables</key>", "\t<dict>");
    for (const key of environmentKeys) {
      lines.push(
        `\t\t<key>${xmlEscape(key)}</key>`,
        `\t\t<string>${xmlEscape(spec.environment[key] as string)}</string>`,
      );
    }
    lines.push("\t</dict>");
  }

  lines.push(
    "\t<key>RunAtLoad</key>",
    "\t<true/>",
    "\t<key>KeepAlive</key>",
    "\t<dict>",
    "\t\t<key>Crashed</key>",
    "\t\t<true/>",
    "\t</dict>",
    "\t<key>ThrottleInterval</key>",
    "\t<integer>10</integer>",
  );

  if (spec.stdoutPath) {
    lines.push("\t<key>StandardOutPath</key>", `\t<string>${xmlEscape(spec.stdoutPath)}</string>`);
  }
  if (spec.stderrPath) {
    lines.push("\t<key>StandardErrorPath</key>", `\t<string>${xmlEscape(spec.stderrPath)}</string>`);
  }

  lines.push("</dict>", "</plist>", "");
  return lines.join("\n");
}

/**
 * systemd 的值里有空格/引号就得加引号(ExecStart 与 Environment 同一套词法)。
 *
 * **`%` 必须写成 `%%`,而且与加不加引号无关**:`%` 是 systemd 的 specifier 前缀(`%h` = home、`%i` = 实例名……),
 * 展开发生在**解析 unit 文件**的时候,引号拦不住它 —— 一个名字里带 `%h` 的目录会在 ExecStart 里被换成家目录。
 * 转义规则是文档明写的 `%%` → 字面 `%`,且在 `ExecStart=` 与 `Environment=` 两种值里同样成立,故在此统一做掉。
 *
 * **`$` 有意不转义**:它的展开是**上下文相关**的 —— `ExecStart=` 里 `$VAR`/`${VAR}` 会被展开(转义写 `$$`),
 * 而 `Environment=` 的值里根本不做变量展开(在那里写 `$$` 只会得到字面的两个美元符)。一个函数没法同时对两处
 * 都做对,故这里只保证「有 `$` 就加引号」这一层,真要处理 `$` 应当由调用点按自己的语境决定。
 */
function systemdQuote(value: string): string {
  const escaped = value.replaceAll("%", "%%");
  if (!/[\s"'\\$%]/.test(value)) return escaped;
  return `"${escaped.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

/**
 * systemd user 单元。
 *
 * `Restart=on-failure` 是 `KeepAlive.Crashed` 的对位物:非零退出与信号致死都重拉,
 * 干净退出(0)不重拉;`RestartSec=10` 对位 launchd 的 `ThrottleInterval`。
 * 日志不重定向 —— systemd 世界里 stdout/stderr 默认进 journal(`journalctl --user -u com.a2.kernel`),
 * 这是 Linux 用户预期的地方,不必再造一份文件日志。
 */
export function renderSystemdUnit(spec: Omit<UnitSpec, "label">): string {
  const environmentKeys = Object.keys(spec.environment).sort();
  return [
    "[Unit]",
    "Description=a2 kernel (agent-first local proxy kernel)",
    "After=network.target",
    "",
    "[Service]",
    "Type=simple",
    `ExecStart=${spec.programArguments.map(systemdQuote).join(" ")}`,
    ...environmentKeys.map(
      (key) => `Environment=${systemdQuote(`${key}=${spec.environment[key] as string}`)}`,
    ),
    "Restart=on-failure",
    "RestartSec=10",
    "",
    "[Install]",
    "WantedBy=default.target",
    "",
  ].join("\n");
}
