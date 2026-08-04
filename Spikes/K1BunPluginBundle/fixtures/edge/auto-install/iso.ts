// 边界样本：静态 import 一个「本地肯定没装」的 npm 包，用来验 Bun 运行期 auto-install
// 的触发规则（祖先目录有没有 node_modules）。
import isOdd from "is-odd";
console.log(JSON.stringify({ ok: true, isOdd: typeof isOdd, three: isOdd(3) }));
