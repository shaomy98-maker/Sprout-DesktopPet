# DesktopPet — Mac 桌宠 Demo 骨架

一只用 SceneKit 基础几何体拼出的占位 3D 宠物，验证桌宠最核心的三件事：
**透明置顶窗口、眼睛跟随鼠标、点击穿透 + 拖动互动**。

## 运行方式

### 方式 A：命令行（最快）
```bash
cd DesktopPetDemo
swift run
```
首次会拉取/编译，几秒后桌面右下角出现宠物。`Ctrl+C` 退出，或点菜单栏 🐾 → 退出。

### 方式 B：Xcode（推荐开发）
直接用 Xcode 打开 `Package.swift`（File → Open，选中该文件），
选择 `DesktopPet` scheme，点 ▶️ 运行。

> 需要 macOS 13+ 与 Xcode 15+ / Swift 5.9+。

## 你会看到 / 能做的

- 宠物悬浮在桌面最前层，跨所有桌面（Space）显示。
- **眼睛（瞳孔）和头部实时跟随鼠标**，带阻尼平滑。
- 待机呼吸动画。
- **表情状态机**：单击=戳一戳(惊讶瞪眼)、双击/摸摸=开心(眯眼笑)、喂食=进食点头、
  拖动=被拖动、久无互动=打盹闭眼摇摆；瞬时表情会自动回到待机。
- **拖动宠物**移动位置。
- 鼠标移到宠物**身体以外区域时点击会穿透**到下层应用（桌面/其他 App 正常可点）。
- 菜单栏 🐾：戳一戳 / 摸摸 / 喂食 / 回到右下角 / 退出。

## 文件结构

分两个 target：`PetCore`（跨端可复用的纯逻辑 Domain 层）+ `DesktopPet`（macOS 表现层）。

| 文件 | 职责 |
|---|---|
| **PetCore**/`PetMood.swift` | 表情枚举 `PetMood` / 交互事件 `PetEvent` / 转移结果（`Codable`，跨端复用） |
| **PetCore**/`PetStateMachine.swift` | 事件驱动的表情状态机，纯逻辑、无 UI、可单测 |
| **PetCore**/`PetRenderer.swift` | 渲染器协议，Domain 通过它驱动渲染、不感知 SceneKit |
| `main.swift` | 进程入口，`.accessory` 模式常驻（不占 Dock） |
| `PetWindow.swift` | 透明 / 无边框 / 置顶 / 跨 Space 窗口（桌宠关键能力） |
| `PetSceneView.swift` | SceneKit 占位宠物 + 眼睛跟随 + 表情动画 + 手势→意图 |
| `AppDelegate.swift` | 菜单栏 + 60Hz 追踪循环 + 状态机驱动（眼睛跟随 / 点击穿透 / 犯困判定） |

`Tests/PetCoreTests/` 覆盖状态机全部转移规则（`swift test`，13 个用例）。

## 实现说明（对应计划书第 4 章）

- **眼睛跟随**用 `NSEvent.mouseLocation` 轮询，**无需任何权限**（不是全局事件监听）。
  正式版若要更精准的全局监听，再按计划书引导申请「辅助功能」权限。
- **点击穿透**：每帧用 `SCNView.hitTest` 判断鼠标是否落在宠物身上，
  动态切换 `window.ignoresMouseEvents`，实现"只有点到宠物才拦截"。
- **占位模型**全部是 `SCNSphere/SCNCone/...` 拼的。接正式资源时，只需在
  `PetSceneView.buildPet` 里改成加载 USDZ/SCN，并把 `leftPupil/rightPupil` 指向
  模型里的眼球节点即可，其余逻辑不动。

## 下一步接入正式 3D 模型

```swift
// 替换 buildPet 内容示意：
let scene = try! SCNScene(url: Bundle.module.url(forResource: "pet", withExtension: "usdz")!)
petRoot = scene.rootNode.childNode(withName: "PetRoot", recursively: true)
leftPupil  = petRoot.childNode(withName: "eye_L_pupil", recursively: true)
rightPupil = petRoot.childNode(withName: "eye_R_pupil", recursively: true)
```
（记得在 Package.swift 的 target 里加 `resources: [.process("Resources")]`。）
