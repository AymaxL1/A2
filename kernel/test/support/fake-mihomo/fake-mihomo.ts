// 假 mihomo 的本体(测试替身)。**不做任何真实代理行为**,只提供内核实际会用到的那几条 REST。
//
// 形态沿用旧仓 `Scripts/fake-mihomo.py`(真子进程 + localhost REST 子集),换成 TS 只是为了不依赖 python3。
//
// **它是有状态的**,这一点很重要:07 票要验的行为大多是"改了之后读回来变了"——
// 切模式、选节点、整份重载。打桩式的固定应答验不了这些,所以这里真的把状态存在进程里,
// 并且 `PUT /configs {path}` 会**真的重新读那份文件**并重建状态(这就是"重载"在假件里的字面实现)。
//
// 分组与延迟表从**配置文件里的注释行**读(真 mihomo 会忽略注释,所以同一份配置对真核也是合法的):
//   `# fake-groups: PROXY=A1,A2;GLOBAL=A1`   分组 → 候选节点(第一个候选即初始 now)
//   `# fake-delays: A1=120;A2=300`           节点 → 延迟毫秒;**表里没有的节点 = 超时**
// 这样"激活订阅之后分组变了"是端到端可观察的:订阅正文经 a2 渲染进 config.yaml,假件重载后读到新分组。
//
// 环境旋钮(测试用):
//   A2_FAKE_MIHOMO_VERSION     伪造版本号(默认 v1.19.28;用低版本可触发兼容地板不达标)
//   A2_FAKE_MIHOMO_META        "0" = /version 的 meta 为假(伪造成非 mihomo 系内核)
//   A2_FAKE_MIHOMO_NO_CONFIGS  "1" = GET /configs 返回 500(伪造能力位缺失)
//   A2_FAKE_MIHOMO_REJECT_RELOAD "1" = PUT /configs 一律 400(伪造"内核不认这份配置",验回滚)

const argv = process.argv.slice(2);
const version = process.env.A2_FAKE_MIHOMO_VERSION ?? "v1.19.28";
const meta = process.env.A2_FAKE_MIHOMO_META !== "0";
const configsBroken = process.env.A2_FAKE_MIHOMO_NO_CONFIGS === "1";
const rejectReload = process.env.A2_FAKE_MIHOMO_REJECT_RELOAD === "1";

if (argv.includes("-v") || argv.includes("--version") || argv.includes("-version")) {
  // 真 mihomo 的 `-v` 首行形态(`Mihomo Meta v1.19.28 darwin arm64 with gc go1.24.5 …`)。
  console.log(`Mihomo Meta ${version} darwin arm64 with gc go1.24.5 Mon Jul 7 00:00:00 UTC 2026`);
  process.exit(0);
}

function flag(name: string): string | undefined {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : undefined;
}

const bootConfigPath = flag("-f");
if (!bootConfigPath) {
  console.error("fake mihomo:没给 -f <配置文件>");
  process.exit(2);
}

interface Group {
  name: string;
  type: string;
  now: string;
  all: string[];
}

interface State {
  configPath: string;
  mode: string;
  mixedPort: number;
  allowLan: boolean;
  logLevel: string;
  secret?: string;
  groups: Map<string, Group>;
  delays: Map<string, number>;
}

function scalar(text: string, key: string): string | undefined {
  return new RegExp(`^[ \\t]*${key}[ \\t]*:[ \\t]*(.+?)[ \\t]*$`, "m").exec(text)?.[1]?.trim();
}

/**
 * `# fake-groups: PROXY=A1,A2;GLOBAL=A1` → 分组表(**保序**:第一个候选就是初始 now)。
 * 配置里没写这行时回落到 `A2_FAKE_MIHOMO_GROUPS`(同样的语法)—— 让"分组从哪来"与"订阅"两件事
 * 在测试里可以分开验:验分组/选节点/测速时不必先造一条订阅。
 */
function parseGroups(text: string): Map<string, Group> {
  const groups = new Map<string, Group>();
  const line =
    /^#[ \t]*fake-groups:[ \t]*(.+)$/m.exec(text)?.[1] ?? process.env.A2_FAKE_MIHOMO_GROUPS;
  if (!line) return groups;
  for (const chunk of line.split(";")) {
    const [name, nodes] = chunk.split("=");
    if (!name || !nodes) continue;
    const tokens = nodes.split(",").map((node) => node.trim());
    const all = tokens.filter((node) => node.length > 0);
    if (all.length === 0) continue;
    // **第一个 token 就是 `now`**;写成空(`GLOBAL=,A1`)即模拟真核里"这个组没有当前选中"
    // 的形态(真核回 `now: ""`,内核那边要归一成缺省 —— 这正是要验的那条)。
    groups.set(name.trim(), {
      name: name.trim(),
      type: "Selector",
      now: tokens[0] as string,
      all,
    });
  }
  return groups;
}

/** `# fake-delays: A1=120;A2=300` → 延迟表。**表里没有的节点就是超时**(这正是要验的那条)。 */
function parseDelays(text: string): Map<string, number> {
  const delays = new Map<string, number>();
  const line =
    /^#[ \t]*fake-delays:[ \t]*(.+)$/m.exec(text)?.[1] ?? process.env.A2_FAKE_MIHOMO_DELAYS;
  if (!line) return delays;
  for (const chunk of line.split(";")) {
    const [node, value] = chunk.split("=");
    const ms = Number.parseInt((value ?? "").trim(), 10);
    if (node && Number.isFinite(ms)) delays.set(node.trim(), ms);
  }
  return delays;
}

