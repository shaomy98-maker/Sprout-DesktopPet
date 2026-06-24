import Cocoa

/// 桌宠窗口：透明、无边框、置顶、可出现在所有桌面（Space）及全屏应用之上。
/// 这是桌宠最关键的“贴在桌面上”能力。
final class PetWindow: NSWindow {

    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: style,
                   backing: backingStoreType,
                   defer: flag)

        isOpaque = false                 // 非不透明
        backgroundColor = .clear         // 透明背景
        hasShadow = false                // 不要窗口阴影
        level = .floating                // 浮在普通窗口之上（更强可用 .statusBar / .screenSaver）
        ignoresMouseEvents = true        // 默认穿透，由 AppDelegate 动态切换
        isMovableByWindowBackground = false
        collectionBehavior = [
            .canJoinAllSpaces,           // 所有桌面都显示
            .stationary,                 // 切换 Space 时不动
            .fullScreenAuxiliary         // 全屏应用之上也能显示
        ]
    }

    // 无边框窗口默认不能成为 key/main，这里允许，便于接收拖动等事件。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
