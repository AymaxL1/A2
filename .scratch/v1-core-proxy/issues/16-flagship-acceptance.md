# 16 — 旗舰场景验收(Phase 1 出口)

**What to build:** 验收辞逐字兑现:「Codex 经 `aa` 开代理/切节点全程零 GUI 打断;换订阅源必触发宿主确认」。产出 E2E 验收脚本(模拟 agent 只经 `aa` 完成 开代理→切模式→选节点→更新已有订阅 全链,断言零确认弹窗、输出与退出码全对)+ 真 Codex 实测记录(含 prefix_rule 一次批准后沙箱外执行的完整路径)+ 换源场景批准/拒绝两分支点验记录。

**Blocked by:** 05, 07, 09, 10, 12

**Status:** ready-for-agent(脚本部分可在 05/07/09/10 完成后先行;正式验收以 `.app` 形态为准)

**验证环:** 脚本可先行(vfsoverlay 期即可跑),正式验收需 Xcode(`.app` + 13 票签名就位后)。

- [ ] E2E 脚本:normal 全链零 GUI 打断,全程仅经 `aa`,断言逐步输出与退出码
- [ ] 真 Codex 按 `aa docs agents-md` 引导接入,prefix_rule 一次批准后完成旗舰操作,留实测记录
- [ ] 换源:Codex 发起 → 宿主弹确认;批准/拒绝两分支行为与记录齐全
- [ ] 验收结论回写 roadmap Phase 1 状态行(通过即 Phase 1 出口)
