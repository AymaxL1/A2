#!/bin/bash
# PROTOTYPE — 不经 SPM 直接 swiftc 构建并运行。
# 原因：本机 CLT 的 libPackageDescription.dylib 符号为空（坏库）且未装 Xcode.app，
# `swift build` 无法解析清单；装好完整 Xcode 后可改用 `swift run`（Package.swift 已保留）。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
# -vfsoverlay 遮掉 CLT 里重复定义 SwiftBridging 的旧 module.modulemap（详见 toolchain-workaround/ 与 README）；CLT 修好后可移除该旗标
swiftc -vfsoverlay toolchain-workaround/overlay.yaml -module-cache-path .build/mcache \
  -o .build/S1PetOverlay Sources/S1PetOverlay/*.swift
exec .build/S1PetOverlay
