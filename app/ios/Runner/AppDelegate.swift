import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var savedBrightness: CGFloat?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Screen brightness for the sender: "max" while transmitting, "restore" after.
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "distance_bits/screen", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { return }
        switch call.method {
        case "max":
          if self.savedBrightness == nil { self.savedBrightness = UIScreen.main.brightness }
          UIScreen.main.brightness = 1.0
          result(nil)
        case "restore":
          if let b = self.savedBrightness { UIScreen.main.brightness = b }
          self.savedBrightness = nil
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    // Don't leave the phone stuck at full brightness if the user switches away mid-send.
    if let b = savedBrightness { UIScreen.main.brightness = b }
    savedBrightness = nil
    super.applicationWillResignActive(application)
  }
}
