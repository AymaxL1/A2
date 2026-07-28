# 12 — XcodeGen app 壳

**What to build:** 产品形态成型:XcodeGen 工程定义入库(生成物不入库),产出 LSUIElement 菜单栏应用——`.app` 内打包宿主、`aa` 可执行与 mihomo 内核资源;`xcodegen generate → xcodebuild build` 全脚本化,双击 `.app` 即得完整宿主(状态栏项 + UDS server + 插件就位)。XCUITest target 建位(冒烟用例归 Phase 3,此处只立骨)。

**Blocked by:** 11

**Status:** ready-for-agent

**验证环:** 需 Xcode。

- [ ] 工程定义入库、可再生,生成物不入库
- [ ] `.app` 可启动:菜单栏可见、UDS 可连,`aa`(经 install-cli)对其全链可用
- [ ] mihomo 随 `.app` 内资源被 ProcessPort 正常拉起
- [ ] 构建脚本一条命令出 `.app`,进 check.sh 或独立构建脚本(归实施)
