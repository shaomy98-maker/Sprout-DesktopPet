import Foundation

/// 一条提醒（喝水 / 起来活动 / 以后扩展的其它）。纯数据，跨端可复用、可序列化。
public struct Reminder: Equatable, Sendable {
    public let id: String          // 类型标识，如 "move" / "water"
    public let message: String     // 泡泡框显示的文案

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

/// 交替提醒调度器：按顺序轮转返回下一个提醒。
///
/// 默认顺序「先运动 → 再喝水」交替；触发节奏（间隔多少分钟）由表现层的定时器决定，
/// 这里只负责"下一个该提醒谁"。用 `add()` 可随时扩展新的提醒类型。
public final class ReminderScheduler {

    public private(set) var reminders: [Reminder]
    private var index = 0

    public init(reminders: [Reminder] = []) {
        self.reminders = reminders
    }

    /// 取下一个提醒并轮转：[运动, 喝水] → 运动, 喝水, 运动, 喝水 …。列表为空返回 nil。
    @discardableResult
    public func next() -> Reminder? {
        guard !reminders.isEmpty else { return nil }
        let reminder = reminders[index % reminders.count]
        index += 1
        return reminder
    }

    /// 扩展：追加一种新的提醒类型（会自动并入轮转）。
    public func add(_ reminder: Reminder) {
        reminders.append(reminder)
    }

    /// 预设：先「起来运动」后「喝水」，交替提醒。
    public static func makeDefault() -> ReminderScheduler {
        ReminderScheduler(reminders: [
            Reminder(id: "move",  message: "主人，坐太久啦，起来动一动吧～ 🐾"),
            Reminder(id: "water", message: "主人，记得喝水哦～ 💧")
        ])
    }
}
