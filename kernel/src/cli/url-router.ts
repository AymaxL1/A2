// `a2 url-router …` 的 argv 适配(02 票)。
//
// **它不是第二个解析器**,只有一次纯 argv 改写:把 spec §4 写给人看的那种写法翻译成域子命令
// 通用解析器认识的 `--名字 值`,之后仍旧交给 `domain.ts` ——别名匹配、类型强转、仲裁、
// 渲染、退出码,一条都不重写。
//
// 为什么非改写不可:别的域(`proxy` / `arbitration`)的入参全是 `--名字 值`,而 spec §4 给
// url-router 定的写法有两处不同形:
//
//   a2 url-router route <url> [--dry-run]
//                      ↑位置参数    ↑不是参数,是"换一条能力"
//
// 两处都是有意的产品决定,不是笔误:
//   * **URL 是位置参数** —— 这条命令的读者一多半不是人而是壳(收到 kAEGetURL 就转发),
//     `a2 url-router route <url>` 与系统交给我们的形状一致;而且 URL 作为独立 argv 传递,
//     全程不拼字符串、不经 shell,注入面为零(spec §4 末句)。
//   * **`--dry-run` 换的是能力不是参数** —— spec §3 写明 `url-router.decide` 就是
//     「CLI `route --dry-run` 的落点」。两者同一个 URL、同一份配置,只差执不执行,
//     所以它们是两条能力(一条 safe 一条 normal),而不是一条能力上的一个开关:
//     风险档必须在 manifest 上分得开,不能藏在参数里。

/** `route` / `decide` —— 收位置 URL 的那两个动作(别的动作原样透传)。 */
const URL_VERBS = new Set(["route", "decide"]);

/** `--dry-run` 落到哪条能力上(spec §3)。 */
const DRY_RUN_VERB = "decide";

/**
 * 把 spec §4 的人类写法改写成域子命令通用解析器认识的形状。
 *
 * 规则只有三条,别的 token 一律原样传下去(该报用法错的由通用解析器去报,这里不抢它的活):
 *   1. 动作是 `route` / `decide` 时,**第一个不以 `--` 开头、且不是 `--url` 的值**的 token → `--url <它>`;
 *   2. `--dry-run` 摘掉,动作换成 `decide`;
 *   3. 其余原样。
 *
 * 幂等:已经写成 `a2 url-router decide --url <u>` 的调用过一遍这里,一个字都不会变。
 */
export function normalizeUrlRouterArgs(args: string[]): string[] {
  const verb = args[0];
  if (verb === undefined || !URL_VERBS.has(verb)) return args;

  const out: string[] = [];
  let dryRun = false;
  let urlSupplied = false;

  for (let index = 1; index < args.length; index += 1) {
    const token = args[index] as string;
    if (token === "--dry-run") {
      dryRun = true;
      continue;
    }
    if (token.startsWith("--")) {
      if (token === "--url") urlSupplied = true;
      out.push(token);
      // `--url <值>` 的值可能长得像位置参数,得跟着一起走,免得下面把它再包一层 `--url`。
      const next = args[index + 1];
      if (token === "--url" && next !== undefined && !next.startsWith("--")) {
        out.push(next);
        index += 1;
      }
      continue;
    }
    if (!urlSupplied) {
      // 位置参数 → `--url <它>`。**只认第一个**:多给的那些原样传下去,由通用解析器报
      // 「多余的参数」(比在这里悄悄吃掉一个更好 —— 吃掉了人就不知道自己多打了一个)。
      out.push("--url", token);
      urlSupplied = true;
      continue;
    }
    out.push(token);
  }

  return [dryRun ? DRY_RUN_VERB : verb, ...out];
}
