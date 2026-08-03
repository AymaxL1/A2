# 04 — dangerous 宿主确认纵切

**What to build:** 平台信任面机制正式化:调用 dangerous 能力时,CLI 不交互阻塞——宿主 GUI 弹出最终确认,批准则执行并回成功,拒绝则回 denied 语义与专属退出码;确认永远落宿主 GUI,agent/CLI 无法绕过(注册表路由层强制,非 CLI 自律)。S2 spike 的两分支点验模式在正式核上重建。

**Blocked by:** 03

**Status:** done(`4842d96`)

**验证环:** vfsoverlay(今天可验,GUI 弹窗直编可跑,两分支需真机点验)。

- [ ] demo dangerous 能力:批准 → 执行成功、退出码 0;拒绝 → denied、专属非零退出码
- [ ] 确认策略在 Runtime 纯逻辑层有假件测试(含「无 GUI 可用时拒绝执行」的保底行为)
- [ ] 经 UDS 直接构造请求也无法跳过确认(E2E 反向用例)
- [ ] 真机点验批准/拒绝两分支并留记录
- [ ] check.sh 全绿
