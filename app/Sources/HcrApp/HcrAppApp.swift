import AppKit
import HcrMedia
import SwiftUI

@main
struct HcrAppApp: App {
  @StateObject private var model = AppModel()
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    Window("hc-remote", id: "main") {
      ContentView(model: model)
        .frame(minWidth: 1020, minHeight: 640)
    }
    .windowResizability(.contentMinSize)

    MenuBarExtra {
      Button("显示主界面") {
        showMainWindow()
      }
      Button("安全锁定") {
        model.securityLock()
        showMainWindow()
      }
      Button("帮助与反馈") {
        showHelp()
      }
      Divider()
      Button("退出") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    } label: {
      Image(
        systemName: model.deviceMode && model.isStreaming
          ? "desktopcomputer.trianglebadge.exclamationmark" : "desktopcomputer")
    }
    .menuBarExtraStyle(.menu)
  }

  private func showMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.title == "hc-remote" }) {
      window.makeKeyAndOrderFront(nil)
    } else {
      openWindow(id: "main")
    }
  }

  private func showHelp() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "hc-remote 远程"
    alert.informativeText = """
      点对点屏幕共享与远程控制（WebRTC 直连，无中转）。

      用法：双方进入同一房间号即可互投互控；也可在“我的设备”中添加 \
      对端设备房间，一键远控。

      详细文档见项目内 HANDOFF.md / DESIGN.md。
      """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "好的")
    alert.runModal()
  }
}
