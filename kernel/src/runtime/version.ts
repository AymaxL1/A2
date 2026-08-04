// 内核版本(单一来源:package.json)。`bun build --compile` 会把这份 JSON 一并打进 bin,
// 所以编译产物与源码运行报的是同一个版本号,不存在两处手抄的漂移。

import pkg from "../../package.json";

export const KERNEL_VERSION: string = pkg.version;
