import Cocoa

/// 宠物头顶的"泡泡弹出框"提示。用一个独立的透明无边框窗口承载，
/// 不受宠物窗口边界裁剪，可浮在宠物上方任意位置。淡入、几秒后淡出。
final class BubbleController {

    private var window: NSWindow?
    private let view = BubbleView()
    private var hideWork: DispatchWorkItem?

    /// 在 `petFrame`（宠物窗口的屏幕 frame）正上方显示一句提示。
    func show(_ message: String, abovePet petFrame: NSRect, duration: TimeInterval = 4.0) {
        view.text = message
        let size = view.fittingSize(for: message)

        let win = window ?? makeWindow()
        window = win
        win.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)

        // 水平居中于宠物，底部尾巴指向宠物顶部（略微重叠进窗口顶部）
        let x = petFrame.midX - size.width / 2
        let y = petFrame.maxY - 36
        win.setFrameOrigin(NSPoint(x: x, y: y))

        win.alphaValue = 0
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            win.animator().alphaValue = 1
        }

        // 自动淡出
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            win.animator().alphaValue = 0
        }, completionHandler: { win.orderOut(nil) })
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.ignoresMouseEvents = true               // 不挡点击
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.contentView = view
        return w
    }
}

/// 绘制圆角对话气泡 + 底部小尾巴 + 居中文字。
final class BubbleView: NSView {

    var text: String = "" { didSet { needsDisplay = true } }

    private let font = NSFont.systemFont(ofSize: 14, weight: .medium)
    private let hPad: CGFloat = 14
    private let vPad: CGFloat = 9
    private let tailH: CGFloat = 9
    private let maxWidth: CGFloat = 240
    private let mint = NSColor(calibratedRed: 0.62, green: 0.85, blue: 0.74, alpha: 1)
    private let ink  = NSColor(calibratedRed: 0.25, green: 0.30, blue: 0.28, alpha: 1)

    /// 按文案算出气泡（含内边距和尾巴）需要的尺寸。
    func fittingSize(for message: String) -> NSSize {
        let bound = (message as NSString).boundingRect(
            with: NSSize(width: maxWidth - hPad * 2, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let w = min(maxWidth, ceil(bound.width) + hPad * 2)
        let h = ceil(bound.height) + vPad * 2 + tailH
        return NSSize(width: max(w, 70), height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let bubble = NSRect(x: r.minX, y: r.minY + tailH, width: r.width, height: r.height - tailH)

        let path = NSBezierPath(roundedRect: bubble, xRadius: 13, yRadius: 13)
        // 底部居中的三角尾巴
        let cx = bounds.midX
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - 9, y: bubble.minY + 1))
        tail.line(to: NSPoint(x: cx, y: r.minY))
        tail.line(to: NSPoint(x: cx + 9, y: bubble.minY + 1))
        tail.close()
        path.append(tail)

        NSColor.white.withAlphaComponent(0.98).setFill()
        path.fill()
        mint.setStroke()
        path.lineWidth = 2
        path.stroke()

        // 居中文字
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink,
            .paragraphStyle: para
        ]
        let textArea = bubble.insetBy(dx: hPad, dy: vPad)
        let textSize = (text as NSString).boundingRect(
            with: NSSize(width: textArea.width, height: textArea.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs).size
        let centered = NSRect(
            x: textArea.minX,
            y: textArea.minY + (textArea.height - textSize.height) / 2,
            width: textArea.width,
            height: textSize.height)
        (text as NSString).draw(in: centered, withAttributes: attrs)
    }
}
