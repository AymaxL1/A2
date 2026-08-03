// AAContracts 退出码契约 —— swift-testing 试点(11 票)。
//
// 为什么拿这一块当第一块试验田:`AAExitCode` 是**永久锁定契约**(数值与语义都不许动),
// agent 与脚本全靠它判结果。这类"锁定表"最适合用断言钉死,也最能暴露 swift-testing
// 与本仓库既有手写 `TestReport` 框架之间的落差。
//
// 与既有断言的关系:本文件**不替换**任何既有断言,是新增的平行覆盖。
// 5500 行既有断言的整体搬迁归 17 票;本票只负责证明"这条路能走通"。
//
// 跑法:`swift test --disable-xctest --enable-swift-testing`
//   本机(macOS,无 Xcode)的工具链**不带 XCTest**,只带 swift-testing,
//   故必须显式 `--disable-xctest`,否则 SPM 会去构建它找不到的 XCTest 宿主。

import Testing
@testable import AAContracts

@Suite("退出码锁定表")
struct ExitCodeContractTests {

    /// 锁定表的数值一个都不许变 —— 变了就是破坏对 agent/脚本的公开契约。
    @Test("0–6 七个码的数值被钉死")
    func lockedNumericValues() {
        #expect(AAExitCode.success == 0)
        #expect(AAExitCode.usage == 1)
        #expect(AAExitCode.denied == 2)
        #expect(AAExitCode.timeout == 3)
        #expect(AAExitCode.hostUnreachable == 4)
        #expect(AAExitCode.capabilityFailure == 5)
        #expect(AAExitCode.protocolError == 6)
    }

    /// `semantics` 是 CLI 帮助表的唯一数据源:必须恰好覆盖 0…6、顺序即展示顺序、无重复无缺口。
    @Test("semantics 恰好覆盖 0…6 且顺序连续")
    func semanticsCoversEveryCodeInOrder() {
        let codes = AAExitCode.semantics.map(\.code)
        #expect(codes == [0, 1, 2, 3, 4, 5, 6], "帮助表应按 0…6 连续列出,实际: \(codes)")
        #expect(Set(codes).count == codes.count, "帮助表出现重复退出码")
        for entry in AAExitCode.semantics {
            #expect(!entry.label.isEmpty, "退出码 \(entry.code) 的语义标签为空")
        }
    }

    /// 业务失败是唯一映射到 5 的错误码。
    @Test("capability_failed → 5")
    func businessFailureMapsToFive() {
        #expect(AAExitCode.forErrorCode(WireErrorCode.capabilityFailed) == AAExitCode.capabilityFailure)
    }

    /// denied 是唯一映射到 2 的错误码(04 票 dangerous 确认链的对外表现)。
    @Test("denied → 2")
    func deniedMapsToTwo() {
        #expect(AAExitCode.forErrorCode(WireErrorCode.denied) == AAExitCode.denied)
    }

    /// 协议/校验层的每一个错误码都必须归 6 —— 逐个点名,不用循环,便于失败时一眼看出是哪个漏了。
    @Test("协议/校验层错误码全部 → 6", arguments: [
        WireErrorCode.unknownCapability,
        WireErrorCode.missingParameter,
        WireErrorCode.typeMismatch,
        WireErrorCode.invalidParams,
        WireErrorCode.badRequest,
        WireErrorCode.unknownOp,
        WireErrorCode.notImplemented,
        WireErrorCode.encodeFailed,
    ])
    func protocolLayerCodesMapToSix(code: String) {
        #expect(AAExitCode.forErrorCode(code) == AAExitCode.protocolError, "错误码 \(code) 应映射到 6")
    }

    /// **fail-safe 而非 fail-silent**:没预期过的 code 必须归 6 让上层察觉,绝不能吞成 0。
    /// 这条是这张表里最重要的一条 —— 它保证「新增了一个错误码但忘了登记」不会静默变成成功。
    @Test("未登记的错误码保守归 6,绝不吞成成功", arguments: [
        "brand_new_code_nobody_registered",
        "",
        "SUCCESS",
        "0",
    ])
    func unknownCodesFallBackToProtocolError(code: String) {
        let mapped = AAExitCode.forErrorCode(code)
        #expect(mapped == AAExitCode.protocolError, "未知码 \"\(code)\" 应归 6,实际 \(mapped)")
        #expect(mapped != AAExitCode.success, "未知码绝不能被吞成成功")
    }
}
