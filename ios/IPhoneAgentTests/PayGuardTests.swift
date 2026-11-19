import XCTest
@testable import IPhoneAgent

final class PayGuardTests: XCTestCase {
    func testButtonsThatPayOrDelete() {
        XCTAssertEqual(PayGuard.kind("立即支付"), .money)
        XCTAssertEqual(PayGuard.kind("支付 ¥99.00"), .money)
        XCTAssertEqual(PayGuard.kind("Place Order"), .money)
        XCTAssertEqual(PayGuard.kind("删除"), .irreversible)
        XCTAssertEqual(PayGuard.kind("确认删除"), .irreversible)
        XCTAssertEqual(PayGuard.kind("Delete From This iPhone"), .irreversible)
        XCTAssertEqual(PayGuard.kind("同意"), .irreversible)
        XCTAssertEqual(PayGuard.kind("卸载应用"), .irreversible)
        XCTAssertEqual(PayGuard.kind("挂断"), .irreversible)
    }

    func testLabelsThatOnlyMentionIt() {
        XCTAssertNil(PayGuard.kind("支付方式"))
        XCTAssertNil(PayGuard.kind("付款码"))
        XCTAssertNil(PayGuard.kind("删除订单后无法恢复，请谨慎操作"))
        XCTAssertNil(PayGuard.kind("全部订单"))
    }

    func testWhoIsAsked() {
        let none: [JObject] = []
        XCTAssertTrue(PayGuard.asks(.money, mode: .payments, steps: none, label: "立即支付"))
        XCTAssertTrue(PayGuard.asks(.irreversible, mode: .payments, steps: none, label: "删除"))
        XCTAssertTrue(PayGuard.asks(.irreversible, mode: .never, steps: none, label: "删除"), "never lets a delete go")
        XCTAssertTrue(PayGuard.asks(.irreversible, mode: .risky, steps: none, label: "删除"))
        XCTAssertFalse(PayGuard.asks(.money, mode: .never, steps: none, label: "立即支付"))
        let yes: [JObject] = [["action": .str("confirmed"), "reason": .str("the user said yes")]]
        XCTAssertFalse(PayGuard.asks(.money, mode: .payments, steps: yes, label: "立即支付"))
        let later = yes + Array(repeating: ["action": .str("tap")], count: PayGuard.recent)
        XCTAssertTrue(PayGuard.asks(.money, mode: .payments, steps: later, label: "立即支付"), "a payment yes is for now")
        XCTAssertFalse(PayGuard.asks(.irreversible, mode: .risky, steps: later, label: "删除"), "one yes covers a bulk delete")
    }
}
