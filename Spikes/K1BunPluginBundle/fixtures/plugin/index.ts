// K1 spike —— 带 npm 依赖的「目录插件」样本。
// 协议照 13 票：exec 一次一调，describe 出清单、call 走 stdin/stdout JSON、退出码即成败。
import pc from "picocolors";
import probe from "a2-lifecycle-probe";

const TOOLS = [
  { name: "echo", dangerous: false, input: { text: "string" } },
  { name: "boom", dangerous: false, input: {} },
];

const deps = {
  picocolors: typeof pc.green === "function",
  probe: probe.probeName,
};

const mode = process.argv[2];

if (mode === "describe") {
  console.log(JSON.stringify({ ok: true, plugin: "k1-dep-plugin", deps, tools: TOOLS }));
  process.exit(0);
}

if (mode === "call") {
  const raw = await Bun.stdin.text();
  let req: any;
  try {
    req = JSON.parse(raw);
  } catch {
    console.log(JSON.stringify({ ok: false, error: "bad_json" }));
    process.exit(2);
  }
  const text = String(req?.input?.text ?? "");
  switch (req?.tool) {
    case "echo":
      console.log(
        JSON.stringify({
          ok: true,
          tool: "echo",
          output: {
            text,
            upper: text.toUpperCase(),
            colored: pc.green(text), // 非 TTY 下 picocolors 自动降级为原文
            probe: probe.probeName,
            pid: process.pid,
            cwd: process.cwd(),
          },
        }),
      );
      process.exit(0);
    case "boom":
      console.log(JSON.stringify({ ok: false, tool: "boom", error: "deliberate_failure" }));
      process.exit(3);
    case "throw":
      throw new Error("k1 uncaught");
    default:
      console.log(JSON.stringify({ ok: false, error: "unknown_tool", tool: req?.tool ?? null }));
      process.exit(4);
  }
}

console.log(JSON.stringify({ ok: false, error: "usage", want: ["describe", "call"] }));
process.exit(64);
