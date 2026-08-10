# 品牌资产(assets/branding/)

本目录是 a2 品牌资产的**唯一落点**。现状:只有概念稿,**尚无定稿、尚无任何成品图标**——
`A2 Panel.app` 目前没有 icon(Info.plist 无 `CFBundleIconFile`),菜单栏是纯文字「A2」。

## 品牌沿革(为什么这些文件叫 Aymax)

三代命名,后一代作废前一代:

1. **Aymax 期**(概念期):产品设想名「Aymax / Aymax Assistant / Aymax Tool」,本目录的
   8 张概念稿全部产于此期(原在 `feature/brand` 分支,提交语明写「刻意不进 main」)。
2. **AA 期**:仓名 PROJECT_AA、bundle id `com.aa.host` 等(已全面退场,见 build-app.sh 头注)。
3. **a2 命名系**(现行,spec 命名节钉死):bin `a2`、`~/.a2`、unit `com.a2.*`、
   壳「A2 Panel」(`com.a2.panel`)。2026-08-11 用户裁定把概念稿收回 main,作废「刻意不进」旧口径。

## 概念稿清单(concepts/,均为 AI 生成的选型草图,非矢量)

| 稿 | 内容 | 与现名的关系 |
|---|---|---|
| v1 | 双 A 组字,三角硬朗,负形星芒;落款「Aymax 助手 / PROJECT_AA」 | AA 期遗产 |
| v2 | 双 A 组字圆润版(anthropic 风),负形星芒;「Aymax Assistant」 | AA 期遗产 |
| **v3** | **A²(A 加上标 2)**,黑/陶土橙两版圆角方图标小样;「A² AYMAX」 | **与现名 a2 逐字吻合,天然候选** |
| v4 | A + 上标锤形(hammer-at);「Aymax Tool」 | 工具系 |
| v5 | A + 上标锤(superscript-hammer 变体) | 工具系 |
| v6 | A + 上标 T 形抽象锤;「Aymax Tool」 | 工具系 |
| v7 | A + 羊角锤(claw) | 工具系 |
| v8 | A + 前倾写实羊角锤;「Aymax Tool」 | 工具系 |

## 图标落地待办(依序,全部未做)

1. **选稿**(人裁):从 v1–v8 选一张方向稿,或据 v3 重做——文字落款一律要从 Aymax 换成 a2 系。
2. **出母版**:矢量重绘(SVG/PDF),含 App 图标版(macOS 圆角方,系统自己裁圆角,素材给直角)
   与**菜单栏 template 版**(单色、透明底、约 18×18pt@2x,`isTemplate=true` 随系统明暗变色)。
3. **生成 iconset**:`iconutil` 出 `.icns`(16–1024 全档)。
4. **接线**:`Scripts/build-app.sh` 拷入 `Contents/Resources/` + Info.plist 写 `CFBundleIconFile`
   (会新增一条 APP 断言);`A2MenuBarController` 的文字标题换 template 图标(快照全部重录)。
5. 提醒:换图标不改 bundle id,TCC 无代价;但 ad-hoc 下每次重出包 cdhash 都变(既有记账,
   见 `docs/runbooks/signing-and-authorization.md` §2.1),与图标无关但常被混为一谈。

改名代价三层(只改显示名便宜 / 改 bundle id 重置授权 / 改 a2 命名系是迁移票)另见
`docs/runbooks/distribution.md` 与 ADR 0012——图标选型不阻塞、也不被阻塞于改名裁定。
