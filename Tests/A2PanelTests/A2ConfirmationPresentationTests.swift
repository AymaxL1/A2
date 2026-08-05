// 10 票:确认器**呈现面**的纯逻辑断言 —— 「`input` 必须原样呈现」这条壳红线的可机读形态。
//
// 为什么值得单独一套:这条红线防的是社工话术(agent 说「我只是改个名字」,实际把订阅源
// 换成了它自己的服务器)。若呈现逻辑藏在 AppKit 的字符串拼接里,只有人眼能审 —— 那不叫门禁。

import Testing
import A2Contract
import A2Panel
import A2PanelFixtures

@Suite("10 确认呈现(input 原样、拒绝是默认、不截断)")
struct A2ConfirmationPresentationTests {

    @Test("10 原样呈现:每个入参一行、逐字等于协议报文里的值")
    func inputIsShownVerbatim() {
        let presentation = A2ConfirmationPresentation(request: A2PanelFixtures.confirmationRequest)
        #expect(presentation.inputLines == [
            "name: 机场 A",
            "source: https://example.invalid/sub/a.yaml",
        ])
        for (key, value) in A2PanelFixtures.confirmationRequest.input {
            #expect(presentation.body.contains(A2MenuModel.describe(value)),
                    "入参 \(key) 的值必须出现在正文里")
        }
    }

    @Test("10 不截断:长到离谱的源地址也整条呈现(被截掉的那一半可能正是恶意的那一半)")
    func longValuesAreNotTruncated() {
        let long = "https://evil.invalid/" + String(repeating: "a", count: 500) + "/sub.yaml"
        let request = A2ConfirmationRequest(
            id: "cfm-long", capability: "proxy.subscription.add",
            descriptor: A2PanelFixtures.capabilities.first { $0.id == "proxy.subscription.add" }!,
            input: ["name": .string("看起来很正常"), "source": .string(long)],
            requestedAt: "t0", expiresAt: "t1")
        let presentation = A2ConfirmationPresentation(request: request)
        #expect(presentation.body.contains(long))
    }

    @Test("10 空入参如实写明,不留空白让人以为「没什么可看的」")
    func emptyInputIsStated() {
        let request = A2ConfirmationRequest(
            id: "cfm-empty", capability: "demo.wipe",
            descriptor: A2PanelFixtures.capabilities.first { $0.id == "demo.wipe" }!,
            input: [:], requestedAt: "t0", expiresAt: "t1")
        let presentation = A2ConfirmationPresentation(request: request)
        #expect(presentation.inputLines == ["(无入参)"])
    }

    @Test("10 呈现面带齐三样坐标:能力 id、风险档、超时时刻")
    func presentationCarriesCoordinates() {
        let presentation = A2ConfirmationPresentation(request: A2PanelFixtures.confirmationRequest)
        #expect(presentation.capability == "proxy.subscription.add")
        #expect(presentation.risk == .dangerous)
        #expect(presentation.body.contains(A2PanelFixtures.confirmationRequest.expiresAt))
        #expect(presentation.summary == "新增或替换订阅源(dangerous)",
                "能力自述取自内核推来的 descriptor,壳不自带副本")
    }

    @Test("10 入参按键名排序(确定性 —— 同一份请求弹两次内容逐字相同)")
    func inputOrderIsDeterministic() {
        let request = A2ConfirmationRequest(
            id: "cfm-order", capability: "proxy.subscription.add",
            descriptor: A2PanelFixtures.capabilities.first { $0.id == "proxy.subscription.add" }!,
            input: ["zeta": .string("1"), "alpha": .string("2"), "mid": .int(3)],
            requestedAt: "t0", expiresAt: "t1")
        #expect(A2ConfirmationPresentation(request: request).inputLines
                == ["alpha: 2", "mid: 3", "zeta: 1"])
    }
}
