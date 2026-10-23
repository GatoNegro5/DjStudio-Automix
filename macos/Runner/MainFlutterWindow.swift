import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var scopedUrls: [URL] = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    if let registrar = flutterViewController.registrar(forPlugin: "GatomixLibrary") {
      let channel = FlutterMethodChannel(
        name: "com.gatonegro5.gatomix/library",
        binaryMessenger: registrar.messenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(nil)
          return
        }
        switch call.method {
        case "musicFolder":
          let url = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
          result(url?.path)
        case "bookmark":
          result(self.makeBookmark(call.arguments as? String))
        case "resolveBookmark":
          result(self.resolveBookmark(call.arguments as? String))
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    super.awakeFromNib()
  }

  private func makeBookmark(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let data = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      return data.base64EncodedString()
    } catch {
      return nil
    }
  }

  private func resolveBookmark(_ encoded: String?) -> [String: String]? {
    guard let encoded, let data = Data(base64Encoded: encoded) else { return nil }
    var stale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      if url.startAccessingSecurityScopedResource() {
        scopedUrls.append(url)
      }
      var payload = ["path": url.path]
      if stale,
        let again = try? url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        ) {
        payload["bookmark"] = again.base64EncodedString()
      }
      return payload
    } catch {
      return nil
    }
  }
}
