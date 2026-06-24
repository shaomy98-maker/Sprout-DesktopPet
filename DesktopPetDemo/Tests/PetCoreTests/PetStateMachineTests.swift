import XCTest
@testable import PetCore

final class PetStateMachineTests: XCTestCase {

    // MARK: - 戳一戳 -> 惊讶（瞬时）

    func testPokeFromIdleSurprises() {
        let sm = PetStateMachine()
        let t = sm.handle(.poke)
        XCTAssertEqual(t?.mood, .surprised)
        XCTAssertEqual(t?.autoReturnAfter, 0.6)
        XCTAssertEqual(sm.mood, .surprised)
    }

    func testTransientMoodSettlesBackToIdle() {
        let sm = PetStateMachine()
        sm.handle(.poke)                       // -> surprised
        let settle = sm.settleToIdle(if: .surprised)
        XCTAssertEqual(settle?.mood, .idle)
        XCTAssertEqual(sm.mood, .idle)
    }

    func testSettleIgnoredIfMoodChangedMeanwhile() {
        let sm = PetStateMachine()
        sm.handle(.poke)                       // -> surprised
        sm.handle(.feed)                       // surprised 不挡 feed -> eating
        XCTAssertEqual(sm.mood, .eating)
        // 之前 surprised 的延时收尾不应把 eating 打回 idle
        XCTAssertNil(sm.settleToIdle(if: .surprised))
        XCTAssertEqual(sm.mood, .eating)
    }

    // MARK: - 抚摸 / 双击 -> 开心

    func testPetMakesHappy() {
        let sm = PetStateMachine()
        XCTAssertEqual(sm.handle(.pet)?.mood, .happy)
    }

    func testDoubleClickMakesHappy() {
        let sm = PetStateMachine()
        XCTAssertEqual(sm.handle(.doubleClick)?.mood, .happy)
    }

    // MARK: - 喂食

    func testFeedEats() {
        let sm = PetStateMachine()
        let t = sm.handle(.feed)
        XCTAssertEqual(t?.mood, .eating)
        XCTAssertEqual(t?.autoReturnAfter, 2.0)
    }

    func testPokeDoesNotInterruptEating() {
        let sm = PetStateMachine()
        sm.handle(.feed)                       // -> eating
        XCTAssertNil(sm.handle(.poke))         // 进食时被戳不打断
        XCTAssertEqual(sm.mood, .eating)
    }

    // MARK: - 拖动（保持型状态）

    func testDragHoldsUntilReleased() {
        let sm = PetStateMachine()
        XCTAssertEqual(sm.handle(.dragBegan)?.mood, .dragged)
        XCTAssertNil(sm.handle(.poke))         // 拖动中其它互动被忽略
        XCTAssertNil(sm.handle(.feed))
        XCTAssertEqual(sm.mood, .dragged)
        XCTAssertEqual(sm.handle(.dragEnded)?.mood, .idle)
    }

    func testDragEndedWithoutDragIsIgnored() {
        let sm = PetStateMachine()
        XCTAssertNil(sm.handle(.dragEnded))
        XCTAssertEqual(sm.mood, .idle)
    }

    // MARK: - 犯困 / 唤醒

    func testIdleElapsedSleepsOnlyFromIdle() {
        let sm = PetStateMachine()
        XCTAssertEqual(sm.handle(.idleElapsed)?.mood, .sleepy)
        // 已经睡着后再 idleElapsed 不重复转移
        XCTAssertNil(sm.handle(.idleElapsed))
    }

    func testWakeOnlyFromSleepy() {
        let sm = PetStateMachine()
        XCTAssertNil(sm.handle(.wake))         // 没睡就不需要醒
        sm.handle(.idleElapsed)                // -> sleepy
        XCTAssertEqual(sm.handle(.wake)?.mood, .idle)
    }

    func testIdleElapsedIgnoredWhileBusy() {
        let sm = PetStateMachine()
        sm.handle(.feed)                       // -> eating
        XCTAssertNil(sm.handle(.idleElapsed))  // 进食中不犯困
        XCTAssertEqual(sm.mood, .eating)
    }

    // MARK: - 编解码（为阶段二上云预留）

    func testMoodIsCodable() throws {
        let data = try JSONEncoder().encode(PetMood.happy)
        let decoded = try JSONDecoder().decode(PetMood.self, from: data)
        XCTAssertEqual(decoded, .happy)
    }
}
