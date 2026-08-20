// 服务「单元」层:unit 文件长什么样、落在哪儿、里面跑哪条命令。
//
// **纯计算**:只产出字符串与路径,不碰 launchctl/systemctl(那是 supervisor.ts 的事),也不写盘。
// 这样"内容对不对""路径对不对"两件事在测试里可以逐字断言,而不必真的装一次服务。
//
// 自愈与自启全在这份内容里(ADR 0008 第 6 条 + 14 票修订):launchd `KeepAlive.{Crashed,SuccessfulExit:false}` + `RunAtLoad`,
// systemd `Restart=on-failure` + `WantedBy=default.target`。应用层不造看门狗 —— 内核崩了由系统重拉,
// 内核被显式停掉(SIGTERM)则**不**重拉(两种 supervisor 的语义在这一点上恰好一致)。

import { homedir } from "node:os";
import path from "node:path";
import type { SupervisorKind } from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";

/**
 * 内核自己的 unit 名。**launchctl/systemctl 的所有目标都由 plan.label 拼出**,
 * 而 plan.label 只可能是本文件这两个常量之一 —— 任何命令行参数、任何环境变量都改不了它
 * (`a2 service` / `a2 mihomo` 都不接受 label 参数,这是有意的边界)。
 */
export const SERVICE_LABEL = "com.a2.kernel";

/**
 * **旧版** a2 自管 mihomo 的 unit 名(06 票立,14 票退场)。
 *
 * 14 票(ADR 0014)起内核**不再写这个 unit** —— mihomo 是 daemon 的直接子进程,全机只剩
 * `com.a2.kernel` 一个 unit。常量保留下来只为一件事:**认得自己的遗产并拆掉它**
 * (`enable --mode=embedded` 的迁移、`service uninstall --purge` 的兜底)。
 * 「数据面不随控制面起落」随之废除 —— a2 死则 mihomo 死,这正是「小白第一」下要的心智模型。
 */
export const MIHOMO_SERVICE_LABEL = "com.a2.mihomo";

/** 覆写 supervisor 选择。**仅供测试与诊断**:在 macOS 上跑一遍 Linux 代码路径(实机验收顺延)。 */
export const SUPERVISOR_ENV = "A2_SERVICE_SUPERVISOR";

/** 日志目录与两个重定向文件(launchd 必须显式指定,否则输出去向不可依赖;systemd 走 journal)。 */
export const LOG_DIR_NAME = "log";
export const STDOUT_LOG_NAME = "kernel.out.log";
export const STDERR_LOG_NAME = "kernel.err.log";
/**
 * a2 内嵌 mihomo 子进程的日志(与内核同一个 log 目录、不同文件名 —— 两条命的日志不该混在一起看)。
 * 14 票起由 `src/mihomo/child.ts` 直接把子进程的 stdout/stderr 重定向到这两个文件(不再经 unit)。
 */
export const MIHOMO_STDOUT_LOG_NAME = "mihomo.out.log";
export const MIHOMO_STDERR_LOG_NAME = "mihomo.err.log";

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
 * Bun 编译产物特有的虚拟文件系统前缀(实测:编译后 `Bun.main` = `/$bunfs/root/<名字>`)。
 * 「本进程是不是一个可分发的单文件」这条判据**全仓只此一处**(15 票:`--copy-to-home` 也问它)。
 */
export const COMPILED_MAIN_PREFIX = "/$bunfs/";

/** 本进程是不是 `bun build --compile` 出来的单文件产物(而不是源码跑的开发态)。 */
export function isCompiledBin(): boolean {
  return Bun.main.startsWith(COMPILED_MAIN_PREFIX);
}

/**
 * unit 里要跑的那条命令。三种形态:
 *   * `binPath` 给了(15 票 `--copy-to-home`)→ `<拷贝> daemon run`,与本进程是什么形态无关;
 *   * 编译产物(`bun build --compile`)→ `<bin> daemon run`;
 *   * 源码跑(开发/测试)→ `<bun> run <入口> daemon run`。
 */
