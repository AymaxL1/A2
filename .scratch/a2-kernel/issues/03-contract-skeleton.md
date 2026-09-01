# 03 — 契约骨架:kernel/ 工程 + TS 契约源 + `a2 daemon run` UDS 骨架

**What to build:** 蓝图第①步。仓库出现 `kernel/` TS 工程,能编译出单文件 bin `a2`:`a2 daemon run` 起 UDS server 常驻前台,另一终端 `a2 status --json` 打通请求-响应闭环。协议报文以 TS schema(zod 类)为单一事实源并可导出 JSON Schema。TS 门禁(`bun test`)从本票起步。Swift 侧一行不动,`check.sh` 保绿。

**Blocked by:** None — can start immediately。

**Status:** done — c872508 kernel/ 立起(2103 行:CLI+daemon+契约+测试),bun test 25/25、check.sh PASS=429 FAIL=0、编译产物 61.0MiB 实跑通

- [x] `kernel/` 工程可 `bun build --compile` 出单文件 `a2`;默认入口为 CLI 子命令,`a2 daemon run` 进前台常驻模式
  - `bash kernel/scripts/build.sh` → `kernel/dist/a2`(**63,991,010 字节 ≈ 61.0MiB**,bundle 93 modules / 编译 63ms);产物不入库(.gitignore)。
  - 入口 `src/cli/main.ts`:`status` / `daemon run` / `help` / `version`,`--json` 全局旗标;`a2 daemon run` 前台常驻(不 fork、不写 pid 文件、不造看门狗——service 归 05 票)。
- [x] daemon 在 `~/.a2/run/kernel.sock` 起 UDS server:父目录自建 0700,bind 后显式收紧 socket 权限(不信任 umask);`A2_HOME` 覆写生效
  - 实测产物输出:`drwx------ run` / `srw------- run/kernel.sock`(mkdir 的 mode 被 umask 削,故 mkdir 后补 chmod;socket 是 bind 后 chmod 0600)。
  - `A2_HOME` 覆写有专门测试(两个 home 各起各的 daemon,互不可见);默认 `~/.a2` 全程未被创建(实测确认 `~/.a2` 仍不存在)。
  - 陈旧 socket:先探活,连得上 = 拒绝启动(不抢别人的 socket),连不上 = 当残骸清掉;SIGTERM/SIGINT 干净收摊并删 socket 文件。
- [x] 基础报文族(请求/响应包封、结构化错误、拒绝即指引报文骨架)以 TS schema 定义,可导出 JSON Schema 文件
  - `src/contract/wire.ts`(zod 源):`RequestEnvelope` / `ResponseEnvelope`(ok 判别的成功|失败)/ `WireError` / `Guidance`(summary + steps[description,command] + context)/ `StatusResult`;NDJSON 帧,`id` 原样回填。
  - `bun run schema` → `kernel/contract/schema/*.schema.json`(5 份,draft-2020-12,入库);漂移由 `bun test` 逐字节对照兜住。
- [x] `a2 status --json` 对运行中 daemon 返回结构化状态,退出码 0;daemon 未运行时返回含精确修复指引的结构化错误、非零退出码、永不隐式拉起
  - 运行中:`{"ok":true,"result":{state,version,protocol,pid,startedAt,uptimeMs,home,socketPath}}`,exit 0,全程走 UDS 往返(不靠"socket 文件在不在"这类旁证)。
  - 未运行:`{"ok":false,"error":{"code":"daemon_unreachable",…,"guidance":{steps:[`a2 service install`,`a2 daemon run`],context:{socketPath,home}}}}`,**exit 4**;查询后 socket 仍不存在(永不隐式拉起,有断言)。
- [x] `bun test` 门禁建立并纳入契约快照测试雏形(schema 编解码金标样本);`check.sh` 全绿不受影响
  - `bun test` **25 pass / 0 fail**(源码入口与 `A2_TEST_BIN=dist/a2` 编译产物两种被测体跑同一批断言);`bun x tsc --noEmit` 干净。
  - 金标样本 12 份(手写,`kernel/contract/golden/` + index.json 清单):7 合法(往返逐字段不变)、5 非法(必须被拒)——09 票 Swift 手写 Codable 读同一批。
  - `bash Scripts/check.sh` → **PASS=429 FAIL=0**(exit 0),Swift 侧一行未动。日志 `/tmp/a2-check-03.log`。
