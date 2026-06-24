# Sprout · 桌面宠物（Desktop Pet）

一只常驻 Mac 桌面的 3D 萌宠：透明无边框窗口悬浮在最前层，眼睛随鼠标转动，可以戳、摸、喂、拖，触发不同表情。本地优先，后续规划扩展到四端状态同步。

## 目录结构

| 路径 | 说明 |
|---|---|
| [桌面宠物_项目计划书与开发计划.md](桌面宠物_项目计划书与开发计划.md) | 完整项目计划书 & 开发计划（含阶段规划、技术选型、Sprint） |
| [DesktopPetDemo/](DesktopPetDemo/) | 可运行的 macOS 实现（SwiftPM） |

## 快速运行

```bash
cd DesktopPetDemo
swift run
```

详见 [DesktopPetDemo/README.md](DesktopPetDemo/README.md)。

## 技术栈

- **语言/框架**：Swift + AppKit（透明置顶窗口）+ SceneKit（3D 渲染）
- **架构**：`PetCore`（跨端可复用纯逻辑：表情状态机/协议，含单测）+ `DesktopPet`（macOS 表现层）
- **模型**：`pet.usdz`（Tripo 生成，运行时原生加载；缺失则退回基础几何体占位形象）
- **最低系统**：macOS 13

## 现状

- ✅ 透明置顶 / 跨 Space / 点击穿透窗口、拖动、菜单栏常驻
- ✅ 眼睛跟随鼠标、待机呼吸
- ✅ 表情状态机（待机/开心/惊讶/进食/被拖/打盹，13 个单测覆盖）
- ✅ 正式 3D 模型接入（USDZ）、可打包为通用 .app / .dmg 分发
- ⬜ 养成数值 + 持久化（Sprint 4，进行中规划）
