# 09 — 控制面能力包:模式/节点/组/测速

**What to build:** 代理日常操作面补齐,四能力经 mihomo REST 全通:`proxy.mode.set`(规则/全局/直连)、`proxy.groups.list`(组/节点/当前选中,safe)、`proxy.node.select`(按组选节点)、`proxy.latency.test`(按组 URL test,safe)。对应域子命令(`aa proxy mode|node|groups|ping` 等,命名归实施)让 Codex 与人类都能一条命令完成。

**Blocked by:** 06

**Status:** ready-for-agent

**验证环:** vfsoverlay(今天可验,需一份含多组多节点的测试配置)。

- [ ] 四能力风险级正确(读=safe,改状态=normal),normal 零 GUI 打断
- [ ] 模式切换/选节点后经 `proxy.status` 与 REST 读回验证生效
- [ ] 测速对指定组返回逐节点延迟,超时节点如实标注
- [ ] REST 客户端压在 Port 后,插件域逻辑经假件测试;E2E 对真内核断言
- [ ] check.sh 全绿
