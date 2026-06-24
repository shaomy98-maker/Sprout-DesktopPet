import Cocoa

/// "穿越"用的传送门。独立透明无边框窗口，可出现在屏幕任意位置；
/// 绿色漩涡（参考 Rick & Morty）：旋转的螺旋纹 + 亮绿发光边。
final class PortalController {

    private var window: NSWindow?
    private let view = PortalView()
    private var center: NSPoint = .zero

    /// 在屏幕坐标 `center` 处打开 `size`（椭圆）的传送门。
    /// `below` 非空时，门会排到该窗口之下（让宠物显示在门前面）。
    func open(at center: NSPoint, size: NSSize, below: NSWindow? = nil, completion: (() -> Void)? = nil) {
        self.center = center
        let win = window ?? makeWindow()
        window = win

        let full = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        let tiny = NSRect(x: center.x - 5, y: center.y - 4, width: 10, height: 8)
        win.setFrame(tiny, display: false)
        win.alphaValue = 0
        win.orderFrontRegardless()
        if let below { win.order(.below, relativeTo: below.windowNumber) }
        view.startSpin()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().setFrame(full, display: true)
            win.animator().alphaValue = 1
        }, completionHandler: completion)
    }

    func close(completion: (() -> Void)? = nil) {
        guard let win = window else { completion?(); return }
        let tiny = NSRect(x: center.x - 5, y: center.y - 4, width: 10, height: 8)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().setFrame(tiny, display: true)
            win.animator().alphaValue = 0
        }, completionHandler: {
            self.view.stopSpin()
            win.orderOut(nil)
            completion?()
        })
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        return w
    }
}

/// 绿色旋转漩涡：径向渐变（暗绿心 → 亮绿边）+ 多条旋转螺旋臂 + 波浪发光边。
final class PortalView: NSView {

    private var phase: CGFloat = 0
    private var timer: Timer?

    func startSpin() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.phase += 0.10
            self?.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopSpin() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let cx = bounds.midX, cy = bounds.midY
        let rx = bounds.width / 2 * 0.92
        let ry = bounds.height / 2 * 0.92

        // 外发光晕
        let glow = wavyEllipse(cx: cx, cy: cy, rx: rx * 1.12, ry: ry * 1.12, waves: 10, amp: 0.05)
        NSColor(calibratedRed: 0.25, green: 1.0, blue: 0.30, alpha: 0.16).setFill()
        glow.fill()

        // 主体：暗绿心 → 亮绿边 径向渐变
        let body = wavyEllipse(cx: cx, cy: cy, rx: rx, ry: ry, waves: 12, amp: 0.05)
        let grad = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.01, green: 0.11, blue: 0.03, alpha: 1.0),
                NSColor(calibratedRed: 0.05, green: 0.48, blue: 0.10, alpha: 1.0),
                NSColor(calibratedRed: 0.40, green: 1.0, blue: 0.28, alpha: 1.0)
            ],
            atLocations: [0.0, 0.60, 1.0],
            colorSpace: .deviceRGB)
        grad?.draw(in: body, relativeCenterPosition: .zero)

        // 旋转螺旋臂（裁剪在洞口内）
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        let arms = 6
        let steps = 44
        let thetaMax: CGFloat = 3.4 * .pi
        NSColor(calibratedRed: 0.82, green: 1.0, blue: 0.70, alpha: 0.55).setStroke()
        for k in 0..<arms {
            let offset = CGFloat(k) / CGFloat(arms) * 2 * .pi + phase
            let arm = NSBezierPath()
            arm.lineWidth = 2
            for i in 0...steps {
                let frac = CGFloat(i) / CGFloat(steps)
                let t = frac * thetaMax
                let x = cx + rx * frac * cos(t + offset)
                let y = cy + ry * frac * sin(t + offset)
                if i == 0 { arm.move(to: NSPoint(x: x, y: y)) }
                else { arm.line(to: NSPoint(x: x, y: y)) }
            }
            arm.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        // 亮绿发光边
        NSColor(calibratedRed: 0.45, green: 1.0, blue: 0.32, alpha: 0.95).setStroke()
        body.lineWidth = max(3, bounds.height * 0.03)
        body.stroke()
    }

    /// 沿椭圆、半径按正弦起伏的"波浪曲线"路径。
    private func wavyEllipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                             waves: Int, amp: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let steps = 72
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let wob = 1 + amp * sin(CGFloat(waves) * t)
            let x = cx + rx * wob * cos(t)
            let y = cy + ry * wob * sin(t)
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
            else { path.line(to: NSPoint(x: x, y: y)) }
        }
        path.close()
        return path
    }
}
