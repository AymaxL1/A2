# 地图:URL 分流进 A2

Label: wayfinder:map
铺图会话:2026-09-03(两轮 grilling 现场裁定见 Notes)
**已收图**:2026-09-03,六票全关,Destination 达成 —— [spec.md](spec.md) 定稿(CR 通过),
施工按 spec §14 另立 effort。

## Destination

一份定稿 spec(`.scratch/url-router/spec.md`):把参考项目 claude-url-router-agent-kit 的
URL 分流能力收进 A2 —— A2 Panel.app 注册为系统默认浏览器,按域名把 URL 派给 Roxy 指定
profile 或兜底浏览器,决策与配置归内核。spec 覆盖能力契约、协议、门禁断言与 ADR 修订清单,
达到「施工票可以直接从它开出」的成熟度。施工本身另立 effort,不在本图。

## Notes

- **参考项目(语义母本)**:`/Users/Shared/Workspaces/claude-url-router-agent-kit` ——
  照抄语义、移植实现。核心源码 `ClaudeURLRouter.swift`(约 560 行,决策核心约百余行),
  接管脚本 `set-as-default.sh` 已实证「第三方 CLI 进程可替任意 bundle id 注册 http/https handler」。
- **技能**:HITL 票(grilling 型)双开 `grilling` + `domain-modeling`;research 票走 `research`
  技能,findings 落 `research/<slug>` 分支(AGENTS.md:调研文档即使被否也合入 main)。
- **执行偏好**:本图遵 wayfinder 默认 plan-only;闭环 legwork 子代理用 Opus 5(用户既定偏好);
  提交风格照 AGENTS.md(中文 conventional commits)。
- **硬红线**:别删 CLT;别碰用户现存 mihomo;research 实验一律只读——**严禁真实改动本机默认浏览器**。
- **关键 ADR**:0004(capability 注册表唯一调用面)、0005(agent-first / CLI 永不交互阻塞)、
  0008(壳不得含业务逻辑 + 裁决序)、0012(面板自足引导)。

### 已裁前提(铺图现场,2026-09-03)

1. **终点 = spec 定稿**,施工另立票(沿本仓 spec → issues 流程)。
2. **handler = A2 Panel.app**:加 `CFBundleURLTypes`(http/https)注册 Launch Services;
   「设为 A2(内核 bin)」不可行 —— macOS 默认浏览器必须是 .app bundle。
   决策/配置/执行进内核新能力,壳只转发,守 ADR 0008 红线。
3. **语义原样照抄**:routedDomains(claude/anthropic 系)→ Roxy 指定 profile
   (CDP → API → launcher 三级降级),其余 → 兜底浏览器。不泛化。
4. **转发路径**:壳经既有 UDS capability 面转发 URL;内核不可达时壳做唯一一条机械兜底 ——
   把 URL 原样交给兜底浏览器。该兜底作为 0008 红线的**显式豁免**写进 spec/ADR。
5. **接管仪式**:`a2 url-router takeover|restore` 内核命令(风险级 dangerous,与 proxy on/off
   同构),面板只做入口按钮;卸载流程加前置(还是默认浏览器时先 restore)。
6. **配置落点**:`~/.a2` 内核域(含敏感 API Key,只留本机、不入 git)。
7. **命名**:子命令组 `a2 url-router`;中文术语「URL 分流」,避开代理域「路由」(已入 CONTEXT.md)。

## Decisions so far

<!-- 只收已关票:一票一行,gist + 链接。铺图现场裁定见上方 Notes,不重复。 -->

- [01 默认 handler API 事实](issues/01-default-handler-api-facts.md):选 NSWorkspace 新 API
  (macOS 12+),completion 在用户点完系统弹框后回调 —— 接管结果可感知;候选列表条件照抄
  参考 Info.plist 组合;免 CLT 路线以「壳当机械执行器」最优,裁定归 04/05。
  findings:[docs/research/url-router-default-handler.md](../../docs/research/url-router-default-handler.md)。
- [02 TS 移植平台事实](issues/02-ts-port-platform-facts.md):ps/lsof/fetch 直译可行
  (热路径 <100ms);唯一真坑是 `/json/new?` 的 `#` 编码差异;RoxyBrowser 纯配置值替换;
  附移植对照草表。findings:[docs/research/url-router-ts-port-facts.md](../../docs/research/url-router-ts-port-facts.md)。
- [03 壳兜底浏览器的配置来源](issues/03-shell-fallback-config-source.md):持久化快照
  (UserDefaults)+ Safari 保底;ADR 0008 豁免四条硬边界(不解析 URL / 不匹配域名 /
  唯一分支=内核可达 / 只吃推送快照);兜底首次节流通知,内核恢复重置。
- [04 接管确认 UX](issues/04-takeover-confirmation-ux.md):一道确认,系统弹框=确认器
  (可复用原则:OS 强制 + 不可伪造 + 结果可感知);执行器=壳(UDS 指令 + completion 回传),
  未跑自动拉起、未装才拒;CLI 有界等待 120s → `confirmation_timeout`,无 GUI 即拒 + 指引;
  restore 同级 dangerous。
- [05 卸载前置修订](issues/05-uninstall-precondition-revision.md):面板卸载 restore 打头、
  拒即中止;install.sh --uninstall 加第四条前置(还接管就拒删 bin);野路径只诊断不动手
  (status 识悬空 + 修复指引);restore 目标失效报错 + `--to` 显式覆写。
- [06 spec 定稿](issues/06-spec-final.md):[spec.md](spec.md) CR 通过 —— 能力契约五条、
  确认模型复用既有退出码词表、壳转发零新帧、门禁 APP14/15、ADR 0008 修订 + 新 0015、
  验收清单与六步切票建议。

## Not yet specified

(空 —— 已收图,全部雾已毕业或消散。)

<!-- 已毕业:门禁断言细目 —— spec §11 列全(APP14/15 + kernel 测试面 + 施工期实测清单)。 -->

<!-- 已毕业:UDS 转发协议细节 —— 03 裁定「配置快照推送 + 持久缓存」后,剩余帧形态细节
     全部归 06 spec(该票 Question 已列),不再是雾。 -->
<!-- 已消散:壳长期不在场的体验姿势 —— LS 点击即拉起 handler(01),退出 A2 连带内核停
     (ADR 0008 修订)→ 兜底 + 节流通知(03/04),降级故事闭环,写进 06 spec 体验章即可。 -->

## Out of scope

- 泛化「域名 → 任意目标」映射表(本次语义原样;要做是将来另一 effort)。
- 施工与实机部署(填 Roxy 参数、真机验收)—— 目的地是 spec,施工票另立。
- 独立 router 小 .app / URL 分流器单独分发(铺图裁定弃,走 Panel+内核)。
- 非 mac 端(ADR 0001 mac-only)。
