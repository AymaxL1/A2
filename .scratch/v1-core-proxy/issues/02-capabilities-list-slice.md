# 02 — 纵切:`aa capabilities list`

**What to build:** 第一发曳光弹:宿主进程雏形(裸状态栏项、起 UDS server)注册一个 demo 能力,`aa capabilities list --json` 经 UDS 拿到能力清单。穿透 Contracts(manifest/能力描述/IPC 协议类型)→ Runtime(注册表)→ HostMacOS(UDS server)→ aa(CLI)四层,每层只做 list 所需的最小切面。

**Blocked by:** 01

**Status:** done(`068805f`)

**验证环:** vfsoverlay(今天可验,S2 已证宿主进程与 UDS 可直编运行)。

- [ ] 宿主进程可启动:状态栏可见、UDS server 在监听
- [ ] `aa capabilities list --json` 输出含 demo 能力的 id、风险级、schema 摘要
- [ ] 宿主未运行时 `aa` 以明确错误信息与非零退出码失败(完整 UX 归 05 票,这里只保底不挂死)
- [ ] Runtime 注册表逻辑有经 TestKit 假件的纯逻辑测试;E2E 有脚本断言输出与退出码
- [ ] check.sh 全绿
