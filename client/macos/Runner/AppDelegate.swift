import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // FileSwitch keeps running in the menu bar when its window is closed.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { TrayController.shared.openMain() }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
