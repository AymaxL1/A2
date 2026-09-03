# 02 capability/CLI 面 + contract golden

Status: claimed
Blocked by: 01

## Question

spec §3/§4:五条能力上注册表 —— `url-router.status`(safe)/`decide`(safe)/
`route`(normal)/`takeover`(dangerous)/`restore`(dangerous),域子命令
`a2 url-router …` 等价写法;输入输出 schema 落 `kernel/contract/schema` + golden 快照。

- route 的执行侧:探测(ps/lsof)、CDP(GET/PUT + AbortSignal.timeout)、
  Roxy API、`open -b`,按 02 研究票实测形状落地;URL 独立 argv。
- takeover/restore 本票只落**契约与幂等判据**(handler 已是目标 → `already:true`),
  执行编排(壳指令帧)归 04 票 —— 在此之前调用返回结构化「执行器未接线」错误。
- 幂等/错误码/`--dry-run`(= decide)/退出码对齐 docs/agents/a2-cli.md。

验收:capabilities list 可见五条(带 risk);contract golden 更新;bun test 绿。

## Comments