async function loadState(configPath: string, previous?: State): Promise<State> {
  const text = await Bun.file(configPath)
    .text()
    .catch(() => undefined);
  if (text === undefined) throw new Error(`读不到配置 ${configPath}`);
  const groups = parseGroups(text);
  // 重载时,同名分组的当前选中**尽量沿用**(真核在候选仍在时也是这个行为)。
  if (previous) {
    for (const [name, group] of groups) {
      const before = previous.groups.get(name);
      if (before && group.all.includes(before.now)) group.now = before.now;
    }
  }
  const port = Number.parseInt(scalar(text, "mixed-port") ?? "7890", 10);
  return {
    configPath,
    mode: scalar(text, "mode") ?? "rule",
    mixedPort: Number.isFinite(port) ? port : 7890,
    allowLan: scalar(text, "allow-lan") === "true",
    logLevel: scalar(text, "log-level") ?? "info",
    ...(scalar(text, "secret") ? { secret: scalar(text, "secret") as string } : {}),
    groups,
    delays: parseDelays(text),
  };
}

let state: State;
try {
  state = await loadState(bootConfigPath);
} catch (error) {
  console.error(`fake mihomo:${String(error)}`);
  process.exit(2);
}

const bootText = await Bun.file(bootConfigPath).text();
const controller = scalar(bootText, "external-controller");
if (!controller) {
  console.error(`fake mihomo:配置里没有 external-controller(${bootConfigPath})`);
  process.exit(2);
}
const port = Number.parseInt(controller.slice(controller.lastIndexOf(":") + 1), 10);

/**
 * 鉴权用的 secret 取**启动那一刻**那份配置里的值 —— 真 mihomo 的控制端点也是启动时确定的,
 * 后续 `PUT /configs` 换配置不会把已经连着的客户端踢下线。
 */
const bootSecret = scalar(bootText, "secret");

function authorized(request: Request): boolean {
  if (!bootSecret) return true;
  return request.headers.get("authorization") === `Bearer ${bootSecret}`;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(request) {
    const url = new URL(request.url);
    const route = url.pathname;
    if (!authorized(request)) return new Response("unauthorized", { status: 401 });

    if (route === "/version") return json({ version, meta });

    if (route === "/configs") {
      if (request.method === "GET") {
        if (configsBroken) return new Response("boom", { status: 500 });
        return json({
          mode: state.mode,
          "mixed-port": state.mixedPort,
          port: 0,
          "socks-port": 0,
          "allow-lan": state.allowLan,
          "log-level": state.logLevel,
        });
      }
      if (request.method === "PATCH") {
        const patch = (await request.json().catch(() => ({}))) as Record<string, unknown>;
        if (typeof patch["mode"] === "string") {
          const mode = patch["mode"];
          if (!["rule", "global", "direct"].includes(mode)) {
            return json({ message: `unsupported mode: ${mode}` }, 400);
          }
          state.mode = mode;
        }
        if (typeof patch["allow-lan"] === "boolean") state.allowLan = patch["allow-lan"];
        // 真核约定:写成功回 204。
        return new Response(null, { status: 204 });
      }
      if (request.method === "PUT") {
        if (rejectReload) return json({ message: "configuration rejected by fake mihomo" }, 400);
        const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;
        const nextPath = typeof body["path"] === "string" ? body["path"] : undefined;
        if (!nextPath) return json({ message: "path is required" }, 400);
        try {
          state = await loadState(nextPath, state);
        } catch (error) {
          return json({ message: String(error) }, 400);
        }
        return new Response(null, { status: 204 });
      }
      return new Response("method not allowed", { status: 405 });
    }

    if (route === "/proxies") {
      const proxies: Record<string, unknown> = { DIRECT: { type: "Direct" } };
      for (const group of state.groups.values()) {
        proxies[group.name] = { type: group.type, now: group.now, all: group.all };
      }
      return json({ proxies });
    }

    if (route.startsWith("/proxies/") && request.method === "PUT") {
      const name = decodeURIComponent(route.slice("/proxies/".length));
      const group = state.groups.get(name);
      if (!group) return json({ message: `proxy not found: ${name}` }, 404);
      const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;
      const node = typeof body["name"] === "string" ? body["name"] : "";
      if (!group.all.includes(node)) return json({ message: `node not in group: ${node}` }, 400);
      group.now = node;
      return new Response(null, { status: 204 });
    }

    const delayMatch = /^\/group\/(.+)\/delay$/.exec(route);
    if (delayMatch) {
      const name = decodeURIComponent(delayMatch[1] as string);
      const group = state.groups.get(name);
      if (!group) return json({ message: `group not found: ${name}` }, 404);
      const result: Record<string, number> = {};
      for (const node of group.all) {
        const delay = state.delays.get(node);
        // **表里没有的节点直接缺席**(而不是给个 0)—— 内核要据此如实标注 timeout。
        if (delay !== undefined) result[node] = delay;
      }
      return json(result);
    }

    return new Response("not found", { status: 404 });
  },
});

// 真 mihomo 收到 SIGTERM 干净退出(main.go);假件照办,好让停/重启语义成立。
// `A2_FAKE_MIHOMO_IGNORE_SIGTERM=1` = 「卡死不理 SIGTERM」档(14 票):
// 验 stop() 的宽限→SIGKILL 升级与认尸补刀,没有这一档那两条路径就是零覆盖。
const stop = () => {
  server.stop(true);
  process.exit(0);
};
if (process.env["A2_FAKE_MIHOMO_IGNORE_SIGTERM"] === "1") {
  process.on("SIGTERM", () => {});
} else {
  process.on("SIGTERM", stop);
}
process.on("SIGINT", stop);

console.log(`fake mihomo ${version} listening on ${server.hostname}:${server.port} (config ${bootConfigPath})`);
