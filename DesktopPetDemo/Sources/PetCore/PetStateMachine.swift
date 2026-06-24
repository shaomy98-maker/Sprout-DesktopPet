import Foundation

/// 事件驱动的表情状态机（计划书 4.4）。
///
/// 纯逻辑、无副作用、无 UI 依赖——给定「当前表情 + 事件」即可推出下一个表情，
/// 因此可被单元测试完整覆盖，并在阶段二的其它端复用同一套行为规则。
public final class PetStateMachine {

    public private(set) var mood: PetMood

    public init(mood: PetMood = .idle) {
        self.mood = mood
    }

    /// 处理一个交互事件。返回非 nil 表示发生了状态转移（调用方据此驱动渲染与计时）；
    /// 返回 nil 表示该事件在当前状态下被忽略（例如进食时再戳一下不打断）。
    @discardableResult
    public func handle(_ event: PetEvent) -> PetMoodTransition? {
        guard let transition = Self.transition(from: mood, on: event) else { return nil }
        mood = transition.mood
        return transition
    }

    /// 瞬时表情到期后的收尾：仅当当前仍停留在 `mood` 时才回到待机，
    /// 避免“happy 还没结束又被戳成 surprised”后把 surprised 误重置。
    @discardableResult
    public func settleToIdle(if mood: PetMood) -> PetMoodTransition? {
        guard self.mood == mood else { return nil }
        self.mood = .idle
        return PetMoodTransition(mood: .idle, autoReturnAfter: nil)
    }

    /// 纯函数式的转移规则：`(当前表情, 事件) -> 转移?`。
    /// 抽成静态函数便于直接对规则做单元测试。
    public static func transition(from mood: PetMood, on event: PetEvent) -> PetMoodTransition? {
        switch event {
        case .dragBegan:
            // 任何状态都可被拖动打断；拖动期间保持，直到 dragEnded。
            return PetMoodTransition(mood: .dragged, autoReturnAfter: nil)

        case .dragEnded:
            return mood == .dragged ? PetMoodTransition(mood: .idle, autoReturnAfter: nil) : nil

        case .feed:
            // 拖动中不接受喂食。
            guard mood != .dragged else { return nil }
            return PetMoodTransition(mood: .eating, autoReturnAfter: 2.0)

        case .poke:
            // 进食 / 拖动时戳一下不打断。
            guard mood != .eating, mood != .dragged else { return nil }
            return PetMoodTransition(mood: .surprised, autoReturnAfter: 0.6)

        case .pet:
            guard mood != .eating, mood != .dragged else { return nil }
            return PetMoodTransition(mood: .happy, autoReturnAfter: 1.5)

        case .doubleClick:
            guard mood != .dragged else { return nil }
            return PetMoodTransition(mood: .happy, autoReturnAfter: 1.2)

        case .idleElapsed:
            // 只有真正待机时才会犯困。
            return mood == .idle ? PetMoodTransition(mood: .sleepy, autoReturnAfter: nil) : nil

        case .wake:
            return mood == .sleepy ? PetMoodTransition(mood: .idle, autoReturnAfter: nil) : nil
        }
    }
}
