import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.gatonegro5.gatomix/library",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      if call.method == "queryLocalSongs" {
        result(GatomixIosLibrary.queryLocalSongs())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

enum GatomixIosLibrary {
  static func queryLocalSongs() -> [[String: Any]] {
    guard MPMediaLibrary.authorizationStatus() == .authorized else {
      return []
    }
    guard let items = MPMediaQuery.songs().items else {
      return []
    }
    var rows: [[String: Any]] = []
    for item in items {
      if item.hasProtectedAsset { continue }
      if item.isCloudItem { continue }
      guard let asset = item.assetURL else { continue }
      let albumId = item.albumPersistentID
      let album = item.albumTitle ?? "Apple Music"
      let added = item.dateAdded?.timeIntervalSince1970 ?? 0
      rows.append([
        "path": asset.absoluteString,
        "folder": "album:\(albumId)",
        "label": album,
        "modifiedMs": Int(added * 1000),
        "size": 0,
      ])
    }
    return rows
  }
}
