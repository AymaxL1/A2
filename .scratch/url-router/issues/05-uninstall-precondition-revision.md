# 05 卸载双路径的前置修订

Type: grilling
Status: resolved
Blocked by: 01

## Question

既有卸载双路径(面板内卸载入口 + `install.sh --uninstall`)都建立在「卸载先看后删」纪律上
(unit 还在、代理还接管着就拒删)。A2 Panel 成为默认浏览器后,多一件「删了就没工具收拾」的
系统状态。要裁:

- **面板卸载路径**:前置检查加「还是默认 handler 时先 restore(或拒绝并指引)」的具体顺序,
  插在既有 proxy off / service uninstall 序列的哪一步;
- **install.sh --uninstall**:它卸的是内核 bin —— bin 没了 `a2 url-router restore` 就没了,
  前置清单要不要加这一条(与既有 ⑤ 条纪律同构);
- **拖废纸篓野路径**:用户直接删 .app、handler 悬空指向已删 bundle 时,系统行为是什么
  (01 查证),我们要不要/能不能兜(比如内核 service 检测到悬空自动 restore ——
  这与「系统状态永远显式发起」的边界怎么摆);
- **restore 目标失效**:兜底浏览器本身被删时 restore 的姿势。

依赖 [01](01-default-handler-api-facts.md) 的还原语义。裁定并入 [06](06-spec-final.md)。

## Answer

裁定(2026-09-03,一轮 grilling,四问全清):

1. **面板卸载序列:restore 打头,拒即中止**。① 若仍是默认 handler → 发起 restore(弹系统框),
   用户拒绝/超时则**卸载中止 + 指引**;② proxy off;③ service uninstall;④ 删文件。
   restore 必须排在服务还活着的时段(内核决策 + 壳执行,04 已裁);「接管还挡着就不往下走」
   与「卸载先看后删」同构。
2. **install.sh --uninstall 加第四条前置**:`com.a2.panel` 仍是默认 http/https handler 时
   拒删 bin,指引先跑 `a2 url-router restore`。POSIX sh 的检测途径归 06 spec 细化。
3. **野路径只诊断不动手**:用户直接删 .app 致 handler 悬空时,不自动改系统状态;
   `a2 url-router status` 识别悬空并给精确修复命令(拒绝即指引同构)。01 的「系统自动回落」
   行为施工期断言实测钉死。守住「系统状态永远显式发起」。
4. **restore 目标失效:报错 + 显式覆写**。兜底浏览器不存在时结构化报错 + 两条指引
   (改配置 / `a2 url-router restore --to com.apple.Safari`),不静默替换目标。

## Comments
