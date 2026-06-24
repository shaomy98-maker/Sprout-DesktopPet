import Cocoa

/// 长按宠物弹出的"环形菜单"：胶囊按钮沿一段圆弧分布在宠物四周（偏上/身后），
/// 逐个从中心弹出。点击胶囊执行动作，点击空白处关闭。
final class RadialMenuController {

    struct Item {
        let title: String
        let action: () -> Void
    }

    private var window: NSWindow?
    private let view = RadialMenuView()

    func show(items: [Item], aroundPet petFrame: NSRect) {
        let win = window ?? makeWindow()
        window = win

        let radius: CGFloat = 118
        let side = (radius + 90) * 2                 // 留足胶囊外延空间
        let center = NSPoint(x: petFrame.midX, y: petFrame.midY)
        let frame = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        win.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)

        view.onDismiss = { [weak self] in self?.dismiss() }
        view.configure(items: items, radius: radius)
        win.orderFrontRegardless()
        view.animateIn()
    }

    func dismiss() {
        guard let win = window else { return }
        view.animateOut { win.orderOut(nil) }
    }

    private func makeWindow() -> NSWindow {
        let w = KeyableBorderlessWindow(contentRect: .zero, styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.contentView = view
        return w
    }
}

/// 无边框但可成为 key（便于接收点击）的窗口。
final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// 环形菜单容器：布置胶囊、跑弹出/收回动画、空白处点击关闭。
final class RadialMenuView: NSView {

    var onDismiss: (() -> Void)?
    private var capsules: [CapsuleButton] = []
    private var targets: [NSPoint] = []     // 各胶囊目标中心

    func configure(items: [RadialMenuController.Item], radius: CGFloat) {
        capsules.forEach { $0.removeFromSuperview() }
        capsules.removeAll(); targets.removeAll()

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        // 沿上半弧分布（从左下经正上到右下），让菜单环绕在宠物身后/上方
        let startDeg: CGFloat = 212
        let endDeg: CGFloat = -32
        let n = items.count

        for (i, item) in items.enumerated() {
            let frac = n == 1 ? 0.5 : CGFloat(i) / CGFloat(n - 1)
            let deg = startDeg + (endDeg - startDeg) * frac
            let rad = deg * .pi / 180
            let target = NSPoint(x: center.x + radius * cos(rad),
                                 y: center.y + radius * sin(rad))

            let cap = CapsuleButton(title: item.title)
            cap.onClick = { [weak self] in
                item.action()
                self?.onDismiss?()
            }
            cap.sizeToFitCapsule()
            cap.setFrameCenter(center)          // 初始收在中心
            cap.alphaValue = 0
            addSubview(cap)
            capsules.append(cap)
            targets.append(target)
        }
    }

    func animateIn() {
        for (i, cap) in capsules.enumerated() {
            let origin = originFor(center: targets[i], size: cap.frame.size)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.045) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    cap.animator().alphaValue = 1
                    cap.animator().setFrameOrigin(origin)
                }
            }
        }
    }

    func animateOut(completion: @escaping () -> Void) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            for cap in capsules {
                cap.animator().alphaValue = 0
                cap.animator().setFrameOrigin(originFor(center: center, size: cap.frame.size))
            }
        }, completionHandler: completion)
    }

    private func originFor(center c: NSPoint, size: NSSize) -> NSPoint {
        NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
    }

    // 点击空白处关闭（胶囊自己会先吃掉落在它身上的点击）
    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}

/// 圆角胶囊按钮。
final class CapsuleButton: NSView {

    var onClick: (() -> Void)?
    private let title: String
    private var hovering = false
    private var tracking: NSTrackingArea?

    private let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let mint = NSColor(calibratedRed: 0.62, green: 0.85, blue: 0.74, alpha: 1)
    private let ink  = NSColor(calibratedRed: 0.22, green: 0.28, blue: 0.26, alpha: 1)

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func sizeToFitCapsule() {
        let w = (title as NSString).size(withAttributes: [.font: font]).width
        setFrameSize(NSSize(width: ceil(w) + 30, height: 30))
    }

    /// 以中心点定位（动画用）。
    func setFrameCenter(_ c: NSPoint) {
        setFrameOrigin(NSPoint(x: c.x - frame.width / 2, y: c.y - frame.height / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (hovering ? mint.withAlphaComponent(0.95) : NSColor.white.withAlphaComponent(0.97)).setFill()
        path.fill()
        mint.setStroke(); path.lineWidth = 2; path.stroke()

        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: hovering ? NSColor.white : ink,
            .paragraphStyle: para
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
        (title as NSString).draw(in: rect, withAttributes: attrs)
    }
}
