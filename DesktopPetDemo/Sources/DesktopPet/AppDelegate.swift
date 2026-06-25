import Cocoa
import PetCore

/// 负责创建桌宠窗口、菜单栏图标，并用定时器驱动“眼睛跟随鼠标 + 点击穿透 + 表情状态机”。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: PetWindow!
    private var sceneView: PetSceneView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?               // 60Hz 追踪定时器
    private var reminderTimer: Timer?       // 提醒定时器
    private var lastTickUptime: TimeInterval = 0   // 上帧时刻（算 dt 用，单调时钟）

    // 表情状态机（Domain 层，纯逻辑）
    private let machine = PetStateMachine()
    private var lastInteraction = Date()
    private let idleToSleepSeconds: TimeInterval = 8.0

    // 提醒系统
    private let reminders = ReminderScheduler.makeDefault()   // 先运动后喝水，交替
    private let reminderInterval: TimeInterval = 10 * 60      // 每 10 分钟交替一次 → 每种各 20 分钟
    private let bubble = BubbleController()

    // 特殊动作（穿越/跳舞）
    private let portal = PortalController()
    private let radialMenu = RadialMenuController()
    private var isBusy = false                                // 表演中，避免重入与误判犯困
    private var slideTimer: Timer?                            // 穿越时窗口逐帧滑动

    // 鼠标围绕脑袋转圈弹出菜单（提示说 3 圈，实际放宽到 ~2.5 圈更易触发）
    private var circleAccum: CGFloat = 0                      // 累积转角（带符号）
    private var circlePrevAngle: CGFloat?
    private var circleLastTime = Date.distantPast
    private var menuCooldownUntil = Date.distantPast
    private let circlesToOpen: CGFloat = 3

    // 连点 N 次关闭
    private var clickCount = 0
    private var lastClickTime = Date.distantPast
    private let clicksToClose = 5
    private let clickWindow: TimeInterval = 1.5               // 相邻点击间隔需 < 此值才算"连点"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupStatusItem()
        startTracking()
        startReminders()
        showFirstRunHintIfNeeded()
    }

    /// 首次启动给一句操作引导（只显示一次，记在 UserDefaults）。
    private func showFirstRunHintIfNeeded() {
        let key = "didShowCircleHint"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.bubble.show("用鼠标在我脑袋上画 3 个圈，就能打开菜单哦～ 🌀",
                             abovePet: self.window.frame, duration: 8.0)
        }
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
        sceneView.onRawClick = { [weak self] in self?.registerClickForClose() }
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
        menu.addItem(withTitle: "跳舞", action: #selector(danceMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "试一下提醒", action: #selector(testReminder), keyEquivalent: "")
        menu.addItem(withTitle: "回到右下角", action: #selector(resetPosition), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出（或连点宠物 5 下）", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func poke() { dispatch(.poke) }
    @objc private func pet()  { dispatch(.pet) }
    @objc private func feed() { dispatch(.feed) }
    @objc private func danceMenu() { startDance() }
    @objc private func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 40, y: vf.minY + 40))
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func testReminder() { fireReminder() }

    // MARK: - 提醒系统（交替：先运动 → 再喝水；抖动 + 头顶泡泡）

    private func startReminders() {
        reminderTimer = Timer.scheduledTimer(withTimeInterval: reminderInterval, repeats: true) { [weak self] _ in
            self?.fireReminder()
        }
    }

    /// 触发下一条提醒：宠物抖动 + 头顶弹出泡泡显示文案。
    private func fireReminder() {
        guard let reminder = reminders.next() else { return }
        sceneView.playShake()
        bubble.show(reminder.message, abovePet: window.frame)
    }

    // MARK: - 连点 5 次关闭

    private func registerClickForClose() {
        let now = Date()
        clickCount = now.timeIntervalSince(lastClickTime) < clickWindow ? clickCount + 1 : 1
        lastClickTime = now
        if clickCount >= clicksToClose {
            clickCount = 0
            closeWithFarewell()
        }
    }

    private func closeWithFarewell() {
        sceneView.playShake()
        bubble.show("拜拜～ 下次见 🐾", abovePet: window.frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - 鼠标围绕脑袋转 3 圈 → 弹出环形菜单

    private func detectCircleGesture(mouse: NSPoint) {
        // 表演中 / 菜单冷却中 不检测
        guard !isBusy, Date() >= menuCooldownUntil else {
            circlePrevAngle = nil; circleAccum = 0; return
        }
        let now = Date()
        // 停顿/离开超过 0.6 秒才放弃已累积进度（不再一离开就清零，容错更高）
        if now.timeIntervalSince(circleLastTime) > 0.6 {
            circleAccum = 0; circlePrevAngle = nil
        }

        // 以宠物身体为圆心（窗口中心）
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let dx = mouse.x - center.x, dy = mouse.y - center.y
        let dist = sqrt(dx * dx + dy * dy)

        // 大幅放宽判定环带：贴着身体绕 / 离得较远绕都算；离开只断开连续性，短暂越界不丢进度
        let rMin: CGFloat = 8, rMax: CGFloat = 420
        guard dist >= rMin, dist <= rMax else {
            circlePrevAngle = nil
            return
        }
        circleLastTime = now

        let angle = atan2(dy, dx)
        if let prev = circlePrevAngle {
            var delta = angle - prev
            while delta > .pi { delta -= 2 * .pi }     // 归一化到 [-π, π]
            while delta < -.pi { delta += 2 * .pi }
            circleAccum += delta
            if abs(circleAccum) >= circlesToOpen * 2 * .pi {   // 满 ~2.5 圈即触发
                circleAccum = 0
                circlePrevAngle = nil
                menuCooldownUntil = now.addingTimeInterval(1.5)
                showPetMenu()
                return
            }
        }
        circlePrevAngle = angle
    }

    // MARK: - 环形宠物菜单（摸摸 / 喂食 / 跳舞 / 穿越 / 关闭）

    private func showPetMenu() {
        let items: [RadialMenuController.Item] = [
            .init(title: "摸摸") { [weak self] in self?.dispatch(.pet) },
            .init(title: "喂食") { [weak self] in self?.dispatch(.feed) },
            .init(title: "跳舞") { [weak self] in self?.startDance() },
            .init(title: "穿越") { [weak self] in self?.startTeleport() },
            .init(title: "关闭") { [weak self] in self?.closeWithFarewell() }
        ]
        radialMenu.show(items: items, aroundPet: window.frame)
    }

    // MARK: - 跳舞

    private func startDance() {
        bubble.show("看我跳个舞～ 💃", abovePet: window.frame)
        sceneView.dance()   // 纯刚体部件编排的萌舞；可反复触发（打断重跳）
    }

    // MARK: - 穿越（黑洞传送）

    private func startTeleport() {
        guard !isBusy else { return }
        isBusy = true
        sceneView.setTrackingSuspended(true)

        let petFrame = window.frame
        let pet = petFrame.size
        let holeSize = NSSize(width: 150, height: 212)     // 竖向椭圆，高 > 宽
        let gap: CGFloat = 30
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame

        // 1) 黑洞出现在宠物左/右侧（挑屏幕更宽裕的一侧），留出间距、不遮挡宠物
        let openOnRight = petFrame.midX <= vf.midX
        let hole1 = NSPoint(
            x: openOnRight ? petFrame.maxX + gap + holeSize.width / 2
                           : petFrame.minX - gap - holeSize.width / 2,
            y: petFrame.midY)
        portal.open(at: hole1, size: holeSize)

        // 2) 同时：朝洞口滑过去（easeOut，可见移动）+ 旋转缩小（easeIn，螺旋着被吸入）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let into = NSPoint(x: hole1.x - pet.width / 2, y: hole1.y - pet.height / 2)
            self.slideWindow(to: into, duration: 0.7) { }   // 移动
            self.sceneView.playEnterPortal { }              // 同步旋转 + 缩小
        }

        // 3) 关闭第一个黑洞（等宠物被完全吸进去后）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.portal.close()
        }

        // 4) 3 秒后随机位置开新传送门（大、接近圆形，在宠物身后做背景），宠物隐身瞬移到门口
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) { [weak self] in
            guard let self else { return }
            let exitHole = NSSize(width: 236, height: 332)   // 竖向大椭圆门，框住宠物身后
            let hole2 = self.randomHoleCenter(petSize: pet, holeSize: exitHole, in: vf)
            self.window.setFrameOrigin(NSPoint(x: hole2.x - pet.width / 2, y: hole2.y - pet.height / 2))
            self.portal.open(at: hole2, size: exitHole, below: self.window)   // 门在宠物身后、居中

            // 5) 宠物在门前放大"走出来" + 打招呼
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.sceneView.playExitPortal()
                self.bubble.show("我回来啦～ 👋", abovePet: self.window.frame)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.sceneView.playGreet()
            }
            // 6) 传送门消失，结束
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                self.portal.close()
                self.sceneView.setTrackingSuspended(false)
                self.isBusy = false
            }
        }
    }

    /// 逐帧插值移动窗口（easeOut），保证肉眼可见的"走过去"，结束回调。
    private func slideWindow(to target: NSPoint, duration: TimeInterval, completion: @escaping () -> Void) {
        slideTimer?.invalidate()
        let start = window.frame.origin
        let startTime = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1.0, Date().timeIntervalSince(startTime) / duration)
            let e = CGFloat(1 - pow(1 - p, 3))      // easeOut
            self.window.setFrameOrigin(NSPoint(x: start.x + (target.x - start.x) * e,
                                               y: start.y + (target.y - start.y) * e))
            if p >= 1.0 {
                timer.invalidate()
                self.slideTimer = nil
                completion()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        slideTimer = t
    }

    /// 随机门中心：保证门和居中其上的宠物窗口都落在屏内。
    private func randomHoleCenter(petSize: NSSize, holeSize: NSSize, in vf: NSRect) -> NSPoint {
        let mx = max(petSize.width, holeSize.width) / 2 + 8
        let my = max(petSize.height, holeSize.height) / 2 + 8
        let loX = vf.minX + mx, hiX = vf.maxX - mx
        let loY = vf.minY + my, hiY = vf.maxY - my
        let x = CGFloat.random(in: min(loX, hiX)...max(loX, hiX))
        let y = CGFloat.random(in: min(loY, hiY)...max(loY, hiY))
        return NSPoint(x: x, y: y)
    }

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

        // 2) 头/眼跟随鼠标（打盹时不追踪）+ 每帧推进动画引擎（弹簧/待机噪声/次级运动）
        let track = machine.mood != .sleepy
        sceneView.setLookActive(track)
        if track {
            let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
            sceneView.lookToward(dx: Double(mouse.x - center.x),
                                 dy: Double(mouse.y - center.y))
        }
        // 每帧推进动画引擎，传入真实 dt（首帧与卡顿后做 clamp，避免一帧跳变过大）
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastTickUptime == 0 ? 1.0 / 60.0 : min(0.1, max(0.0, now - lastTickUptime))
        lastTickUptime = now
        sceneView.tick(dt: CGFloat(dt))

        // 3) 点击穿透：只有鼠标真正落在宠物身上时才接收事件，否则穿透到下层应用
        window.ignoresMouseEvents = !overPet

        // 3.5) 鼠标围绕脑袋转 3 圈 -> 弹出环形菜单
        detectCircleGesture(mouse: mouse)

        // 4) 久无互动 -> 犯困；鼠标悬停在宠物身上视为陪伴，刷新计时（表演中不犯困）
        if overPet { lastInteraction = Date() }
        if !isBusy, machine.mood == .idle,
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
