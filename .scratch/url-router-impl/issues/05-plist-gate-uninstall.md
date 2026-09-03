# 05 Info.plist/门禁断言 + 卸载双路径前置

Status: claimed
Blocked by: 04

## Question

spec §7(Info.plist)/§9(卸载)/§11(门禁):

- build-app.sh:Info.plist 加 `CFBundleURLTypes`(http+https,Owner)+
  `CFBundleDocumentTypes`(public.html/xhtml/url,Viewer);断言 APP14/APP15;
  可执行清单 APP8 一字不动。
- 面板卸载序列:restore 打头、拒/超时即中止 + 指引,再走既有 proxy off →
  service uninstall → 删文件。
- `install.sh --uninstall` 第四条前置:com.a2.panel 仍是默认 handler 就拒删 bin
  (检测途径在此票定,POSIX sh 无 jq 约束);
  `kernel/test/install-script.test.ts` 加断言。
- `url-router.status` 补悬空诊断(handler 指向已删 bundle → 修复指引)。

验收:check.sh 出包步 APP1–15 全绿;install-script 测试绿。

## Comments

- 2026-09-04 实施完毕(分支 `feature/url-router-05-plist-gate-uninstall`,五笔提交):
  - `3becf7a` feat(app):Info.plist 认领 http/https + APP14/15
  - `483d708` feat(install):卸载第四条前置(还挂着默认浏览器就拒删 bin)
  - `c7d7a3c` feat(kernel):`url-router.status` 的悬空诊断
  - `cb13b14` feat(kernel):purge 的第四道门(`service_purge_url_handler_taken`)
  - `e21d20d` feat(panel):卸载序列 restore 打头,拒即中止

  **门禁**:`bash Scripts/check.sh` 八步全绿(bun test 655 条 / swift test 283 条 /
  旗舰 e2e 50 / 插件 e2e 50 / 出包 APP1–APP15)。出包实跑 **APP1–APP15 全 PASS**;
  APP14 的"恰为"判据做过反证(往 plist 里塞第三个 scheme `ftp` 会被拒)。
  两侧测试数:bun 655(新增 23)、swift 283(新增 7)。

  **四条 CR 口径**(每条都写进了代码注释,这里只列判据):
  1. **install.sh 第四条前置不依赖 daemon**:`defaults export` 读 LaunchServices 的用户设定表,
     `com.a2.panel` 出现即拒。判据**宁可宽,不可漏**(那张表只记用户显式设过的 default;
     宽的代价是多跑一次幂等的 restore,漏的代价是删完再也还原不回去)。没有 `defaults`(Linux)跳过。
  2. **内核 purge 的⓪e 只拦"确知挂着"**:任一 scheme 是 com.a2.panel 就拦(半个接管照样有链接来找它);
     读不出来(null)**不拦** —— 未能判定 ≠ 确知挂着,拦下去会把 Linux 与没装过 Panel 的机器全堵死。
     排在五道门最后:它是唯一要起子进程的判据。错误码归退出码 1,与 `service_purge_blocked` 同档。
  3. **悬空诊断 fail-open**:`mdfind` 空结果要再问一次**对照探询**(`com.apple.finder`);
     连它都查不到 = Spotlight 不答话 → 报"未能判定",不报悬空。**不用 `open -b`**(那会真拉起 app)。
     `handler.dangling` 用 `min(1)`:空数组会让「诊断过、干净」与「没做过诊断」在机读面上长得一样。
  4. **诊断只在 status**:takeover/restore 的回执里那份 handler 不带 dangling —— 那一刻系统状态正在变。

  **与 spec / 底账的偏差:一处,已记账并写进 ADR 0012 修订**
  票面预案是「面板卸载序列**经会话**调 `url-router.status` / `.restore`」。实施改走**内嵌 bin
  白名单**(`url-router status --json` / `url-router restore --json`),理由是硬的:
  壳自己就是 `url-router.restore` 的机械执行器 —— 内核收到这条命令要**反向推**一帧执行指令给壳。
  若这条命令由壳自己经会话发出,会话线程此刻正阻塞在 `awaitResponse` 上,那帧指令会被缓冲进推送
  队列**永不派发**:内核等满 120s、壳等到连接报废,一次互等的死锁。走内嵌 bin 时发起方是**另一个
  进程**(子进程 a2 CLI),会话线程照常空闲在 `nextPush` 上,弹框正常出现。
  代价如实记:`restore` 是白名单里唯一会等人的命令(至多 120s),等待期间引导面锁在「卸载中…」。
  裁定语义**一个字没变**(restore 打头 / 拒即中止 / 指引原样转达 / 壳零业务判断),变的只是通道。
  白名单因此恰增两条(共十二条,**takeover 不在里面**);ADR 0012 第 3 条与第 6 条各加一条修订。

  **顺带修的两处小账**:①`test/support/fake-url-router/defaults` 改用纯内建命令 —— 沙盒把 PATH
  钉死成假 supervisor 目录时它原来会静默失败成"读不出来",而那恰好是本该被拦下的用例会安静通过的
  样子;②`Scripts/check.sh` 的步骤标题 APP1–APP13 → APP1–APP15。

  **留给 06 的**:ADR 0015 新立与 ADR 0008 第 5 条修订(spec §10,本票只补了 0012 的两条修订);
  真机验收 —— 弹框实感、悬空自动回落的实测断言、`.app` 真的出现在「默认网页浏览器」候选里。