export function resolveProgramArguments(binPath?: string): string[] {
  if (binPath !== undefined) return [binPath, "daemon", "run"];
  return isCompiledBin()
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

export interface ServicePlanOptions {
  /**
   * unit 里要跑的可执行(15 票 `--copy-to-home`:`$A2_HOME/bin/a2` 那份拷贝)。
   * 不给则由 `resolveProgramArguments()` 按本进程形态自己算 —— 不带旗标时行为一字不变。
   */
  binPath?: string;
}

/** 把「装哪个 unit」这件事一次算清:路径、内容、启动命令、日志目录。 */
export function servicePlan(
  kind: SupervisorKind,
  paths: KernelPaths,
  env: Record<string, string | undefined> = process.env,
  options: ServicePlanOptions = {},
): ServicePlan {
  const programArguments = resolveProgramArguments(options.binPath);
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

/**
 * **旧版** `com.a2.mihomo` unit 的**移除专用** plan(14 票 / ADR 0014)。
 *
 * 14 票起 mihomo 是 daemon 的直接子进程,内核**再也不写这个 unit** —— 所以渲染族
 * (`MihomoUnitSpec` / `mihomoServicePlan`)整族删码。留下的只有「怎么把它拆掉」:
 *   * `a2 mihomo enable --mode=embedded` 检出它 → bootout + 删 plist(自己的遗产自己收);
 *   * `a2 service uninstall --purge` 的兜底路径继续认得这个 label。
 *
 * 因此 `unitContent` 恒为空串:移除路径从不写文件,只 unload + unlink。
 * `programArguments` 仍照旧版的 argv 形状拼(`<bin> -d <data> -f <config>`)—— 它是
 * `service/manager.ts::unitRecordedHome` 判「盘上这份 unit 是给哪个 `$A2_HOME` 装的」的指纹,
 * 那条判断读的正是旧 unit 里写着的 argv[0]。**红线**:label 恒是 `com.a2.mihomo`,
 * 别人装的 mihomo(`io.metacubex.mihomo` 等)在任何路径下都进不了这个 plan。
 */
export function legacyMihomoRemovalPlan(
  kind: SupervisorKind,
  paths: KernelPaths,
  mihomo: { binaryPath: string; dataDir: string; configPath: string },
  env: Record<string, string | undefined> = process.env,
): ServicePlan {
  return {
    kind,
    label: MIHOMO_SERVICE_LABEL,
    unitPath:
      kind === "launchd"
        ? path.join(launchAgentsDir(env), `${MIHOMO_SERVICE_LABEL}.plist`)
        : path.join(systemdUserDir(env), `${MIHOMO_SERVICE_LABEL}.service`),
    unitContent: "",
    programArguments: [mihomo.binaryPath, "-d", mihomo.dataDir, "-f", mihomo.configPath],
    logDir: path.join(paths.home, LOG_DIR_NAME),
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
 * `KeepAlive` 是双键 `{Crashed:true, SuccessfulExit:false}`(14 票 / 03 研究,OR 语义):
 *   * `Crashed` 管典型崩溃信号(SIGSEGV/SIGABRT,实测约 ThrottleInterval 后重拉);
 *   * `SuccessfulExit:false` 补上 **`kill -9` 那一格** —— man page 的 `Crashed` 不把 SIGKILL 当崩溃
 *     (「有人存心弄死它」),而 jetsam 杀内存大户用的恰是 SIGKILL;`SuccessfulExit:false` 按
 *     「非 0 退出就重拉」兜住它(信号致死无退出码,算非 0;03 票实测 SIGKILL 后约 30s 重拉)。
 *   * **代价是一条红线**:一切主动停止路径(uninstall bootout、daemon 正常关闭)必须以 **exit 0**
 *     收尾,否则 launchd 会把刚停的服务顶回来 —— daemon 的退出钩子(`cli/daemon.ts`)为此负责。
 * `ThrottleInterval` 写成默认值 10s,是为了让"崩溃循环会被节流"这件事在文件里看得见。
 * systemd 的 `Restart=on-failure` 本就把信号致死都算 failure,两端自此对齐(SIGKILL 一格不再不对称)。
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
    "\t\t<key>SuccessfulExit</key>",
    "\t\t<false/>",
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
export function renderSystemdUnit(spec: Omit<UnitSpec, "label"> & { description?: string }): string {
  const environmentKeys = Object.keys(spec.environment).sort();
  return [
    "[Unit]",
    `Description=${spec.description ?? "a2 kernel (agent-first local proxy kernel)"}`,
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

// MARK: - 反向:从**盘上那份 unit** 里读回它实际要跑的可执行(15 票)

/**
 * 已装好的 unit 实际指向的可执行(argv[0])。**解不动就返回 undefined**(不是本内核写的 / 被人改坏了)——
 * 调用方据此回落到「本次调用会写的那个」,所以这里绝不猜:猜错就是给面板一个假的托管事实。
 *
 * 为什么非读盘不可:`servicePlan()` 算出来的是「**这次调用会写**什么」,而 `service status` 的
 * `binPath` 要答的是「**盘上那份现在指着**什么」。面板正是靠这个区别判断"内核该不该升级" ——
 * 若拿本次调用的计划值冒充事实,面板从 .app 里跑一次 status 就会看到 .app 内那份 bin,
 * 而 unit 其实指着 `$A2_HOME/bin/a2` 的拷贝。那不是不精确,是假话。
 *
 * 两个渲染器各有一个反向物,与它们**逐条对位**(有往返断言守着:render → parse ≡ 原 argv[0])。
 */
export function unitBinaryPath(kind: SupervisorKind, content: string): string | undefined {
  return kind === "launchd" ? launchdBinaryPath(content) : systemdBinaryPath(content);
}

/** `renderLaunchdPlist` 的反向:ProgramArguments 数组里的头一个 `<string>`。 */
function launchdBinaryPath(content: string): string | undefined {
  const block = /<key>ProgramArguments<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(content)?.[1];
  if (block === undefined) return undefined;
  const first = /<string>([\s\S]*?)<\/string>/.exec(block)?.[1];
  return first === undefined ? undefined : xmlUnescape(first);
}

/** `xmlEscape` 的反向。`&amp;` **必须最后还原**,否则 `&amp;lt;` 会被两步吃成 `<`。 */
function xmlUnescape(value: string): string {
  return value.replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&amp;", "&");
}

/**
 * 盘上那份 unit 记着的 `A2_HOME`(17 票 CR 尾款)。**解不动就返回 undefined**,同 `unitBinaryPath`:
 * 绝不猜 —— 这个值是 `--purge` 的一道 fail-closed 门,猜错就是把别人那个 home 的数据删了。
 *
 * 为什么它答得了「这份服务是给谁装的」:`servicePlan()` 把安装时的 `A2_HOME` **写进了 unit**
 * (supervisor 不读 shell 配置,不写进去托管实例就会去管 `~/.a2`)。于是盘上那份 unit 里的
 * 这一格,就是"这台机器上正被托管的那个内核服务的是哪个 home"的**唯一事实**。
 *
 * 与 `unitBinaryPath` 同一条纪律:两个渲染器各有一个反向物,逐条对位,有往返断言守着
 * (render → parse ≡ 原 home,含带空格 / `&` / `%` 的病态路径)。
 */
export function unitHomePath(kind: SupervisorKind, content: string): string | undefined {
  return kind === "launchd" ? launchdHomePath(content) : systemdHomePath(content);
}

/** `renderLaunchdPlist` 的反向:`EnvironmentVariables` 那个 dict 里 `A2_HOME` 后面紧跟的那个 `<string>`。 */
function launchdHomePath(content: string): string | undefined {
  const block = /<key>EnvironmentVariables<\/key>\s*<dict>([\s\S]*?)<\/dict>/.exec(content)?.[1];
  if (block === undefined) return undefined;
  const value = /<key>A2_HOME<\/key>\s*<string>([\s\S]*?)<\/string>/.exec(block)?.[1];
  return value === undefined ? undefined : xmlUnescape(value);
}

/**
 * `renderSystemdUnit` 的反向:`Environment=` 那行里的 `A2_HOME=…`。
 *
 * 渲染时整条 `KEY=VALUE` 一起过 `systemdQuote`,所以这里也整条取回来再拆第一个 `=` ——
 * 分开处理会在"值里带空格因而整条被加了引号"那种真实路径上读出半截。
 */
function systemdHomePath(content: string): string | undefined {
  for (const match of content.matchAll(/^Environment=(.*)$/gm)) {
    const token = systemdFirstToken(match[1] as string);
    if (token === undefined) continue;
    const separator = token.indexOf("=");
    if (separator <= 0) continue;
    if (token.slice(0, separator) === "A2_HOME") return token.slice(separator + 1);
  }
  return undefined;
}

/** `renderSystemdUnit` 的反向:`ExecStart=` 那行的头一个词(按 `systemdQuote` 的词法拆)。 */
function systemdBinaryPath(content: string): string | undefined {
  const line = /^ExecStart=(.*)$/m.exec(content)?.[1];
  return line === undefined ? undefined : systemdFirstToken(line);
}

/**
 * `systemdQuote` 的反向,只取头一个词。两种形态:带引号的(值里有空格/引号/反斜杠/`$`/`%`)与裸的。
 * `%%` → 字面 `%` 的还原对两种形态都要做(转义发生在加引号**之前**,见 `systemdQuote`)。
 */
function systemdFirstToken(line: string): string | undefined {
  const text = line.trimStart();
  if (text.length === 0) return undefined;
  if (!text.startsWith('"')) {
    const end = /\s/.exec(text)?.index ?? text.length;
    return text.slice(0, end).replaceAll("%%", "%");
  }
  let token = "";
  for (let index = 1; index < text.length; index += 1) {
    const char = text[index] as string;
    // `systemdQuote` 只会转义 `\` 与 `"` 两种,别的反斜杠原样留着。
    if (char === "\\" && index + 1 < text.length) {
      const next = text[index + 1] as string;
      token += next === "\\" || next === '"' ? next : `\\${next}`;
      index += 1;
      continue;
    }
    if (char === '"') return token.replaceAll("%%", "%");
    token += char;
  }
  // 引号没闭合 —— 不是本内核写出来的东西,不猜。
  return undefined;
}
