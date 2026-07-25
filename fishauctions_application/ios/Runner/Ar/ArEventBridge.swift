import Flutter

/// Owns the two AR event channels (`ar_pose`, `ar_detections`) for the whole engine's lifetime and
/// relays `ArCameraPlatformView`'s events into them. Mirrors `ar/ArEventBridge.kt`.
///
/// This deliberately does *not* live on the platform view, which is what it used to do and why AR
/// mode was dead:
///
///  1. Dart subscribes to both channels in `ArLotsScreen._initCamera()` and only *then* mounts
///     `ArCameraView`, so the `listen` message reached the platform before the view existed —
///     i.e. before anything had called `setStreamHandler`, leaving the channel name unregistered
///     with the messenger. Dart's `EventChannel` gets a `MissingPluginException` back, reports it
///     to `FlutterError`, and never retries: both streams stayed dead for the life of the screen.
///     No pose/status ⇒ `_arStatus` stuck at `checking` ⇒ the permanent spinner; no detections ⇒
///     nothing ever scanned. Registering at engine setup means a handler is always in place
///     before Dart can possibly listen.
///
///  2. Session status is a one-shot event sent from the view's initializer — ahead of Dart's
///     `onListen` in the other ordering. So `sendStatus` is sticky: the last status is replayed
///     to a newly-attached sink, and a view teardown clears it (`clearStatus`) so a stale `ready`
///     can't outlive its session.
///
/// Everything here runs on the main thread (the channels are registered there, and the AR session
/// delegate queue is `.main`), so the sinks need no further synchronization.
class ArEventBridge: NSObject {
  // Retained so the channels outlive `didInitializeImplicitFlutterEngine`.
  private let poseChannel: FlutterEventChannel
  private let detectionChannel: FlutterEventChannel

  private var poseSink: FlutterEventSink?
  private var detectionSink: FlutterEventSink?
  private var lastStatus: (status: String, message: String?)?

  init(messenger: FlutterBinaryMessenger) {
    poseChannel = FlutterEventChannel(
      name: "com.fishauctions.app/ar_pose", binaryMessenger: messenger)
    detectionChannel = FlutterEventChannel(
      name: "com.fishauctions.app/ar_detections", binaryMessenger: messenger)
    super.init()

    poseChannel.setStreamHandler(
      ArStreamHandler(
        onListen: { [weak self] sink in
          self?.poseSink = sink
          if let last = self?.lastStatus {
            sink(Self.statusPayload(status: last.status, message: last.message))
          }
        },
        onCancel: { [weak self] in self?.poseSink = nil }))
    detectionChannel.setStreamHandler(
      ArStreamHandler(
        onListen: { [weak self] sink in self?.detectionSink = sink },
        onCancel: { [weak self] in self?.detectionSink = nil }))
  }

  func sendStatus(status: String, message: String?) {
    DispatchQueue.main.async { [weak self] in
      self?.lastStatus = (status, message)
      self?.poseSink?(Self.statusPayload(status: status, message: message))
    }
  }

  func sendPose(tracking: Bool, px: Double, pz: Double, fx: Double, fz: Double) {
    poseSink?(["type": "pose", "tracking": tracking, "px": px, "pz": pz, "fx": fx, "fz": fz])
  }

  func sendDetections(imageWidth: Int, imageHeight: Int, barcodes: [[String: Any?]]) {
    detectionSink?([
      "imageWidth": imageWidth, "imageHeight": imageHeight, "barcodes": barcodes,
    ])
  }

  /// Forgets the sticky status — called when the AR view is disposed, so the next screen's
  /// subscriber doesn't get replayed a `ready` belonging to a session that no longer exists.
  func clearStatus() {
    DispatchQueue.main.async { [weak self] in self?.lastStatus = nil }
  }

  private static func statusPayload(status: String, message: String?) -> [String: Any] {
    ["type": "status", "status": status, "message": message as Any]
  }
}

/// Trivial `FlutterStreamHandler` that just forwards listen/cancel to closures — both AR event
/// channels use one of these rather than two near-identical handler classes.
private class ArStreamHandler: NSObject, FlutterStreamHandler {
  private let onListenCallback: (@escaping FlutterEventSink) -> Void
  private let onCancelCallback: () -> Void

  init(onListen: @escaping (@escaping FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
    self.onListenCallback = onListen
    self.onCancelCallback = onCancel
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    onListenCallback(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancelCallback()
    return nil
  }
}
