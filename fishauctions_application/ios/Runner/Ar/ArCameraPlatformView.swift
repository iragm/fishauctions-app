import ARKit
import Flutter
import SceneKit
import UIKit
import Vision

/// The Flutter-embedded AR camera view: an `ARSCNView` rendering ARKit's camera passthrough
/// (SceneKit handles that internally — no custom Metal/GL rendering needed here, unlike Android's
/// ARCore path), driven by one `ARSession`. Composed into the Flutter widget tree as a normal
/// UIView (`UiKitView`).
///
/// ARKit must own the camera to do visual-inertial tracking (that's what VIO *is* — camera + IMU
/// fused), so this replaces the mobile_scanner/AVFoundation pipeline entirely for AR mode rather
/// than running alongside it — the same reasoning as the Android side (see
/// `ar/ArSessionManager.kt`). QR detection moves to the Vision framework fed by ARKit's frames —
/// comparable detection quality to what mobile_scanner's own ML Kit-backed scanner gave.
class ArCameraPlatformView: NSObject, FlutterPlatformView, ARSessionDelegate {
  private let sceneView: ARSCNView
  private let session = ARSession()
  private let onDispose: () -> Void

  private var poseSink: FlutterEventSink?
  private var detectionSink: FlutterEventSink?

  private var detectionInFlight = false
  private var lastDetectionAttempt = Date.distantPast
  private let detectionInterval: TimeInterval = 0.1  // ~10 Hz — matches the Android side

  init(
    frame: CGRect,
    poseChannel: FlutterEventChannel,
    detectionChannel: FlutterEventChannel,
    onDispose: @escaping () -> Void
  ) {
    sceneView = ARSCNView(frame: frame)
    self.onDispose = onDispose
    super.init()

    poseChannel.setStreamHandler(
      ArStreamHandler(onListen: { [weak self] sink in self?.poseSink = sink },
                       onCancel: { [weak self] in self?.poseSink = nil }))
    detectionChannel.setStreamHandler(
      ArStreamHandler(onListen: { [weak self] sink in self?.detectionSink = sink },
                       onCancel: { [weak self] in self?.detectionSink = nil }))

    sceneView.scene = SCNScene()
    sceneView.automaticallyUpdatesLighting = false
    sceneView.session = session
    session.delegate = self
    session.delegateQueue = DispatchQueue.main

    UIDevice.current.beginGeneratingDeviceOrientationNotifications()

    if ARWorldTrackingConfiguration.isSupported {
      let config = ARWorldTrackingConfiguration()
      config.planeDetection = []
      config.environmentTexturing = .none
      config.isLightEstimationEnabled = false
      session.run(config)
      sendStatus(status: "ready", message: nil)
    } else {
      sendStatus(
        status: "unsupported",
        message: "This device doesn't support ARKit, which AR lot mode needs for camera tracking."
      )
    }
  }

  func view() -> UIView { sceneView }

  func dispose() {
    session.pause()
    UIDevice.current.endGeneratingDeviceOrientationNotifications()
    onDispose()
  }

  // MARK: - ARSessionDelegate (called on `session.delegateQueue`, set to .main above)

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let tracking = frame.camera.trackingState == .normal
    // Columns 0-2 are the pose's local axes expressed in world space (column-major 4x4); ARKit's
    // camera looks down its own -Z (same OpenGL-style convention ARCore uses), and the world is
    // right-handed, Y-up (gravity-aligned, the default `worldAlignment`). The Dart side derives
    // yaw + the BACKEND_SPEC.md Part 5 odometry frame from these via a shared, unit-tested
    // transform (ar_geometry.dart) — deliberately no trig happens natively here.
    let t = frame.camera.transform
    sendPose(
      tracking: tracking,
      px: Double(t.columns.3.x), pz: Double(t.columns.3.z),
      fx: Double(-t.columns.2.x), fz: Double(-t.columns.2.z))

    maybeDetect(frame: frame)
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    sendStatus(status: "error", message: error.localizedDescription)
  }

  // MARK: - QR detection

  private func maybeDetect(frame: ARFrame) {
    guard !detectionInFlight else { return }
    let now = Date()
    guard now.timeIntervalSince(lastDetectionAttempt) >= detectionInterval else { return }
    lastDetectionAttempt = now
    detectionInFlight = true

    let pixelBuffer = frame.capturedImage
    let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
    let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
    let cgOrientation = Self.exifOrientation(for: UIDevice.current.orientation)
    // ARKit's captured buffer is always in the sensor's native (landscape) orientation; Vision
    // rotates its conceptual frame per `cgOrientation`, so a portrait hint (.left/.right) means
    // the corner points it reports are relative to a width/height-swapped image.
    let swapped = cgOrientation == .left || cgOrientation == .right
    let reportedWidth = swapped ? bufferHeight : bufferWidth
    let reportedHeight = swapped ? bufferWidth : bufferHeight

    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    let handler = VNImageRequestHandler(
      cvPixelBuffer: pixelBuffer, orientation: cgOrientation, options: [:])

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      defer {
        DispatchQueue.main.async { self?.detectionInFlight = false }
      }
      guard let self = self else { return }
      try? handler.perform([request])
      let observations = (request.results as? [VNBarcodeObservation]) ?? []
      let barcodes: [[String: Any?]] = observations.compactMap { obs in
        guard obs.symbology == .qr else { return nil }
        // Vision's corner points are normalized (0...1), origin bottom-left, already in the
        // upright (orientation-corrected) frame — flip Y and scale to match the top-left-origin
        // pixel convention mobile_scanner/ML Kit already used on this screen.
        let corners = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map {
          [Double($0.x) * Double(reportedWidth), (1.0 - Double($0.y)) * Double(reportedHeight)]
        }
        return ["rawValue": obs.payloadStringValue, "corners": corners]
      }
      DispatchQueue.main.async {
        self.sendDetections(
          imageWidth: reportedWidth, imageHeight: reportedHeight, barcodes: barcodes)
      }
    }
  }

  private static func exifOrientation(for deviceOrientation: UIDeviceOrientation)
    -> CGImagePropertyOrientation
  {
    switch deviceOrientation {
    case .portraitUpsideDown: return .left
    case .landscapeLeft: return .up
    case .landscapeRight: return .down
    case .portrait: return .right
    default: return .right  // .faceUp/.faceDown/.unknown — portrait is this app's common case
    }
  }

  // MARK: - Event sinks (must run on main — callers already are, but stay defensive)

  private func sendStatus(status: String, message: String?) {
    DispatchQueue.main.async { [weak self] in
      self?.poseSink?(["type": "status", "status": status, "message": message as Any])
    }
  }

  private func sendPose(tracking: Bool, px: Double, pz: Double, fx: Double, fz: Double) {
    poseSink?(["type": "pose", "tracking": tracking, "px": px, "pz": pz, "fx": fx, "fz": fz])
  }

  private func sendDetections(imageWidth: Int, imageHeight: Int, barcodes: [[String: Any?]]) {
    detectionSink?([
      "imageWidth": imageWidth, "imageHeight": imageHeight, "barcodes": barcodes,
    ])
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
