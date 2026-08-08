import AVFoundation
import Flutter
import Speech
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
  // Retained for the engine's lifetime — it owns the AR event channels' stream handlers.
  private var arEvents: ArEventBridge?

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
      case "speechRecognitionAvailable":
        Self.handleSpeechRecognitionAvailable(result: result)
      case "getCameraFov":
        Self.handleGetCameraFov(result: result)
      case "tapToPayEducationAvailable":
        // iOS-only: Apple's merchant-education sheet is iOS 18+. Android has
        // no equivalent (Tap to Pay on Android education is Google's/Square's).
        result(TapToPayEducationPresenter.isAvailable)
      case "presentTapToPayEducation":
        // Apple's education sheet must come up over the app's own UI, so it
        // presents from the root view controller — the Flutter one — rather
        // than from a controller we create.
        TapToPayEducationPresenter.present(
          from: UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController,
          result: result
        )
      case "osVersion":
        // Drives the "update your iPhone" message Apple's requirement 1.4 asks
        // for: on iOS below the Tap to Pay floor the app must say the OS is the
        // problem, not the hardware. Square's SDK collapses both into a single
        // `isDeviceCapable() == false`, so the app asks the OS directly.
        result(UIDevice.current.systemVersion)
      case "addPassToWallet":
        // iOS-only: Android has no equivalent (Google Wallet passes are added
        // by opening a save URL in the browser, which the WebView already
        // routes externally). See WalletPassPresenter.swift.
        let arguments = call.arguments as? [String: Any]
        WalletPassPresenter.addPass(
          data: arguments?["bytes"] as? FlutterStandardTypedData,
          result: result
        )
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // AR lot mode's camera view (Ar/ArCameraPlatformView.swift): ARKit owns the camera for
    // visual-inertial pose tracking + feeds Vision for QR detection, replacing the
    // mobile_scanner/AVFoundation pipeline that screen used to use. Mirrors MainActivity.kt's
    // registration; getLensDistortion/isNfcEnabled etc. above stay Android-only, this is the one
    // platform-view registration both sides share.
    //
    // The pose/detection channels' stream handlers are attached here, at engine setup, rather
    // than when the platform view is created: Dart subscribes before it mounts the view, so
    // registering them any later loses the subscription outright (see Ar/ArEventBridge.swift).
    arEvents = ArEventBridge(messenger: registrar.messenger())
    registrar.register(
      ArCameraViewFactory(events: arEvents!),
      withId: "com.fishauctions.app/ar_camera"
    )
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

  // Whether this iPhone has speech recognition — asked *without* triggering an authorization
  // prompt, which rules out `speech_to_text`'s initialize() (it asks for the microphone and speech
  // recognition, then reports the permission as if it were the capability). The page calls
  // voiceGetState() on load, long before the user has expressed any interest in talking to it.
  //
  // Reading authorizationStatus() and supportedLocales() are both silent. `.restricted` is the one
  // status that really means never — a device-policy ban (Screen Time, MDM) the user cannot lift —
  // so it's the only one that reports "no". `.denied` deliberately still says yes: a phone whose
  // owner refused once and can re-enable it in Settings is a phone that can do this, and hiding
  // the button leaves them nothing to tap.
  //
  // supportedLocales() rather than SFSpeechRecognizer(locale: .current), because the recognition
  // locale comes from the app's served voice config (en_US by default), not from the phone's
  // region — a device set to a locale Apple doesn't recognize can still recognize English.
  private static func handleSpeechRecognitionAvailable(result: FlutterResult) {
    if SFSpeechRecognizer.authorizationStatus() == .restricted {
      result(false)
      return
    }
    result(!SFSpeechRecognizer.supportedLocales().isEmpty)
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
