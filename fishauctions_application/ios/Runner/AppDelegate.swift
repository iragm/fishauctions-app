import AVFoundation
import Flutter
import SquareMobilePaymentsSDK
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Mirror of MainActivity.kt's channel. getSdkInt / isTapToPayCapable are
  // deliberately NOT implemented here: they're Android-only questions — the
  // Dart side guards them, and iOS capability comes from the Square plugin's
  // own isDeviceCapable().
  private static let platformChannelName = "com.fishauctions.app/platform"
  private static let cachedSquareAppIdKey = "square_application_id"
  // Process-wide, matching the SDK's process-scoped singleton.
  private static var squareInitializedAppId: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Square wants initialize() inside didFinishLaunching, but our app id is
    // server-driven (/api/mobile/config/ — one binary serves any deployment).
    // So: every launch after the first successful config fetch initializes
    // early here from the cached id; only the very first run initializes late
    // via the "initializeSquare" channel call below. Same restart-to-switch-
    // deployments semantics as Android.
    if let cached = UserDefaults.standard.string(forKey: Self.cachedSquareAppIdKey),
      !cached.isEmpty
    {
      Self.initializeSquare(applicationId: cached)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FishAuctionsPlatform")
    else {
      return
    }
    let channel = FlutterMethodChannel(
      name: Self.platformChannelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "initializeSquare":
        let arguments = call.arguments as? [String: Any]
        Self.handleInitializeSquare(
          applicationId: arguments?["applicationId"] as? String,
          result: result
        )
      case "getCameraFov":
        Self.handleGetCameraFov(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // Horizontal field of view of the back wide camera in degrees, or nil when
  // unavailable — the same camera mobile_scanner captures with. AR lot mode
  // uses it to compute accurate QR bearings without a hardcoded FOV guess.
  private static func handleGetCameraFov(result: FlutterResult) {
    guard
      let device = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .back)
    else {
      result(nil)
      return
    }
    result(Double(device.activeFormat.videoFieldOfView))
  }

  private static func handleInitializeSquare(applicationId: String?, result: FlutterResult) {
    guard let applicationId, !applicationId.isEmpty else {
      result(
        FlutterError(code: "missing_app_id", message: "applicationId is required", details: nil))
      return
    }
    if let current = squareInitializedAppId {
      if current == applicationId {
        result(nil)  // idempotent for the same id
      } else {
        result(
          FlutterError(
            code: "already_initialized_other",
            message:
              "Square SDK already initialized for a different application id; "
              + "restart the app to switch deployments.",
            details: nil))
      }
      return
    }
    initializeSquare(applicationId: applicationId)
    result(nil)
  }

  private static func initializeSquare(applicationId: String) {
    guard squareInitializedAppId == nil else { return }
    // Same call as the Square plugin's example app. Non-throwing; a bad id
    // surfaces later as an authorize() failure with a clear SDK message.
    MobilePaymentsSDK.initialize(squareApplicationID: applicationId)
    squareInitializedAppId = applicationId
    // Cache so the next launch can initialize early, where Square wants it.
    UserDefaults.standard.set(applicationId, forKey: cachedSquareAppIdKey)
  }
}
