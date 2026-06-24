import Foundation

/// 宠物的表情 / 情绪状态。对应原图表情集与计划书 4.4 的状态机。
///
/// 纯逻辑类型，不依赖任何 UI / 渲染框架，可在 macOS / iOS / 未来跨端共用。
/// 已 `Codable`，为阶段二上云同步铺路。
public enum PetMood: String, Codable, CaseIterable, Sendable {
    case idle        // 待机
    case happy       // 开心 / 眯眼笑
    case surprised   // 惊讶（被戳）
    case eating      // 进食
    case dragged     // 被拖动
    case sleepy      // 打盹（久无互动）
}

/// 来自交互层的“意图”。Presentation 层把鼠标/触控手势翻译成这些与端无关的事件，
/// 交给状态机决定下一步表情，从而让 Domain 逻辑完全不依赖具体输入设备。
public enum PetEvent: Sendable {
    case poke          // 单击 = 戳一戳
    case pet           // 长按 / 抚摸
    case doubleClick   // 双击 = 特殊动作
    case feed          // 喂食
    case dragBegan     // 开始拖动
    case dragEnded     // 结束拖动
    case idleElapsed   // 长时间无互动
    case wake          // 任意互动唤醒
}

/// 一次状态转移的结果。
/// - `mood`: 转移到的目标表情。
/// - `autoReturnAfter`: 若为非 nil，表示这是个“瞬时表情”，到时应自动回到 `.idle`；
///   nil 表示该状态会一直保持，直到外部事件（如 `dragEnded` / `wake`）打破。
public struct PetMoodTransition: Equatable, Sendable {
    public let mood: PetMood
    public let autoReturnAfter: TimeInterval?

    public init(mood: PetMood, autoReturnAfter: TimeInterval?) {
        self.mood = mood
        self.autoReturnAfter = autoReturnAfter
    }
}
