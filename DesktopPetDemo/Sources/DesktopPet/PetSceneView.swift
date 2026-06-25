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

    // 动画分层：idleNode(待机噪声) → headNode(头朝向弹簧) → petRoot(动作+内容)，各层只被一个系统写，互不覆盖。
    private var idleNode: SCNNode!
    private var headNode: SCNNode!
    private var petRoot: SCNNode!                   // 动作（弹跳/旋转/穿越）+ 模型内容都挂在它

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

    /// 表演特殊动作（跳舞 / 穿越）时挂起头/眼跟随，避免覆盖动作。
    private var trackingSuspended = false
    func setTrackingSuspended(_ s: Bool) { trackingSuspended = s }

    // 头/身朝向 + 眼睛跟手：目标值 + 临界阻尼弹簧（追-过-回的灵动）
    private var lookActive = true
    private var cursorNX: CGFloat = 0, cursorNY: CGFloat = 0   // 归一化光标方向 [-1,1]
    private var headYawSpring = Spring(stiffness: Tunables.followStiffness, damping: Tunables.followDamping)
    private var headPitchSpring = Spring(stiffness: Tunables.followStiffness, damping: Tunables.followDamping)
    private var eyeXSpring = Spring(stiffness: Tunables.eyeFollowStiffness, damping: Tunables.eyeFollowDamping)
    private var eyeYSpring = Spring(stiffness: Tunables.eyeFollowStiffness, damping: Tunables.eyeFollowDamping)
    func setLookActive(_ b: Bool) { lookActive = b }

    private var animTime: Double = 0       // tick 累计时间，驱动 idle 噪声 + 看别处调度

    // 偶发"看别处"：到时给一个短暂的伪光标目标
    private var nextLookAwayAt: Double = Double.random(in: Tunables.lookAwayMin...Tunables.lookAwayMax)
    private var lookAwayUntil: Double = 0
    private var lookAwayTarget = (x: CGFloat(0), y: CGFloat(0))

    // 次级运动（耳朵/围巾/嫩芽/铃铛等软部件：用位移做滞后摆动，避免绕错枢轴）
    private struct Appendage {
        let node: SCNNode
        let restPosition: SCNVector3
        let span: CGFloat              // 部件本地半径，限幅按它换算
        var sx = Spring(stiffness: Tunables.secondaryStiffness, damping: Tunables.secondaryDamping)
        var sy = Spring(stiffness: Tunables.secondaryStiffness, damping: Tunables.secondaryDamping)
    }
    private var appendages: [Appendage] = []
    private var rawAppendages: [SCNNode] = []   // 占位构建时直接填充
    private var prevPetYaw: CGFloat = 0
    private var prevPetPosY: CGFloat = 0

    private var isDancing = false

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
        idleNode = SCNNode()
        headNode = SCNNode()
        petRoot = SCNNode()
        scene.rootNode.addChildNode(idleNode)
        idleNode.addChildNode(headNode)
        headNode.addChildNode(petRoot)

        // 多级兜底：刚体部件模型 pet.usdz（做部件级萌系动画）→ 占位猫。
        // 注：pet_dance.usdz（UsdSkel 骨骼）SceneKit 渲染不出，loadDanceModel 已不在加载链上
        //（方法保留备查）；跳舞改为纯刚体部件编排。
        if loadModel(into: petRoot) {
            collectAppendages()
        } else {
            buildPlaceholderPet()
            collectAppendages()
        }
    }

    /// 通用加载：reparent → Z-up 扶正 + 面向镜头 → 双面修复 → 归一化居中。返回容器节点。
    private func mountModel(url: URL, into parent: SCNNode) -> SCNNode? {
        guard let modelScene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
        let yaw = SCNNode()
        yaw.eulerAngles = SCNVector3(0, -CGFloat.pi / 2, 0)   // 面向镜头
        parent.addChildNode(yaw)

        let container = SCNNode()
        for child in Array(modelScene.rootNode.childNodes) { container.addChildNode(child) }
        container.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)   // USD Z-up → SceneKit Y-up
        yaw.addChildNode(container)

        var meshCount = 0
        var lo = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        container.enumerateHierarchy { node, _ in
            guard let geo = node.geometry else { return }
            meshCount += 1
            for m in geo.materials {
                m.isDoubleSided = true
                m.metalness.contents = 0.0
                m.roughness.contents = 0.85
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
        NSLog(String(format: "[Pet] mount meshes=%d bbox=(%.2f,%.2f,%.2f)~(%.2f,%.2f,%.2f) sizeY=%.3f scale=%.4f pos=(%.2f,%.2f,%.2f)",
                     meshCount, Double(lo.x), Double(lo.y), Double(lo.z), Double(hi.x), Double(hi.y), Double(hi.z),
                     Double(sizeY), Double(s), Double(container.position.x), Double(container.position.y), Double(container.position.z)))
        return container
    }

    /// 【已停用，保留备查】加载 pet_dance.usdz（UsdSkel 骨骼版）作静态展示。
    ///
    /// SceneKit 渲染不了这只 Tripo 的 UsdSkel 蒙皮（一开 skinner 整只塌缩消失，已验证：关掉 skinner
    /// 的 rest pose 渲染完美；isPlaying/拉远/转 .scn 均无效；RealityKit 实测可正常蒙皮+播放）。
    /// 现已改为主用纯网格 pet.usdz + 刚体部件编排，本方法不在加载链上；如需骨骼舞请走 RealityKit。
    private func loadDanceModel(into parent: SCNNode) -> Bool {
        guard let url = Bundle.module.url(forResource: "pet_dance", withExtension: "usdz", subdirectory: "Resources"),
              let ref = SCNReferenceNode(url: url) else {
            return false
        }
        ref.load()
        guard !ref.childNodes.isEmpty else { return false }

        let yaw = SCNNode()
        yaw.eulerAngles = SCNVector3(0, -CGFloat.pi / 2, 0)   // 面向镜头
        parent.addChildNode(yaw)
        let container = SCNNode()
        container.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)   // USD Z-up → SceneKit Y-up
        yaw.addChildNode(container)
        container.addChildNode(ref)

        var meshCount = 0
        var lo = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        ref.enumerateHierarchy { node, _ in
            node.skinner = nil                       // SceneKit 渲染不了该 UsdSkel 蒙皮(已穷尽测试)，关掉用 rest pose
            guard let geo = node.geometry else { return }
            meshCount += 1
            for m in geo.materials { m.isDoubleSided = true; m.metalness.contents = 0.0; m.roughness.contents = 0.85 }
            let bb = node.boundingBox
            for cx in [bb.min.x, bb.max.x] { for cy in [bb.min.y, bb.max.y] { for cz in [bb.min.z, bb.max.z] {
                let w = node.convertPosition(SCNVector3(cx, cy, cz), to: yaw)
                lo.x = Swift.min(lo.x, w.x); lo.y = Swift.min(lo.y, w.y); lo.z = Swift.min(lo.z, w.z)
                hi.x = Swift.max(hi.x, w.x); hi.y = Swift.max(hi.y, w.y); hi.z = Swift.max(hi.z, w.z)
            }}}
        }
        let sizeY = max(hi.y - lo.y, 0.0001)
        let s = 3.0 / sizeY
        container.scale = SCNVector3(s, s, s)
        container.position = SCNVector3(-(lo.x + hi.x) / 2 * s, 0.2 - (lo.y + hi.y) / 2 * s, -(lo.z + hi.z) / 2 * s)

        bindEyeNodes(in: ref)
        NSLog("[Pet] 已加载 pet_dance.usdz(静态 rest pose, skinner 关) meshes=\(meshCount) 眼睛节点=\(eyeFollowNodes.count)")
        return true
    }

    /// 加载静态 pet.usdz：归一化 + 识别眼睛。
    private func loadModel(into parent: SCNNode) -> Bool {
        guard let url = Bundle.module.url(forResource: "pet", withExtension: "usdz", subdirectory: "Resources"),
              let container = mountModel(url: url, into: parent) else {
            NSLog("[Pet] 未找到/无法加载 pet.usdz，使用占位模型")
            return false
        }
        bindEyeNodes(in: container)
        NSLog("[Pet] 已加载 pet.usdz 眼睛节点=\(eyeFollowNodes.count) names=\(eyeFollowNodes.map { $0.name ?? "?" })")
        return true
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

    /// 记录归一化的光标方向；真正的头/眼逼近在 tick(dt:) 里用弹簧完成（带"追、过、回"）。
    func lookToward(dx: Double, dy: Double) {
        let scale = 260.0
        cursorNX = CGFloat(max(-1, min(1, dx / scale)))
        cursorNY = CGFloat(max(-1, min(1, dy / scale)))
    }

    /// 每帧推进（dt≈1/60，由 AppDelegate 60Hz 回调）：
    /// 跟手弹簧（追-过-回）+ 偶发看别处 + 待机噪声（呼吸/摆/眨眼另由定时器）+ 次级运动。
    func tick(dt: CGFloat) {
        animTime += Double(dt)
        let active = lookActive && !trackingSuspended

        // —— 偶发"看别处"：到点选随机方向短暂转头，再回到跟手 ——
        if active, animTime >= nextLookAwayAt {
            let ang = CGFloat.random(in: 0 ..< (2 * .pi))
            lookAwayTarget = (cos(ang), sin(ang) * 0.6)        // 竖直分量收一点更自然
            lookAwayUntil = animTime + Tunables.lookAwayHold
            nextLookAwayAt = animTime + Double.random(in: Tunables.lookAwayMin ... Tunables.lookAwayMax)
        }
        let lookingAway = animTime < lookAwayUntil
        let nx = lookingAway ? lookAwayTarget.x : cursorNX
        let ny = lookingAway ? lookAwayTarget.y : cursorNY

        // —— 头/身朝向：弹簧逼近，作用在 headNode（与动作层 petRoot 解耦）——
        let tYaw   = active ? nx * Tunables.headTiltMax : 0
        let tPitch = active ? -ny * Tunables.headTiltMax * Tunables.headPitchScale : 0
        headYawSpring.step(target: tYaw, dt: dt)
        headPitchSpring.step(target: tPitch, dt: dt)
        headNode?.eulerAngles = SCNVector3(headPitchSpring.value, headYawSpring.value, 0)

        // —— 眼睛跟手：弹簧平移（沿用 eyeShift 幅度）——
        let tEyeX = active ? nx * eyeShift : 0
        let tEyeY = active ? ny * eyeShift : 0
        eyeXSpring.step(target: tEyeX, dt: dt)
        eyeYSpring.step(target: tEyeY, dt: dt)
        for (i, eye) in eyeFollowNodes.enumerated() where i < eyeFollowBase.count {
            let b = eyeFollowBase[i]
            eye.position.x = b.x + eyeXSpring.value
            eye.position.y = b.y + eyeYSpring.value
        }

        // —— 待机噪声：呼吸(缩放+浮动) + 重心慢摆（永不完全静止）；跳舞时冻结让编排动作干净呈现 ——
        if isDancing {
            idleNode?.position = SCNVector3(0, 0, 0)
            idleNode?.eulerAngles = SCNVector3(0, 0, 0)
            idleNode?.scale = SCNVector3(1, 1, 1)
        } else {
            let breathPhase = animTime * Tunables.breathHz * 2 * .pi   // 正弦本身即两端慢中间快(inOutSine 性质)
            let breath = 1 + Tunables.breathAmp * CGFloat(sin(breathPhase))
            idleNode?.scale = SCNVector3(breath, breath, breath)
            idleNode?.position.y = Tunables.bobAmp * CGFloat(sin(breathPhase))
            idleNode?.eulerAngles = SCNVector3(0, 0, Tunables.swayAmp * CGFloat(sin(animTime * Tunables.swayHz * 2 * .pi)))
        }

        stepSecondary(dt: dt)
    }

    /// 次级运动：软部件用"位移"滞后于身体的转动/起伏（位移而非旋转，避免绕错枢轴甩飞），
    /// 身体停下后弹簧带轻微过冲回正。
    private func stepSecondary(dt: CGFloat) {
        guard !appendages.isEmpty, let root = petRoot else { return }

        // 身体这帧的角速度(偏航) / 竖直速度——含编排动作 + 头朝向带来的运动
        let yaw = root.eulerAngles.y + headYawSpring.value
        let posY = root.position.y
        let safeDt = max(dt, 0.0001)
        let yawVel = (yaw - prevPetYaw) / safeDt
        let bobVel = (posY - prevPetPosY) / safeDt
        prevPetYaw = yaw
        prevPetPosY = posY

        let clamp = Tunables.secondaryClamp
        for i in appendages.indices {
            let span = appendages[i].span
            let cx = max(-clamp, min(clamp, -yawVel * Tunables.secondaryYawGain)) * span
            let cy = max(-clamp, min(clamp, -bobVel * Tunables.secondaryBobGain)) * span
            appendages[i].sx.step(target: cx, dt: dt)
            appendages[i].sy.step(target: cy, dt: dt)
            let rest = appendages[i].restPosition
            appendages[i].node.position = SCNVector3(rest.x + appendages[i].sx.value,
                                                     rest.y + appendages[i].sy.value,
                                                     rest.z)
        }
    }

    private func collectAppendages() {
        let nodes = rawAppendages.isEmpty ? detectAppendages() : rawAppendages
        appendages = nodes.map { n in
            let span = max(CGFloat(n.boundingSphere.radius) * n.scale.x, 0.02)
            return Appendage(node: n, restPosition: n.position, span: span)
        }
        prevPetYaw = headYawSpring.value + (petRoot?.eulerAngles.y ?? 0)
        prevPetPosY = petRoot?.position.y ?? 0
        NSLog("[Pet] 次级运动软部件=\(appendages.count) 眼睛=\(eyeFollowNodes.count)")
    }

    /// 真模型启发式：把"较小且非眼睛"的部件（耳朵/嫩芽/铃铛/围巾）选为软部件做次级摆动。
    /// 大块（身体/头）跟 petRoot 整体走，不单独抖。找不到合适小件就返回空，安全降级。
    private func detectAppendages() -> [SCNNode] {
        var parts: [(node: SCNNode, r: CGFloat)] = []
        petRoot.enumerateChildNodes { n, _ in
            guard n.geometry != nil else { return }
            parts.append((n, CGFloat(n.boundingSphere.radius) * n.scale.x))
        }
        guard parts.count >= 2 else { return [] }
        let eyeSet = Set(eyeFollowNodes.map { ObjectIdentifier($0) })
        let radii = parts.map { $0.r }.sorted()
        let medR = radii[radii.count / 2]
        return parts
            .filter { $0.r <= medR * 1.05 && !eyeSet.contains(ObjectIdentifier($0.node)) }
            .sorted { $0.r < $1.r }                       // 最小的优先（最像软挂件）
            .prefix(Tunables.secondaryMaxParts)
            .map { $0.node }
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
        let interval = Double.random(in: Tunables.blinkMin ... Tunables.blinkMax)
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.blinkOnce()
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    /// 一次快速眨眼：竖轴压到 ~0.1 再弹回；偶尔双眨，更像真人。
    private func blinkOnce() {
        guard !trackingSuspended, !eyeExprNodes.isEmpty else { scheduleNextBlink(); return }
        let close = Tunables.blinkClose, cd = Tunables.blinkCloseDur, od = Tunables.blinkOpenDur
        applyEyeOpenness(close, duration: cd)           // 闭
        DispatchQueue.main.asyncAfter(deadline: .now() + cd) { [weak self] in
            guard let self else { return }
            self.applyEyeOpenness(self.currentOpenness, duration: od)   // 睁回当前表情
            if Double.random(in: 0...1) < 0.12 {        // ~12% 概率双眨
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    self.applyEyeOpenness(close, duration: cd)
                    DispatchQueue.main.asyncAfter(deadline: .now() + cd) {
                        self.applyEyeOpenness(self.currentOpenness, duration: od)
                        self.scheduleNextBlink()
                    }
                }
            } else {
                self.scheduleNextBlink()
            }
        }
    }

    private func applyGesture(for mood: PetMood) {
        guard !isDancing else { return }   // 跳舞期间不让表情手势清掉/覆盖 petRoot 的编排旋转
        petRoot.removeAction(forKey: "sway")
        petRoot.removeAction(forKey: "chew")
        if mood != .sleepy { petRoot.eulerAngles = SCNVector3(0, 0, 0) }   // 清掉上一个动作残留的旋转
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
        // 挤压拉伸：压扁蓄力 → 弹起拉长 → 回弹复原（scale 反相变化）
        let squash  = nonUniformScale(from: SCNVector3(1, 1, 1),       to: SCNVector3(1.10, 0.90, 1.10), dur: 0.09)
        let stretch = nonUniformScale(from: SCNVector3(1.10, 0.90, 1.10), to: SCNVector3(0.92, 1.14, 0.92), dur: 0.12)
        let settle  = nonUniformScale(from: SCNVector3(0.92, 1.14, 0.92), to: SCNVector3(1, 1, 1),       dur: 0.16)
        petRoot.runAction(.sequence([squash, stretch, settle]), forKey: "bounce")
    }

    /// 从 `from` 经 `ease` 曲线（默认 ease-out cubic）到 `to` 的非均匀缩放动作。
    private func nonUniformScale(from: SCNVector3, to: SCNVector3, dur: CFTimeInterval,
                                ease: @escaping (Double) -> Double = Ease.outCubic) -> SCNAction {
        SCNAction.customAction(duration: dur) { node, elapsed in
            let p = dur > 0 ? min(1.0, Double(elapsed) / dur) : 1.0
            let e = CGFloat(ease(p))
            node.scale = SCNVector3(from.x + (to.x - from.x) * e,
                                    from.y + (to.y - from.y) * e,
                                    from.z + (to.z - from.z) * e)
        }
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

    /// 触发跳舞：一段约 5 秒、纯刚体部件编排的萌舞——
    /// 左右摇摆 groove → 点头(过冲) → 小跳 → 扭身(inOutSine) → 小跳 → 缓动转圈收尾(反向蓄力+回弹)。
    /// 旋转幅度做足以读出"在跳舞"、竖直小跳收小别盖过旋转；全程冻结呼吸、挂起跟手，耳朵/围巾/铃铛
    /// 由次级运动自动跟着甩；结束平滑回待机。可反复触发（打断重跳）。
    func dance(loop: Bool = false) {
        guard let petRoot else { return }
        petRoot.removeAction(forKey: "dance")               // 允许重复触发：打断上一段
        petRoot.eulerAngles = SCNVector3(0, 0, 0)           // 从干净姿态起跳，避免相对动作累积漂移
        petRoot.position = SCNVector3(0, 0, 0)
        petRoot.scale = SCNVector3(1, 1, 1)
        isDancing = true
        trackingSuspended = true

        // 编排：先左右摇摆 groove（最像跳舞）→ 点头 → 小跳 → 扭身 → 小跳 → 转圈收尾
        let routine = SCNAction.sequence([swayBeats(), nodBeats(), hopBeat(), twistBeats(), hopBeat(), spinBeat()])
        let body: SCNAction = loop ? .repeatForever(routine) : routine
        petRoot.runAction(body, forKey: "dance") { [weak self] in
            petRoot.eulerAngles = SCNVector3(0, 0, 0)
            petRoot.position = SCNVector3(0, 0, 0)
            petRoot.scale = SCNVector3(1, 1, 1)
            self?.isDancing = false
            self?.trackingSuspended = false
        }
    }

    /// 左右摇摆 groove：身体侧倾(绕 Z) + 每拍轻微下沉，像踩拍子摇摆——最能读出"在跳舞"。净旋转/位移 0。
    private func swayBeats() -> SCNAction {
        let a = Tunables.danceSway
        func lean(_ delta: CGFloat) -> SCNAction {
            .group([
                SCNAction.rotateBy(x: 0, y: 0, z: delta, duration: 0.32).eased(Ease.inOutSine),
                SCNAction.sequence([
                    SCNAction.moveBy(x: 0, y: -0.05, z: 0, duration: 0.16).eased(Ease.inOutSine),
                    SCNAction.moveBy(x: 0, y: 0.05, z: 0, duration: 0.16).eased(Ease.inOutSine)
                ])
            ])
        }
        // 侧倾序列：+a,-2a,+2a,-a → 倾角 a,-a,a,0（左右各两拍），净回正
        return .sequence([lean(a), lean(-2 * a), lean(2 * a), lean(-a)])
    }

    /// 节拍点头：两下，绕 X 下-上，落点用 backOut 过冲（净旋转 0）。
    private func nodBeats() -> SCNAction {
        let down = SCNAction.rotateBy(x: Tunables.danceNod, y: 0, z: 0, duration: 0.18).eased { Ease.backOut($0) }
        let up = SCNAction.rotateBy(x: -Tunables.danceNod, y: 0, z: 0, duration: 0.18).eased(Ease.outCubic)
        return .sequence([down, up, down, up])
    }

    /// 左右扭身：绕 Y 来回，inOutSine（净旋转 0：-t, +2t, -t）。
    private func twistBeats() -> SCNAction {
        let t = Tunables.danceTwist
        let l = SCNAction.rotateBy(x: 0, y: -t, z: 0, duration: 0.30).eased(Ease.inOutSine)
        let r = SCNAction.rotateBy(x: 0, y: 2 * t, z: 0, duration: 0.42).eased(Ease.inOutSine)
        let back = SCNAction.rotateBy(x: 0, y: -t, z: 0, duration: 0.30).eased(Ease.inOutSine)
        return .sequence([l, r, back])
    }

    /// 一次小跳：蓄力下蹲 → 升空瘦高(stretch) → 落地矮胖(squash) → backOut 回弹复原。位移净值 0。
    private func hopBeat() -> SCNAction {
        let h = Tunables.danceHopHeight, sq = Tunables.danceSquash
        let crouch  = SCNVector3(1 + sq, 1 - sq, 1 + sq)
        let stretch = SCNVector3(1 - sq, 1 + sq * 1.15, 1 - sq)
        let down = nonUniformScale(from: SCNVector3(1, 1, 1), to: crouch, dur: 0.10)
        let rise = SCNAction.group([
            nonUniformScale(from: crouch, to: stretch, dur: 0.18),
            SCNAction.moveBy(x: 0, y: h, z: 0, duration: 0.18).eased(Ease.outCubic)
        ])
        let fall = SCNAction.group([
            nonUniformScale(from: stretch, to: crouch, dur: 0.16, ease: Ease.inCubic),
            SCNAction.moveBy(x: 0, y: -h, z: 0, duration: 0.16).eased(Ease.inCubic)
        ])
        let recover = nonUniformScale(from: crouch, to: SCNVector3(1, 1, 1), dur: 0.16, ease: { Ease.backOut($0) })
        return .sequence([down, rise, fall, recover])
    }

    /// 缓动转圈：先反向蓄力(inCubic) → 整圈 outCubic 收尾 → 小过冲再回弹（净旋转恰好 2π，落回原朝向）。
    private func spinBeat() -> SCNAction {
        let w = Tunables.danceWindup
        let windup = SCNAction.rotateBy(x: 0, y: -w, z: 0, duration: 0.15).eased(Ease.inCubic)
        let spin = SCNAction.rotateBy(x: 0, y: 2 * .pi + w, z: 0, duration: 0.70).eased(Ease.outCubic)
        let over = SCNAction.rotateBy(x: 0, y: 0.10, z: 0, duration: 0.12).eased(Ease.outCubic)
        let back = SCNAction.rotateBy(x: 0, y: -0.10, z: 0, duration: 0.14).eased(Ease.inOutSine)
        return .sequence([windup, spin, over, back])
    }

    /// 穿越——"被吸进黑洞"：旋转 + 缩小同步进行（与上层的滑动同时启动，螺旋着被吸入）。
    /// 缩小用 easeIn：前段保持大、后段才缩没，配合滑动 easeOut 让"移动"清晰可见。
    func playEnterPortal(completion: @escaping () -> Void) {
        guard let petRoot else { completion(); return }
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
        petRoot.runAction(grow)
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
            dance()                 // 双击 → 跳舞
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
            rawAppendages.append(ear)
            let inner = SCNNode(geometry: cone(0.18, 0.34, mint))
            inner.position = SCNVector3(0, 0.02, 0.08)
            ear.addChildNode(inner)
        }

        // 头顶嫩芽
        let stem = SCNNode(geometry: cylinder(0.04, 0.45, mint))
        stem.position = SCNVector3(0, 2.05, 0)
        petRoot.addChildNode(stem)
        rawAppendages.append(stem)
        for sx in [-1.0, 1.0] {
            let leaf = SCNNode(geometry: sphere(0.16, mint))
            leaf.scale = SCNVector3(1.3, 0.5, 0.8)
            leaf.position = SCNVector3(sx * 0.16, 2.28, 0)
            leaf.eulerAngles = SCNVector3(0, 0, sx * -0.5)
            petRoot.addChildNode(leaf)
            rawAppendages.append(leaf)
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
        rawAppendages.append(bell)
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
