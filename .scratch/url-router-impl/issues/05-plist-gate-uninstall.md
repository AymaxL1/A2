# 05 Info.plist/门禁断言 + 卸载双路径前置

Status: open
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
