import SceneKit

/// 萌系动画的纯工具层：缓动曲线、临界阻尼弹簧、集中可调参数。
/// 无任何 UI/节点依赖，方便单独调参与复用。

// MARK: - 缓动曲线

enum Ease {
    /// 收尾减速（自然落定）。
    static func outCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    /// 起步加速（蓄力）。
    static func inCubic(_ t: Double) -> Double { t * t * t }
    /// 两端慢、中间快（呼吸/扭身最自然）。
    static func inOutSine(_ t: Double) -> Double { -(cos(.pi * t) - 1) / 2 }
    /// 过冲回弹：收尾时越过目标再弹回（点头/落地的“萌”感来源）。
    static func backOut(_ t: Double, s: Double = 1.70158) -> Double {
        let p = t - 1
        return 1 + (s + 1) * pow(p, 3) + s * pow(p, 2)
    }

    /// SCNAction.timingFunction 用的 inOutSine（(Float)->Float）。
    static let inOutSineTiming: (Float) -> Float = { Float(inOutSine(Double($0))) }
}

extension SCNAction {
    /// 给动作套一条自定义时间曲线。用法：`.rotateBy(...).eased(Ease.outCubic)`，
    /// 带默认参数的曲线用闭包：`.eased { Ease.backOut($0) }`。
    @discardableResult
    func eased(_ curve: @escaping (Double) -> Double) -> SCNAction {
        timingFunction = { Float(curve(Double($0))) }
        return self
    }
}

// MARK: - 临界阻尼弹簧（次级运动 / 跟手都用它，产生“追-过-回”的灵动）

/// 一维弹簧。macOS 下 SCNVector3 分量为 CGFloat，故这里用 CGFloat 避免到处强转。
struct Spring {
    var value: CGFloat = 0
    var vel: CGFloat = 0
    var stiffness: CGFloat
    var damping: CGFloat

    init(stiffness: CGFloat = 60, damping: CGFloat = 14) {
        self.stiffness = stiffness
        self.damping = damping
    }

    /// 半隐式欧拉积分一步，朝 `target` 逼近。
    mutating func step(target: CGFloat, dt: CGFloat) {
        let a = (target - value) * stiffness - vel * damping
        vel += a * dt
        value += vel * dt
    }

    mutating func reset(to v: CGFloat = 0) { value = v; vel = 0 }
}

// MARK: - 集中可调参数（所有“手感”都在这调，幅度一律保守）

enum Tunables {
    // —— idle 噪声 ——
    static let breathAmp: CGFloat = 0.015       // 呼吸缩放幅度（1±此值）
    static let breathHz: Double = 0.55          // 呼吸频率
    static let swayAmp: CGFloat = 0.03          // 重心摆角(rad)
    static let swayHz: Double = 0.16            // 重心摆频率
    static let bobAmp: CGFloat = 0.022          // 呼吸上下浮动

    // —— 眨眼 ——
    static let blinkMin: Double = 3.0
    static let blinkMax: Double = 6.0
    static let blinkClose: CGFloat = 0.1        // 闭眼时竖轴缩放比例
    static let blinkCloseDur: Double = 0.12     // 闭眼用时
    static let blinkOpenDur: Double = 0.10      // 睁回用时

    // —— 偶发“看别处” ——
    static let lookAwayMin: Double = 5.0
    static let lookAwayMax: Double = 11.0
    static let lookAwayHold: Double = 0.9       // 看别处保持时长
    static let lookAwayAmount: CGFloat = 200    // 看别处的伪光标偏移量(像素)

    // —— 跟手 ——
    static let headTiltMax: CGFloat = 0.12      // 头/身朝光标最大倾角(rad)
    static let headPitchScale: CGFloat = 0.4    // 俯仰相对偏航的缩放
    static let followStiffness: CGFloat = 120
    static let followDamping: CGFloat = 18
    static let eyeFollowStiffness: CGFloat = 140
    static let eyeFollowDamping: CGFloat = 20

    // —— 次级运动（软部件滞后摆动，用位移实现避免绕错枢轴）——
    static let secondaryStiffness: CGFloat = 55
    static let secondaryDamping: CGFloat = 9
    static let secondaryYawGain: CGFloat = 0.14   // 身体角速度 → 水平位移 增益（太弱看不出就调大）
    static let secondaryBobGain: CGFloat = 0.22   // 身体竖直速度 → 竖直位移 增益
    static let secondaryClamp: CGFloat = 0.16     // 位移限幅（相对部件本地半径；太飘就调小）
    static let secondaryMaxParts = 8              // 最多几个软部件参与

    // —— 跳舞振幅（旋转幅度要够大才"读得出在跳舞"，别被竖直小跳盖过）——
    static let danceNod: CGFloat = 0.30         // 点头幅度(rad ≈17°)
    static let danceTwist: CGFloat = 0.50       // 扭身幅度(rad ≈29°，另一侧 2× 更夸张)
    static let danceSway: CGFloat = 0.38        // 左右侧倾摇摆(rad ≈22°，最能读出"在跳舞")
    static let danceHopHeight: CGFloat = 0.22   // 小跳高度（调小，别盖过旋转）
    static let danceSquash: CGFloat = 0.12      // 挤压拉伸幅度
    static let danceWindup: CGFloat = 0.30      // 转圈前反向蓄力角度(rad)

    // —— 肢体律动跳舞（关节装配版：胳膊/腿摆动 + 身体律动）——
    static let danceBeat: Double = 0.45         // 每拍时长
    static let danceBeats = 8                   // 总拍数
    static let danceArm: CGFloat = 0.6          // 抬臂摆角(rad ≈34°，别 >50° 否则刚体露缝)
    static let danceArmFollow: CGFloat = 0.25   // 另一只手的跟随比例
    static let danceLeg: CGFloat = 0.20         // 腿/脚摆角
    static let danceLegFollow: CGFloat = 0.6
    static let danceBodyLean: CGFloat = 0.12    // 身体侧倾(绕 Z)
    static let danceBodyYaw: CGFloat = 0.10     // 身体小转(绕 Y)
    static let danceBob: CGFloat = 0.06         // 身体上下 bob
}
