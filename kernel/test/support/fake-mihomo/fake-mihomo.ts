// 假 mihomo 的本体(测试替身)。**不做任何真实代理行为**,只提供检测面需要的两样东西:
//   * `-v` → 真 mihomo 那一行版本输出(检测的版本判据就是解析它);
//   * `-d <目录> -f <配置>` → 按配置里的 `external-controller` / `secret` 起一个 HTTP 服务,
//     暴露 06 票用得到的**只读**子集:`GET /version`、`GET /configs`、`GET /proxies`。
//
// 形态沿用旧仓 `Scripts/fake-mihomo.py` 的那套(真子进程 + localhost REST 子集),
// 换成 TS 只是为了不再依赖 python3,并且能直接用 Bun.serve。
//
// 环境旋钮(测试用):
//   A2_FAKE_MIHOMO_VERSION  伪造版本号(默认 v1.19.28;用低版本可触发兼容地板不达标)
//   A2_FAKE_MIHOMO_META     "0" = /version 的 meta 为假(伪造成非 mihomo 系内核)
//   A2_FAKE_MIHOMO_NO_CONFIGS "1" = GET /configs 返回 500(伪造能力位缺失)

const argv = process.argv.slice(2);
const version = process.env.A2_FAKE_MIHOMO_VERSION ?? "v1.19.28";
const meta = process.env.A2_FAKE_MIHOMO_META !== "0";
const configsBroken = process.env.A2_FAKE_MIHOMO_NO_CONFIGS === "1";

if (argv.includes("-v") || argv.includes("--version") || argv.includes("-version")) {
  // 真 mihomo 的 `-v` 首行形态(`Mihomo Meta v1.19.28 darwin arm64 with gc go1.24.5 …`)。
  console.log(`Mihomo Meta ${version} darwin arm64 with gc go1.24.5 Mon Jul 7 00:00:00 UTC 2026`);
  process.exit(0);
}

function flag(name: string): string | undefined {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : undefined;
}

const configPath = flag("-f");
if (!configPath) {
  console.error("fake mihomo:没给 -f <配置文件>");
  process.exit(2);
}

const text = await Bun.file(configPath)
  .text()
  .catch(() => undefined);
if (text === undefined) {
  console.error(`fake mihomo:读不到配置 ${configPath}`);
  process.exit(2);
}

const scalar = (key: string): string | undefined =>
  new RegExp(`^[ \\t]*${key}[ \\t]*:[ \\t]*(.+?)[ \\t]*$`, "m").exec(text)?.[1]?.trim();

const controller = scalar("external-controller");
if (!controller) {
  console.error(`fake mihomo:配置里没有 external-controller(${configPath})`);
  process.exit(2);
}
const secret = scalar("secret");
const port = Number.parseInt(controller.slice(controller.lastIndexOf(":") + 1), 10);
const mode = scalar("mode") ?? "rule";
const mixedPort = Number.parseInt(scalar("mixed-port") ?? "7890", 10);

function authorized(request: Request): boolean {
  if (!secret) return true;
  return request.headers.get("authorization") === `Bearer ${secret}`;
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port,
  fetch(request) {
    const route = new URL(request.url).pathname;
    if (!authorized(request)) return new Response("unauthorized", { status: 401 });
    if (route === "/version") return Response.json({ version, meta });
    if (route === "/configs") {
      if (configsBroken) return new Response("boom", { status: 500 });
      return Response.json({ mode, "mixed-port": mixedPort, port: 0, "socks-port": 0, "allow-lan": false });
    }
    if (route === "/proxies") {
      return Response.json({
        proxies: {
          DIRECT: { type: "Direct" },
          GLOBAL: { type: "Selector", now: "DIRECT", all: ["DIRECT"] },
        },
      });
    }
    return new Response("not found", { status: 404 });
  },
});

// 真 mihomo 收到 SIGTERM 干净退出(main.go);假件照办,好让 supervisor 的停/重启语义成立。
const stop = () => {
  server.stop(true);
  process.exit(0);
};
process.on("SIGTERM", stop);
process.on("SIGINT", stop);

console.log(`fake mihomo ${version} listening on ${server.hostname}:${server.port} (config ${configPath})`);
