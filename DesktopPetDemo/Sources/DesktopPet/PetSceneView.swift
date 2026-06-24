import Cocoa
import SceneKit
import PetCore

/// 透明背景的 SceneKit 视图，实现 `PetRenderer`，由上层状态机驱动。
///
/// 优先加载正式模型 `pet.usdz`（Tripo 生成，分块网格）：自动扶正（USD Z-up→Y-up）、
/// 面向镜头、归一化大小、识别眼睛部件做跟随；加载失败则退回基础几何体占位形象。
///
/// 眼睛统一抽象成两组节点：
/// - `eyeFollowNodes`：随鼠标平移（真模型=识别出的眼睛部件；占位=瞳孔）
/// - `eyeExprNodes`  ：表情缩放睁/眯/闭（真模型=眼睛部件；占位=眼白）
final class PetSceneView: SCNView, PetRenderer {

    private var petRoot: SCNNode!                   // 整只的根（跟手微转 / 呼吸 / 弹跳都作用在它）

    private var eyeFollowNodes: [SCNNode] = []
    private var eyeFollowBase: [SCNVector3] = []
    private var eyeExprNodes: [SCNNode] = []
    private var eyeExprBase: [SCNVector3] = []      // 各眼睛节点的基准缩放
    private var eyeShift: CGFloat = 0.06            // 眼睛最大平移量
    private var currentOpenness: CGFloat = 1.0      // 当前表情对应的睁眼程度（眨眼后睁回它）
    private var blinkTimer: Timer?
    private var eyeSquishAxis = 1                   // 眯眼缩放轴：1=Y(占位/Y-up)，2=Z(真模型/Z-up 的竖直)

    /// 真模型里眼睛部件名（由另一版的贴图分析得出；认错就改这里，找不到会用几何启发式兜底）。
    private let eyePartNames = ["tripo_part_17", "tripo_part_19"]

    private(set) var currentMood: PetMood = .idle
    /// 交互意图回调：把鼠标手势翻译成与端无关的 `PetEvent` 交给上层状态机。
    var onIntent: ((PetEvent) -> Void)?
    /// 每次物理点击（非拖动）都回调一次，用于"连点 N 次关闭"等原始计数。
    var onRawClick: (() -> Void)?

    /// 表演特殊动作（跳舞 / 穿越）时挂起眼睛跟随，避免每帧改 eulerAngles 把动作覆盖掉。
    private var trackingSuspended = false
    func setTrackingSuspended(_ s: Bool) { trackingSuspended = s }

    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var didDrag = false

    override init(frame: NSRect, options: [String : Any]? = nil) {
        super.init(frame: frame, options: options)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        let scene = SCNScene()
        scene.background.contents = nil
        self.scene = scene
        antialiasingMode = .multisampling4X
        isJitteringEnabled = true

        buildCamera(in: scene)
        buildLights(in: scene)
        buildPet(in: scene)
        startIdleBreathing()
        startBlinking()
    }

    // MARK: - 相机 / 灯光

