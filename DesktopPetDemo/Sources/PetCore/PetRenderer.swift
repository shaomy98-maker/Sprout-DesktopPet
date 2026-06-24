import Foundation

/// 渲染器抽象（计划书 3.2「用协议抽象渲染器」）。
///
/// Domain 层只认这个协议，不关心底层是 SceneKit、RealityKit 还是阶段二其它端的
/// Filament / Unity。各端各自提供实现，业务逻辑零改动。
public protocol PetRenderer: AnyObject {
    /// 切换到指定表情对应的动画 / 姿态。
    func render(mood: PetMood)

    /// 让宠物看向某方向（dx/dy 为鼠标相对宠物中心的偏移，像素）。
    func lookToward(dx: Double, dy: Double)
}
