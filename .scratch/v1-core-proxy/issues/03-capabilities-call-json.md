# 03 — 纵切:`aa capabilities call --json` 与退出码契约

**What to build:** 调用面成型:`aa capabilities call <id> --json` 对 safe 与 normal 能力全链执行(参数经 schema 校验、注册表路由、结果 JSON 回传);`aa capabilities describe <id> --json` 输出完整 schema。定死全命令面的机读契约:JSON 输出结构与退出码语义(成功/业务失败/协议错误/宿主未运行等),此后所有票沿用。

**Blocked by:** 02

**Status:** ready-for-agent

**验证环:** vfsoverlay(今天可验)。

- [ ] safe 与 normal 两个 demo 能力经 call 全链成功,normal 零 GUI 打断
- [ ] 参数不合 schema 时报错走统一 JSON 错误结构 + 对应退出码
- [ ] describe 输出足以让 agent 不读源码就能构造合法调用
- [ ] 退出码语义表落进 CLI 帮助/文档,E2E 脚本逐码断言
- [ ] check.sh 全绿
