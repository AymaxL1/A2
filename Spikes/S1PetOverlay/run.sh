#!/bin/bash
# PROTOTYPE — 不经 SPM 直接 swiftc 构建并运行。
# 原因：本机 CLT 的 libPackageDescription.dylib 符号为空（坏库）且未装 Xcode.app，
# `swift build` 无法解析清单；装好完整 Xcode 后可改用 `swift run`（Package.swift 已保留）。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
# -vfsoverlay 遮掉 CLT 里重复定义 SwiftBridging 的旧 module.modulemap（详见 toolchain-workaround/ 与 README）。
# 2026-08-04：本机 CLT 已修（旧 module.modulemap 已改名 .disabled），该旗标在此机上已成冗余——
#   但保留不删，这样本 spike 在 CLT 仍坏的机器上照样能跑（overlay 对已修好的机器无害）。
#   门禁 Scripts/check.sh 走的是自动探测，不再固定带此旗标。
swiftc -vfsoverlay toolchain-workaround/overlay.yaml -module-cache-path .build/mcache \
  -o .build/S1PetOverlay Sources/S1PetOverlay/*.swift
exec .build/S1PetOverlay
