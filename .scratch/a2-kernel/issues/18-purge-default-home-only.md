# 18 — purge 收紧:只对默认 `~/.a2` 生效(用户裁定)

**What to build:** 用户对 17 票遗留裁定项(「护栏是地板不是白名单」)的拍板:**`--purge` 只在解析后的 home 等于默认 `~/.a2` 时放行;任何自定义 `A2_HOME` → 结构化拒绝 + 提醒,不删**(指明当前 home 是哪、并给「自定义 home 请自行清理」的自助口径)。这一刀把 `/Applications`、`~/Documents` 之类「既非根也非家目录的普通目录」整类错误从根上封死。既有四道闩(接管态 / 地板 / symlink / 站错 home)全部保留作纵深,不回退。面板不受影响(面板恒用默认 home)。

**Blocked by:** 17(已落地,HEAD 131e933)。

**Status:** done — 941b053(CR 尾款 e629909:站错 home 的指引原是死路 —— 让人到那个 home 重跑 --purge 会被 ⓪0 再拒,改为三条自助口径)—— 941b053 purge 收紧为 default-home-only(自定义 A2_HOME 一律拒、零删除;四道旧闩全保留作纵深)

- [x] 判据:`paths.home` 解析值 ≠ `os.homedir()/.a2` → 结构化拒绝、零删除;相等放行(显式 `A2_HOME=~/.a2` 等价写法也放行,比较用归一化后的绝对路径)
- [x] 错误码按 `exit-codes.ts` 纪律归档(复用 `service_purge_unsafe_home`(6)或新码,二选一并说理——语义是「purge 在自定义 home 上永远不成立」,不是「等会儿再来」);guidance 指明当前 home 路径与自助清理口径;金标含拒绝样本并过 context 键集对账
- [x] 既有四道闩与其测试全保留;新增:自定义 home 拒绝用例(拒后零删除)+ 默认 home 放行用例;变异验证:判据去掉 → 拒绝用例红
- [x] `usage.ts` / `docs/agents/a2-cli.md` / `docs/runbooks/distribution.md` 口径同步(「--purge 只对默认 ~/.a2 生效」);面板文案不需改(恒默认 home),核一眼确认
- [x] 17 票遗留裁定项在 nightlog 记「已裁:default-home-only,18 票落地」;门禁 8 步全绿
