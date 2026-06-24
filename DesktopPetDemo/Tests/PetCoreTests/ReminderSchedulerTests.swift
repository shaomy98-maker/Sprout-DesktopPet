import XCTest
@testable import PetCore

final class ReminderSchedulerTests: XCTestCase {

    func testDefaultAlternatesMoveThenWater() {
        let s = ReminderScheduler.makeDefault()
        XCTAssertEqual(s.next()?.id, "move")    // 先运动
        XCTAssertEqual(s.next()?.id, "water")   // 再喝水
        XCTAssertEqual(s.next()?.id, "move")    // 交替循环
        XCTAssertEqual(s.next()?.id, "water")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ReminderScheduler().next())
    }

    func testAddExtendsRotation() {
        let s = ReminderScheduler(reminders: [Reminder(id: "a", message: "A")])
        XCTAssertEqual(s.next()?.id, "a")
        s.add(Reminder(id: "b", message: "B"))   // 后续扩展
        XCTAssertEqual(s.next()?.id, "b")
        XCTAssertEqual(s.next()?.id, "a")
    }

    func testMessagesPresent() {
        let s = ReminderScheduler.makeDefault()
        XCTAssertFalse(s.next()?.message.isEmpty ?? true)
    }
}
