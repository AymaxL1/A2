# Electron 回退预研(2026-07-28)——已评估,维持原判

本目录五份研究文档是对 ADR 0002(Swift 原生栈)的一次性重评产物,由新动机(进度/工具链/通用性)触发,非回退硬门触发。

**终裁(2026-07-28,用户当面确认):不翻案,维持 Swift 原生;V1 期内技术栈问题封卷,不再重开。**

- 裁决全文:`.scratch/electron-recon/issues/09-final-ruling.md`
- 动机澄清:`.scratch/electron-recon/issues/08-generality-clarify.md`
- 地图与全部票:`.scratch/electron-recon/map.md`
- 冒烟 spike 产物:`Spikes/E1ElectronSmoke/`

本目录结论中栈无关的部分(UDS/CLI/沙箱、签名公证链、GPL 边界)对 Swift 路线继续有效;Electron 专属部分归档备查,将来若真做 Windows(重画目的地的新效fort)可复用。
