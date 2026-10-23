import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let thermal = FlutterMethodChannel(
      name: "gatomix/thermal",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    thermal.setMethodCallHandler { call, result in
      if call.method == "status" {
        result(ProcessInfo.processInfo.thermalState.rawValue)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
