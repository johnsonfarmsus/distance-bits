import AVFoundation
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
    if let controller = window?.rootViewController as? FlutterViewController {
      let cam = FlutterMethodChannel(name: "distance_bits/camera", binaryMessenger: controller.binaryMessenger)
      cam.setMethodCallHandler { call, result in
        AppDelegate.handleCamera(call, result)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Manual exposure + white balance on the camera the Flutter camera plugin opened.
  /// The plugin names cameras by AVCaptureDevice.uniqueID, and devices are shared
  /// objects, so configuring the device here affects the running session.
  /// A screen is far brighter than a dim room: auto exposure picks a long shutter
  /// that both clips the colours and blends consecutive frames together.
  static func handleCamera(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard let id = args["id"] as? String, let dev = AVCaptureDevice(uniqueID: id) else {
      result(FlutterError(code: "no_device", message: "camera not found", details: nil))
      return
    }
    let fmt = dev.activeFormat
    switch call.method {
    case "info":
      result([
        "minISO": Double(fmt.minISO), "maxISO": Double(fmt.maxISO),
        "minDur": CMTimeGetSeconds(fmt.minExposureDuration), "maxDur": CMTimeGetSeconds(fmt.maxExposureDuration),
        "iso": Double(dev.iso), "dur": CMTimeGetSeconds(dev.exposureDuration),
      ])
    case "manual":
      let d = min(max(args["dur"] as? Double ?? 0.001, CMTimeGetSeconds(fmt.minExposureDuration)), CMTimeGetSeconds(fmt.maxExposureDuration))
      let iso = Float(min(max(args["iso"] as? Double ?? 100, Double(fmt.minISO)), Double(fmt.maxISO)))
      do {
        try dev.lockForConfiguration()
        dev.setExposureModeCustom(duration: CMTimeMakeWithSeconds(d, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
        if args["daylightWB"] as? Bool ?? false, dev.isWhiteBalanceModeSupported(.locked) {
          var g = dev.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: 6500, tint: 0))
          let mx = dev.maxWhiteBalanceGain
          g.redGain = min(max(g.redGain, 1), mx)
          g.greenGain = min(max(g.greenGain, 1), mx)
          g.blueGain = min(max(g.blueGain, 1), mx)
          dev.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
        }
        dev.unlockForConfiguration()
        result(["iso": Double(iso), "dur": d])
      } catch {
        result(FlutterError(code: "lock_failed", message: error.localizedDescription, details: nil))
      }
    case "auto":
      do {
        try dev.lockForConfiguration()
        if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
        dev.unlockForConfiguration()
        result(nil)
      } catch {
        result(FlutterError(code: "lock_failed", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    // Don't leave the phone stuck at full brightness if the user switches away mid-send.
    if let b = savedBrightness { UIScreen.main.brightness = b }
    savedBrightness = nil
    super.applicationWillResignActive(application)
  }
}