    private func buildCamera(in scene: SCNScene) {
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 2.6   // 模型已归一化到高约 3，留点边距
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, 0.2, 8)
        scene.rootNode.addChildNode(node)
    }

    private func buildLights(in scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        scene.rootNode.addChildNode(ambient)

        // 用方向光替代近距点光，光照更均匀、不易打出刺眼高光；强度调低
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 450
        key.eulerAngles = SCNVector3(-0.6, -0.5, 0)
        scene.rootNode.addChildNode(key)
    }

    // MARK: - 构建宠物（优先真模型，失败退回占位）

    private func buildPet(in scene: SCNScene) {
        petRoot = SCNNode()
        scene.rootNode.addChildNode(petRoot)
        if loadModel(into: petRoot) { return }
        buildPlaceholderPet()
    }

    /// 加载 pet.usdz：扶正 + 面向镜头 + 归一化居中 + 识别眼睛。
    private func loadModel(into parent: SCNNode) -> Bool {
        guard let url = Bundle.module.url(forResource: "pet", withExtension: "usdz", subdirectory: "Resources") else {
            NSLog("[Pet] 未找到 pet.usdz，使用占位模型")
            return false
        }
        do {
            let modelScene = try SCNScene(url: url, options: [.checkConsistency: false])

            // 层级：petRoot > yaw(面向镜头) > container(Z-up→Y-up + 缩放居中)
            let yaw = SCNNode()
            yaw.eulerAngles = SCNVector3(0, -CGFloat.pi / 2, 0)   // 绕 Y 转 -90°，把“朝右”转成面向镜头
            parent.addChildNode(yaw)

            let container = SCNNode()
            for child in modelScene.rootNode.childNodes { container.addChildNode(child) }
            container.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)   // USD Z-up → SceneKit Y-up
            yaw.addChildNode(container)

            // 双面修复（Tripo 法线反转坑）+ 手动并集包围盒（在 yaw 空间度量，含扶正旋转）
            var meshCount = 0
            var lo = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
            var hi = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
            container.enumerateHierarchy { node, _ in
                guard let geo = node.geometry else { return }
                meshCount += 1
                for m in geo.materials {
                    m.isDoubleSided = true            // 修法线反转
                    m.metalness.contents = 0.0        // 去掉 Tripo 偏高的金属度 → 哑光，消刺眼高光
                    m.roughness.contents = 0.85       // 提高粗糙度，进一步柔化高光
                }
                let bb = node.boundingBox
                for cx in [bb.min.x, bb.max.x] {
                    for cy in [bb.min.y, bb.max.y] {
                        for cz in [bb.min.z, bb.max.z] {
                            let w = node.convertPosition(SCNVector3(cx, cy, cz), to: yaw)
                            lo.x = Swift.min(lo.x, w.x); lo.y = Swift.min(lo.y, w.y); lo.z = Swift.min(lo.z, w.z)
                            hi.x = Swift.max(hi.x, w.x); hi.y = Swift.max(hi.y, w.y); hi.z = Swift.max(hi.z, w.z)
                        }
                    }
                }
            }
            let sizeY = max(hi.y - lo.y, 0.0001)
            let s = 3.0 / sizeY
            container.scale = SCNVector3(s, s, s)
            container.position = SCNVector3(-(lo.x + hi.x) / 2 * s,
                                            0.2 - (lo.y + hi.y) / 2 * s,
                                            -(lo.z + hi.z) / 2 * s)

            bindEyeNodes(in: container)
            NSLog("[Pet] 已加载 pet.usdz meshes=\(meshCount) 眼睛节点=\(eyeFollowNodes.count) names=\(eyeFollowNodes.map { $0.name ?? "?" })")
            return true
        } catch {
            NSLog("[Pet] 加载 pet.usdz 失败: \(error)，使用占位模型")
            return false
        }
    }

    /// 绑定眼睛节点：先按名字找，找不到用几何启发式兜底。两组（跟随/表情）在真模型上是同一对部件。
    private func bindEyeNodes(in root: SCNNode) {
        var found: [SCNNode] = []
        for name in eyePartNames {
            if let n = root.childNode(withName: name, recursively: true) { found.append(n) }
        }
        if found.count < 2 { found = autoDetectEyes(in: root) }
        eyeShift = 0.02
        eyeSquishAxis = 2                 // 真模型为 Z-up，竖直闭眼缩 Z
        eyeFollowNodes = found
        eyeFollowBase = found.map { $0.position }
        eyeExprNodes = found
        eyeExprBase = found.map { $0.scale }
    }

    /// 几何兜底：在 petRoot（Y-up）空间里找“靠上、体积偏小、左右成对”的两块当眼睛。
    private func autoDetectEyes(in root: SCNNode) -> [SCNNode] {
        var parts: [(node: SCNNode, c: SCNVector3, r: CGFloat)] = []
        root.enumerateChildNodes { n, _ in
            guard n.geometry != nil else { return }
            let (mn, mx) = n.boundingBox
            let localC = SCNVector3((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
            let c = n.convertPosition(localC, to: petRoot)        // 转到 Y-up 世界空间
            let r = CGFloat(n.boundingSphere.radius) * n.scale.x
            parts.append((n, c, r))
        }
        guard parts.count >= 2 else { return [] }
        let ys = parts.map { $0.c.y }
        let minY = ys.min()!, maxY = ys.max()!
        let span = max(maxY - minY, 0.0001)
        let radii = parts.map { $0.r }.sorted()
        let medR = radii[radii.count / 2]
        let cands = parts.filter {
            let h = ($0.c.y - minY) / span
            return h > 0.35 && h < 0.85 && $0.r <= medR && abs($0.c.x) > 0.02
        }
        var best: (SCNNode, SCNNode)? = nil
        var bestScore = CGFloat.greatestFiniteMagnitude
        for i in 0..<cands.count {
            for j in (i + 1)..<cands.count {
                let a = cands[i], b = cands[j]
                guard a.c.x * b.c.x < 0 else { continue }          // 一左一右
                let score = abs(a.c.y - b.c.y) + abs(abs(a.c.x) - abs(b.c.x))
                if score < bestScore { bestScore = score; best = (a.node, b.node) }
            }
        }
        if let (l, r) = best { return [l, r] }
        return []
    }

    // MARK: - 眼睛跟随（AppDelegate 每帧调用）

    func lookToward(dx: Double, dy: Double) {
        guard !trackingSuspended else { return }
        let scale = 260.0
        let nx = CGFloat(max(-1, min(1, dx / scale)))
        let ny = CGFloat(max(-1, min(1, dy / scale)))

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.08
        for (i, eye) in eyeFollowNodes.enumerated() {
            let b = eyeFollowBase[i]
            eye.position = SCNVector3(b.x + nx * eyeShift, b.y + ny * eyeShift, b.z)
        }
        // 整体轻微朝向鼠标，加强“看着你”
        let tilt: CGFloat = 0.12
        petRoot?.eulerAngles = SCNVector3(-ny * tilt * 0.4, nx * tilt, 0)
        SCNTransaction.commit()
    }

    // MARK: - 表情渲染（PetRenderer）

    func render(mood: PetMood) {
        currentMood = mood
        switch mood {
        case .idle, .dragged, .sleepy: currentOpenness = 1.0   // 休息也睁眼，靠自然眨眼表现生命感
        case .happy:                   currentOpenness = 0.30  // 眯眼笑
        case .surprised:               currentOpenness = 1.35  // 瞪大
        case .eating:                  currentOpenness = 0.85
        }
        applyEyeOpenness(currentOpenness, duration: 0.18)
        applyGesture(for: mood)
    }

    /// 把眼睛开合程度设为 `o`（1=正常睁开，0≈闭合）。沿“竖直轴”压扁：占位 Y、真模型(Z-up) Z。
    private func applyEyeOpenness(_ o: CGFloat, duration: CFTimeInterval) {
        guard !eyeExprNodes.isEmpty else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        for (i, n) in eyeExprNodes.enumerated() {
            let b = eyeExprBase[i]
            n.scale = eyeSquishAxis == 2
                ? SCNVector3(b.x, b.y, b.z * o)
                : SCNVector3(b.x, b.y * o, b.z)
        }
        SCNTransaction.commit()
    }

    // MARK: - 自然眨眼（贴近真人频率 ~15-20 次/分钟）

    private func startBlinking() { scheduleNextBlink() }

    private func scheduleNextBlink() {
        blinkTimer?.invalidate()
        let interval = Double.random(in: 2.6...5.0)     // 平均约每 3.8 秒一次
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.blinkOnce()
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    /// 一次快速眨眼：闭 ~0.06s、睁回当前表情 ~0.10s；偶尔双眨，更像真人。
    private func blinkOnce() {
        guard !trackingSuspended, !eyeExprNodes.isEmpty else { scheduleNextBlink(); return }
        applyEyeOpenness(0.04, duration: 0.06)          // 闭
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.applyEyeOpenness(self.currentOpenness, duration: 0.10)   // 睁回当前表情
            if Double.random(in: 0...1) < 0.12 {        // ~12% 概率双眨
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    self.applyEyeOpenness(0.04, duration: 0.06)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        self.applyEyeOpenness(self.currentOpenness, duration: 0.10)
                        self.scheduleNextBlink()
                    }
                }
            } else {
                self.scheduleNextBlink()
            }
        }
    }

    private func applyGesture(for mood: PetMood) {
        petRoot.removeAction(forKey: "sway")
        petRoot.removeAction(forKey: "chew")
        switch mood {
        case .happy:
            playBounce()
        case .surprised:
            petRoot.runAction(.sequence([.scale(by: 1.12, duration: 0.07), .scale(by: 1.0 / 1.12, duration: 0.14)]))
        case .eating:
            let bite = SCNAction.sequence([
                .moveBy(x: 0, y: -0.05, z: 0, duration: 0.16),
                .moveBy(x: 0, y: 0.05, z: 0, duration: 0.16)
            ])
            petRoot.runAction(.repeat(bite, count: 6), forKey: "chew")
        case .sleepy:
            let a = SCNAction.rotateBy(x: 0, y: 0, z: 0.06, duration: 1.4); a.timingMode = .easeInEaseOut
            let b = SCNAction.rotateBy(x: 0, y: 0, z: -0.06, duration: 1.4); b.timingMode = .easeInEaseOut
            petRoot.runAction(.repeatForever(.sequence([a, b])), forKey: "sway")
        case .idle, .dragged:
            break
        }
    }

    // MARK: - 动作

    func playBounce() {
        guard let petRoot else { return }
        let down = SCNAction.scale(by: 1.0 / 1.06, duration: 0.12); down.timingMode = .easeOut
        petRoot.runAction(.sequence([.scale(by: 1.06, duration: 0.08), down]))
    }

    /// 抖动（提醒时用）。用左右平移实现，不与眼睛跟随（改 eulerAngles）/呼吸（改 scale）冲突。
    func playShake() {
        guard let petRoot else { return }
        let a: CGFloat = 0.16
        let t = 0.04
        let cycle = SCNAction.sequence([
            .moveBy(x: a, y: 0, z: 0, duration: t),
            .moveBy(x: -2 * a, y: 0, z: 0, duration: 2 * t),
            .moveBy(x: 2 * a, y: 0, z: 0, duration: 2 * t),
            .moveBy(x: -a, y: 0, z: 0, duration: t)
        ])
        petRoot.runAction(.repeat(cycle, count: 3), forKey: "shake")
    }

    /// 跳舞：扭身 + 蹦跳，约 3.5 秒。期间挂起眼睛跟随，结束恢复。
    func playDance() {
        guard let petRoot else { return }
        trackingSuspended = true
        petRoot.removeAction(forKey: "breath")
        let twist = SCNAction.sequence([
            .rotateBy(x: 0, y: 0, z: 0.25, duration: 0.22),
            .rotateBy(x: 0, y: 0, z: -0.50, duration: 0.40),
            .rotateBy(x: 0, y: 0, z: 0.25, duration: 0.22)
        ])
        let hop = SCNAction.sequence([
            .moveBy(x: 0, y: 0.22, z: 0, duration: 0.22),
            .moveBy(x: 0, y: -0.22, z: 0, duration: 0.22)
        ])
        petRoot.runAction(.repeat(.group([twist, hop]), count: 4)) { [weak self] in
            petRoot.eulerAngles = SCNVector3(0, 0, 0)
            self?.trackingSuspended = false
            self?.startIdleBreathing()
        }
    }

    /// 穿越——"被吸进黑洞"：旋转 + 缩小同步进行（与上层的滑动同时启动，螺旋着被吸入）。
    /// 缩小用 easeIn：前段保持大、后段才缩没，配合滑动 easeOut 让"移动"清晰可见。
    func playEnterPortal(completion: @escaping () -> Void) {
        guard let petRoot else { completion(); return }
        petRoot.removeAction(forKey: "breath")
        let spin = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 4, z: 0, duration: 0.7)  // 转 2 圈
        let shrink = SCNAction.scale(to: 0.01, duration: 0.7); shrink.timingMode = .easeIn
        petRoot.runAction(.group([spin, shrink]), completionHandler: completion)
    }

    /// 穿越——"走出黑洞"：从极小放大回原状，恢复呼吸。
    func playExitPortal() {
        guard let petRoot else { return }
        petRoot.eulerAngles = SCNVector3(0, 0, 0)
        petRoot.scale = SCNVector3(0.01, 0.01, 0.01)
        let grow = SCNAction.scale(to: 1.0, duration: 0.5); grow.timingMode = .easeOut
        petRoot.runAction(grow) { [weak self] in
            self?.startIdleBreathing()
        }
    }

    /// 打招呼：左右摆动几下（无骨骼，用整体摆动近似挥手）。
    func playGreet() {
        guard let petRoot else { return }
        let l = SCNAction.rotateBy(x: 0, y: 0, z: 0.22, duration: 0.16)
        let r = SCNAction.rotateBy(x: 0, y: 0, z: -0.22, duration: 0.16)
        petRoot.runAction(.sequence([l, r, l, r])) {
            petRoot.eulerAngles = SCNVector3(0, 0, 0)
        }
    }

    private func startIdleBreathing() {
        guard let petRoot else { return }
        let inhale = SCNAction.scale(by: 1.015, duration: 1.6); inhale.timingMode = .easeInEaseOut
        let exhale = SCNAction.scale(by: 1.0 / 1.015, duration: 1.6); exhale.timingMode = .easeInEaseOut
        petRoot.runAction(.repeatForever(.sequence([inhale, exhale])), forKey: "breath")
    }

    // MARK: - 鼠标交互（手势 → 意图）

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        // 移动超过阈值才算真正拖动；小于则视为微抖动忽略
        if !didDrag {
            let dx = now.x - dragStartMouse.x, dy = now.y - dragStartMouse.y
            if dx * dx + dy * dy < 36 { return }   // < 6px 抖动忽略
            didDrag = true
            onIntent?(.dragBegan)
        }
        window?.setFrameOrigin(NSPoint(x: dragStartOrigin.x + (now.x - dragStartMouse.x),
                                       y: dragStartOrigin.y + (now.y - dragStartMouse.y)))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onIntent?(.dragEnded)
        } else if event.clickCount >= 2 {
            onIntent?(.doubleClick)
            onRawClick?()
        } else {
            onIntent?(.poke)
            onRawClick?()
        }
    }

    // MARK: - 占位宠物（资源缺失时的兜底）

    private func buildPlaceholderPet() {
        let white = material(NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.91, alpha: 1))
        let mint  = material(NSColor(calibratedRed: 0.62, green: 0.85, blue: 0.74, alpha: 1))
        let pink  = material(NSColor(calibratedRed: 0.97, green: 0.74, blue: 0.74, alpha: 1))
        let black = material(NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        let gold  = material(NSColor(calibratedRed: 0.93, green: 0.74, blue: 0.30, alpha: 1))

        // 身体 + 头
        let body = SCNNode(geometry: sphere(1.02, white))
        body.scale = SCNVector3(1.0, 1.12, 1.0)
        body.position = SCNVector3(0, -0.35, 0)
        petRoot.addChildNode(body)
        let head = SCNNode(geometry: sphere(0.95, white))
        head.position = SCNVector3(0, 0.95, 0.1)
        petRoot.addChildNode(head)

        // 耳朵
        for sx in [-1.0, 1.0] {
            let ear = SCNNode(geometry: cone(0.32, 0.55, white))
            ear.position = SCNVector3(sx * 0.55, 1.65, 0)
            ear.eulerAngles = SCNVector3(0, 0, sx * -0.25)
            petRoot.addChildNode(ear)
            let inner = SCNNode(geometry: cone(0.18, 0.34, mint))
            inner.position = SCNVector3(0, 0.02, 0.08)
            ear.addChildNode(inner)
        }

        // 头顶嫩芽
        let stem = SCNNode(geometry: cylinder(0.04, 0.45, mint))
        stem.position = SCNVector3(0, 2.05, 0)
        petRoot.addChildNode(stem)
        for sx in [-1.0, 1.0] {
            let leaf = SCNNode(geometry: sphere(0.16, mint))
            leaf.scale = SCNVector3(1.3, 0.5, 0.8)
            leaf.position = SCNVector3(sx * 0.16, 2.28, 0)
            leaf.eulerAngles = SCNVector3(0, 0, sx * -0.5)
            petRoot.addChildNode(leaf)
        }

        // 眼睛（白底 + 黑瞳）：瞳孔跟随、眼白做表情
        let (eL, pL) = makeEye(at: SCNVector3(-0.34, 1.02, 0.92), white: white, black: black)
        let (eR, pR) = makeEye(at: SCNVector3(0.34, 1.02, 0.92), white: white, black: black)
        eyeFollowNodes = [pL, pR]; eyeFollowBase = [pL.position, pR.position]
        eyeExprNodes = [eL, eR];   eyeExprBase = [eL.scale, eR.scale]
        eyeShift = 0.08

        // 腮红
        for sx in [-1.0, 1.0] {
            let cheek = SCNNode(geometry: sphere(0.16, pink))
            cheek.scale = SCNVector3(1.2, 0.7, 0.3)
            cheek.position = SCNVector3(sx * 0.62, 0.78, 0.78)
            petRoot.addChildNode(cheek)
        }
        // 鼻子
        let nose = SCNNode(geometry: sphere(0.06, black))
        nose.position = SCNVector3(0, 0.84, 1.02)
        petRoot.addChildNode(nose)

        // 薄荷围巾 + 铃铛
        let scarf = SCNNode(geometry: torus(0.74, 0.14, mint))
        scarf.eulerAngles = SCNVector3(0.30, 0, 0)
        scarf.position = SCNVector3(0, 0.46, 0.05)
        petRoot.addChildNode(scarf)
        let bell = SCNNode(geometry: sphere(0.12, gold))
        bell.position = SCNVector3(0, 0.30, 0.82)
        petRoot.addChildNode(bell)
    }

    /// 返回 (眼白节点, 瞳孔节点)。
    private func makeEye(at pos: SCNVector3, white: SCNMaterial, black: SCNMaterial) -> (SCNNode, SCNNode) {
        let eye = SCNNode(geometry: sphere(0.2, white))
        eye.scale = SCNVector3(1, 1.15, 0.6)
        eye.position = pos
        petRoot.addChildNode(eye)
        let pupil = SCNNode(geometry: sphere(0.13, black))
        pupil.position = SCNVector3(0, 0, 0.16)
        eye.addChildNode(pupil)
        let glint = SCNNode(geometry: sphere(0.04, material(.white)))
        glint.position = SCNVector3(0.04, 0.05, 0.13)
        pupil.addChildNode(glint)
        return (eye, pupil)
    }

    // MARK: - 几何 / 材质工具

    private func material(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.9
        m.metalness.contents = 0.0
        return m
    }
    private func sphere(_ r: CGFloat, _ m: SCNMaterial) -> SCNGeometry {
        let g = SCNSphere(radius: r); g.segmentCount = 48; g.materials = [m]; return g
    }
    private func cone(_ top: CGFloat, _ h: CGFloat, _ m: SCNMaterial) -> SCNGeometry {
        let g = SCNCone(topRadius: 0, bottomRadius: top, height: h); g.materials = [m]; return g
    }
    private func cylinder(_ r: CGFloat, _ h: CGFloat, _ m: SCNMaterial) -> SCNGeometry {
        let g = SCNCylinder(radius: r, height: h); g.materials = [m]; return g
    }
    private func torus(_ ring: CGFloat, _ pipe: CGFloat, _ m: SCNMaterial) -> SCNGeometry {
        let g = SCNTorus(ringRadius: ring, pipeRadius: pipe); g.materials = [m]; return g
    }
}
