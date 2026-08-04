// 本地打成 npm tarball 的「依赖」，专门用来验 lifecycle scripts 是否被跳过：
// 它的 pre/postinstall 一旦执行就会在自己的包目录里留下 *_RAN 标记文件。
module.exports = { probeName: "a2-lifecycle-probe@1.0.0" };
