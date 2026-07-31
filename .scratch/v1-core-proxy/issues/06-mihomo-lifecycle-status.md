# 06 — mihomo 子进程生命周期 + `proxy.status`

**What to build:** 代理插件第一发曳光弹:锁版 mihomo 内核作为 PluginProxy 私有资源入库;宿主 ProcessPort 负责拉起/健康检查/回收(特权面归宿主),插件经 REST 读内核状态(业务面归插件);`proxy.status`(safe)注册进注册表,`aa proxy status` 显示内核运行状态/监听端口/当前模式与节点。

**Blocked by:** 03

**Status:** ready-for-agent

**验证环:** vfsoverlay(今天可验,mihomo 为独立 Go 二进制可直接运行)。

- [x] 内核锁版入库(版本号记录在案),随宿主启停:宿主退出内核必回收,无孤儿进程
- [x] 健康检查:内核死亡可检测,状态反映真实存活
- [x] `aa proxy status --json` 输出真实内核状态;内核未运行时状态如实呈现而非报错
- [x] ProcessPort 有假件测试(插件域逻辑不依赖真进程);E2E 脚本对真内核断言
- [x] check.sh 全绿
