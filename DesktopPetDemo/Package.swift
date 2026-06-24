// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopPet",
    platforms: [.macOS(.v13)],
    targets: [
        // 跨端可复用的纯逻辑核心（Domain 层）：状态机、表情、协议。无 UI 依赖。
        .target(
            name: "PetCore",
            path: "Sources/PetCore"
        ),
        // macOS 端表现层：透明置顶窗口 + SceneKit 渲染。USDZ 由 SceneKit 原生加载，零第三方依赖。
        .executableTarget(
            name: "DesktopPet",
            dependencies: ["PetCore"],
            path: "Sources/DesktopPet",
            resources: [.copy("Resources")]
        ),
        // Domain 层单元测试。
        .testTarget(
            name: "PetCoreTests",
            dependencies: ["PetCore"],
            path: "Tests/PetCoreTests"
        )
    ]
)
