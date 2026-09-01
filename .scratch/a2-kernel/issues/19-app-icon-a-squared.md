# 19 — 图标落地:v3「A²」→ .icns + 菜单栏 template(用户选稿)

**What to build:** 用户从 8 张概念稿中选定 **v3「A²」**(`assets/branding/concepts/aymax-logo-concept-v3-a-squared.png`)。据其**程序化重绘**母版(概念稿是 AI 海报小样,不可直接裁用):CoreGraphics/CoreText 脚本生成 1024 母版 → iconset → `AppIcon.icns`;同一字形出**菜单栏 template 单色版**;接线 `Scripts/build-app.sh`(CFBundleIconFile + 新 APP 断言)与 `A2MenuBarController`(文字「A2」换 template 图标,dev 无 bundle 时回落文字)。README 待办勾销 + 纠正其中一处错误口径。

设计规格(编排会话已定,不重议):
- **App 图标**:Big Sur 圆角方**画在素材里**(macOS 不代裁圆角——iOS 才是;README 现有「系统自己裁圆角,素材给直角」是错的,顺手改正),遵循 HIG 网格(1024 画布、约 824 中置圆角方、留投影边距);**主选陶土橙底 + 米白「A²」**(色值从 v3 小样取样),同时产出黑底变体存 `assets/branding/` 备选不接线。
- **字形**:系统粗黑无衬线(SF Pro / Helvetica Bold 族,经 CoreText 渲染),大写 A + 右上角上标 2(约 40% 字号,基线抬高),布局照 v3 小样比例。
  > **19 票实施记(两个目测值均被实测推翻,依本条主句「布局照 v3 小样比例」照实测落地)**:
  > 「上标**约 40% 字号**」出自**本票面**(即上一行);「A 高约占方的 **55–60%**」出自**编排提示词**
  > (编排会话已认领)。对 v3 右下角两个圆角方小样做像素测量(连通域拆 A 与 2,黑/橙两版交叉验证,
  > 一致到 1%):上标高 / A 高 = 0.321 与 0.308 → 取 **0.315**;A 的 cap 高 / 方边 = 0.472 与 0.465
  > → 取 **0.470**。两个目测值都偏大,成品**照实测**。门禁有断言钉住这两个数
  > (`A2BrandAssetTests`;变异:把上标比改成票面那个 0.40 → 当场红)。
- **菜单栏**:同一 A² 字形的单色 template(黑 + alpha,`isTemplate=true`,18×18pt 提供 @1x/@2x),随系统明暗自动变色;代理接管中的「●」指示以 image+title 并存方式保留。
- **可复现**:生成脚本入库(如 `Scripts/gen-app-icon.swift`,swift 单文件可直跑),产物(母版 PNG、.icns、template PNG)一并入库——重跑脚本必须能逐字节或像素级重现(如有系统字体渲染的微差,如实记录判据)。

**Blocked by:** brand 整理(51f65ed,已落地)。

**Status:** done

- [x] 生成脚本 + 母版 1024(陶土橙主选 / 黑底备选)+ iconset 全档 + `AppIcon.icns` + 菜单栏 template @1x/@2x,全部入库于 `assets/branding/`(产物)与 `Scripts/`(脚本);脚本可重跑,产物与脚本一致有断言或如实判据
      → `Scripts/gen-app-icon.swift`(单文件,`swift Scripts/gen-app-icon.swift` 直跑;**不能 import AppKit**,解释器 JIT 加载不了 ObjC 类,实测记在文件头)。15 个产物。**判据是逐字节**:`--verify` 重跑到临时目录与入库产物 `Data ==` 比,本机连跑两次全同(含 `.icns`)——画的是字形轮廓路径,不经 hinting;跨机/跨系统版本不承诺(SF Pro 随系统更新)。另有门禁层的几何断言(`A2BrandAssetTests`,10 条)。
- [x] build-app.sh:`AppIcon.icns` → `Contents/Resources/`,Info.plist 写 `CFBundleIconFile`;新增 APP 断言(icns 在包内、`sips`/`iconutil` 可解、尺寸档齐);APP8 可执行计数不受影响(icns 非可执行)
      → **APP12**(icns:在 + `CFBundleIconFile` 对 + `iconutil -c iconset` 往返解得开 + 十档齐 + 最大档 `sips` 问出 1024)与 **APP13**(菜单栏 template 两档 18/36px)。三个文件都以 644 拷入,APP8 清单一个字不变(实测)。清单现为 APP1–APP13,`check.sh` 两处标签同步。
- [x] A2MenuBarController:statusItem 用 template 图标(从 Bundle 取,dev/swift build 无资源时回落现有文字「A2」,行为有测试);「A2 ●」接管指示语义保留(image + 「●」title);相关断言更新;菜单内容快照不受影响(核实 golden 零漂移,受影响则重录并说明)
      → 新 `A2MenuBarIcon`(取图,资源目录可注入)+ `A2MenuBarPresentation`(纯函数,两输入四组合)。控制器只剩接线。**golden 零漂移已核实**:状态栏那一格不进 `A2MenuModel`,`Snapshots/a2-panel/` 一张没动。
- [x] `assets/branding/README.md`:待办 1–4 勾销/更新,纠正「系统自己裁圆角」错误口径;Finder/Dock 实看效果留一条人工项(LSUIElement 无 Dock 图标,实看主要在 Finder/打开面板)
      → 待办 1–4 勾销、口径纠正写在原处(macOS 圆角画进素材,iOS 才是系统裁);新增成品清单 + 设计参数节 + 两条人工项(Finder 实看 / 菜单栏明暗实看)。
- [x] 门禁 8 步全绿;变异验证:icns 从包里抽走 → 新 APP 断言红;template 资源抽走 → 回落文字的测试仍绿且回落行为断言在
      → 门禁 **步 PASS=8 FAIL=0**(bun 458 · swift **228**(+20)· e2e 46 · 插件 50 · APP1–APP13)。变异三组(另加两组加强)全部「红 → 还原 → 绿」,明细见 nightlog 19 票节。

**CR 尾款(2026-08-11,双轴过 + 7 条尾款,一轮收掉)**:`--verify` 的 `defer` 死码(`exit()` 不跑 defer,
每跑一次漏一个临时目录)已修 —— 主体收进返回 Bool 的函数、`exit` 留在函数外;`superscriptOverlapRatio 0.180`
补上量化断言(七个设计常量至此全部被门禁钉住);iconset 那条测试标题不再冒领「原生重画」;
**圆角方向词写反已翻转**(半径占比小 = 更方 ⇒ 小样比 HIG 略方、成品比小样略圆),脚本头 + nightlog 两处;
票面「40% 字号」的出处与推翻过程补记在设计规格节;README 补「逐字节只在同机同系统承诺」与
`templateCapRatio = 0.72`;`docs/v1-roadmap.md:110` 的硬编码条数改为「以 build-app.sh 的 APP 清单为准」。
