import Cocoa

// 程序入口：以 .accessory 模式运行（不在 Dock 显示图标，像真正的桌宠常驻进程）
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
