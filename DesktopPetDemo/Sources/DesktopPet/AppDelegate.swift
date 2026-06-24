import Cocoa
import PetCore

/// 负责创建桌宠窗口、菜单栏图标，并用定时器驱动“眼睛跟随鼠标 + 点击穿透 + 表情状态机”。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: PetWindow!
    private var sceneView: PetSceneView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?               // 60Hz 追踪定时器

    // 表情状态机（Domain 层，纯逻辑）
    private let machine = PetStateMachine()
    private var lastInteraction = Date()
    private let idleToSleepSeconds: TimeInterval = 8.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupStatusItem()
        startTracking()
    }

    // MARK: - 窗口

    private func setupWindow() {
        let size = NSSize(width: 320, height: 360)
        window = PetWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        sceneView = PetSceneView(frame: NSRect(origin: .zero, size: size))
        sceneView.onIntent = { [weak self] event in self?.dispatch(event) }
        window.contentView = sceneView

        // 默认放到主屏右下角
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let origin = NSPoint(x: vf.maxX - size.width - 40,
                                 y: vf.minY + 40)
            window.setFrameOrigin(origin)
        }
        window.orderFrontRegardless()
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"

        let menu = NSMenu()
        menu.addItem(withTitle: "戳一戳", action: #selector(poke), keyEquivalent: "")
        menu.addItem(withTitle: "摸摸", action: #selector(pet), keyEquivalent: "")
        menu.addItem(withTitle: "喂食", action: #selector(feed), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "回到右下角", action: #selector(resetPosition), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func poke() { dispatch(.poke) }
    @objc private func pet()  { dispatch(.pet) }
    @objc private func feed() { dispatch(.feed) }
    @objc private func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 40, y: vf.minY + 40))
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - 表情状态机驱动

    /// 收到一个交互意图：先唤醒（若在打盹），再交给状态机，按结果驱动渲染与计时。
    private func dispatch(_ event: PetEvent) {
        lastInteraction = Date()
        if machine.mood == .sleepy, let wake = machine.handle(.wake) {
            sceneView.render(mood: wake.mood)
        }
        apply(machine.handle(event))
    }

    /// 应用一次状态转移：切换渲染；若是瞬时表情，到时自动回到待机。
    private func apply(_ transition: PetMoodTransition?) {
        guard let transition else { return }
        sceneView.render(mood: transition.mood)
        if let after = transition.autoReturnAfter {
            let mood = transition.mood
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                guard let self else { return }
                if let settle = self.machine.settleToIdle(if: mood) {
                    self.sceneView.render(mood: settle.mood)
                }
            }
        }
    }

    // MARK: - 追踪循环（眼睛跟随 + 点击穿透 + 犯困判定）

    private func startTracking() {
        // 优先用 60Hz 定时器（DisplayLink 在 SPM 命令行场景下足够，简化为 Timer）
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        // 1) 全局鼠标位置（屏幕坐标，origin 在左下；无需任何权限）
        let mouse = NSEvent.mouseLocation
        let overPet = isMouseOverPet(screenPoint: mouse)

        // 2) 让宠物眼睛看向鼠标（打盹闭眼时不追踪，让摇摆动作接管姿态）
        if machine.mood != .sleepy {
            let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
            sceneView.lookToward(dx: Double(mouse.x - center.x),
                                 dy: Double(mouse.y - center.y))
        }

        // 3) 点击穿透：只有鼠标真正落在宠物身上时才接收事件，否则穿透到下层应用
        window.ignoresMouseEvents = !overPet

        // 4) 久无互动 -> 犯困；鼠标悬停在宠物身上视为陪伴，刷新计时
        if overPet { lastInteraction = Date() }
        if machine.mood == .idle,
           Date().timeIntervalSince(lastInteraction) > idleToSleepSeconds {
            apply(machine.handle(.idleElapsed))
        }
    }

    /// 把屏幕坐标换算到 SCNView 内做命中检测，判断是否指向宠物本体。
    private func isMouseOverPet(screenPoint: NSPoint) -> Bool {
        guard window.frame.contains(screenPoint) else { return false }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        let inView = sceneView.convert(inWindow, from: nil)
        let hits = sceneView.hitTest(inView, options: [
            .boundingBoxOnly: true,
            .ignoreHiddenNodes: true
        ])
        return !hits.isEmpty
    }
}
