// 假 `networksetup` 的本体(测试替身)。**门禁绝不碰真的系统代理** —— 这是本票最硬的纪律之一:
// 用户此刻的网络很可能正靠他自己的代理活着,把系统代理留在坏状态 = 用户断网 = 事故。
// 所以内核里那个 `NetworkSetupPort` 整条可注入,而门禁里注入的就是这个文件。
//
// 它不是打桩:状态真的落在一个 JSON 文件里(形状与旧仓 `netfake-state.json` 逐字段相同),
// 读写都作用在同一份状态上,所以"接管 → 还原 → 终态逐字段等于接管前"是可以真断言的。
//
// 支持的子命令(内核实际会发的全部,多一条都没有):
//   -listallnetworkservices
//   -getwebproxy / -getsecurewebproxy / -getsocksfirewallproxy            <service>
//   -setwebproxy / -setsecurewebproxy / -setsocksfirewallproxy            <service> <host> <port>
//   -setwebproxystate / -setsecurewebproxystate / -setsocksfirewallproxystate <service> on|off
//
// 环境旋钮:
//   A2_FAKE_NETSETUP_STATE      状态文件路径(必需)
//   A2_FAKE_NETSETUP_LOG        调用日志(每行一条完整 argv;红线核对用)
//   A2_FAKE_NETSETUP_FAIL_AT    **恰好第 N 次**写调用失败,其余照常(验"接管写到一半失败要回滚"——
//                               回滚本身也要发写调用,所以故障必须是一次性的,不能是"从此以后都失败")
//   A2_FAKE_NETSETUP_LIST_FAIL  "1" = -listallnetworkservices 非零退出(验读实况失败的处置)

import { appendFileSync, readFileSync, writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const statePath = process.env.A2_FAKE_NETSETUP_STATE;
if (!statePath) {
  console.error("fake networksetup:需要 A2_FAKE_NETSETUP_STATE(测试夹具没设好)");
  process.exit(127);
}
const logPath = process.env.A2_FAKE_NETSETUP_LOG;
if (logPath) appendFileSync(logPath, `networksetup ${argv.join(" ")}\n`);

interface Setting {
  enabled: boolean;
  host: string;
  port: number;
}
interface ServiceState {
  service: string;
  http: Setting;
  https: Setting;
  socks: Setting;
}

type Kind = "http" | "https" | "socks";

const GET: Record<string, Kind> = {
  "-getwebproxy": "http",
  "-getsecurewebproxy": "https",
  "-getsocksfirewallproxy": "socks",
};
const SET: Record<string, Kind> = {
  "-setwebproxy": "http",
  "-setsecurewebproxy": "https",
  "-setsocksfirewallproxy": "socks",
};
const STATE: Record<string, Kind> = {
  "-setwebproxystate": "http",
  "-setsecurewebproxystate": "https",
  "-setsocksfirewallproxystate": "socks",
};

function load(): ServiceState[] {
  return (JSON.parse(readFileSync(statePath as string, "utf8")) as { services: ServiceState[] }).services;
}

function save(services: ServiceState[]): void {
  writeFileSync(statePath as string, `${JSON.stringify({ services }, null, 2)}\n`);
}

function find(services: ServiceState[], name: string): ServiceState {
  const found = services.find((entry) => entry.service === name);
  if (!found) {
    console.error(`** Error: The parameters were not valid. (${name})`);
    process.exit(1);
  }
  return found;
}

/** 写调用的计数落在状态文件旁边 —— 假件是每次调用一个新进程,内存里存不住计数。 */
function bumpWriteCount(): number {
  const counterPath = `${statePath}.writes`;
  let count = 0;
  try {
    count = Number.parseInt(readFileSync(counterPath, "utf8").trim(), 10) || 0;
  } catch {
    count = 0;
  }
  count += 1;
  writeFileSync(counterPath, `${count}\n`);
  return count;
}

function guardWriteFailure(): void {
  const failAt = Number.parseInt(process.env.A2_FAKE_NETSETUP_FAIL_AT ?? "", 10);
  if (!Number.isFinite(failAt) || failAt <= 0) return;
  if (bumpWriteCount() === failAt) {
    console.error("** Error: The parameters were not valid.");
    process.exit(1);
  }
}

const verb = argv[0] ?? "";

if (verb === "-listallnetworkservices") {
  if (process.env.A2_FAKE_NETSETUP_LIST_FAIL === "1") {
    console.error("** Error: Could not list network services.");
    process.exit(1);
  }
  // 真 networksetup 的首行是说明抬头,内核会跳过它;`*` 前缀 = 已禁用的服务,内核也会跳过。
  console.log("An asterisk (*) denotes that a network service is disabled.");
  for (const entry of load()) console.log(entry.service);
  console.log("*Disabled Service");
  process.exit(0);
}

if (GET[verb]) {
  const services = load();
  const setting = find(services, argv[1] ?? "")[GET[verb] as Kind];
  console.log(`Enabled: ${setting.enabled ? "Yes" : "No"}`);
  console.log(`Server: ${setting.host}`);
  console.log(`Port: ${setting.port}`);
  console.log("Authenticated Proxy Enabled: 0");
  process.exit(0);
}

if (SET[verb]) {
  guardWriteFailure();
  const services = load();
  const entry = find(services, argv[1] ?? "");
  const port = Number.parseInt(argv[3] ?? "0", 10);
  if (!Number.isFinite(port) || port <= 0 || (argv[2] ?? "").length === 0) {
    console.error("** Error: The parameters were not valid.");
    process.exit(1);
  }
  entry[SET[verb] as Kind] = { enabled: true, host: argv[2] as string, port };
  save(services);
  process.exit(0);
}

if (STATE[verb]) {
  guardWriteFailure();
  const services = load();
  const entry = find(services, argv[1] ?? "");
  const kind = STATE[verb] as Kind;
  if ((argv[2] ?? "") === "on") {
    entry[kind] = { ...entry[kind], enabled: true };
  } else {
    // 真 networksetup 的 `state off` 只关开关、不清 Server/Port;a2 读回时按"关"归一
    // (host 空 / port 0),所以这里直接归一,状态文件与内核的读回口径一致。
    entry[kind] = { enabled: false, host: "", port: 0 };
  }
  save(services);
  process.exit(0);
}

console.error(`** Error: Unknown option ${verb}`);
process.exit(1);
