# 07 — 系统代理接管/还原

**What to build:** `proxy.system.enable|disable`(normal):接管前快照系统代理原状态,启用时把系统 HTTP/HTTPS/SOCKS 代理指向 mihomo 监听端口,停用与正常退出时还原到快照状态——退出后网络立即恢复直连。`aa proxy on|off` 全程零 GUI 打断(旗舰场景的核心一环)。

**Blocked by:** 06

**Status:** done(`8f5c3e5`;接管态持久化后经 `854cb63`/`38b5eac`/`bf5ab58` 审后收口)

**验证环:** vfsoverlay(今天可验;改系统代理需管理员账户,真机断言经 networksetup 读回)。

- [ ] 接管前快照记录原系统代理状态;enable → 系统代理指向内核端口,disable → 精确还原快照
- [ ] 宿主正常退出:停内核 + 还原系统代理,E2E 脚本验证退出后系统设置已复原
- [ ] 快照/还原判定为纯逻辑,经假件测试覆盖(含「原本就有第三方代理」的还原用例)
- [ ] `aa proxy on|off` 为 normal 级零确认,输出与退出码守 03 票契约
- [ ] check.sh 全绿
