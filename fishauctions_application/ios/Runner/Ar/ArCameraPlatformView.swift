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
  private let events: ArEventBridge
  private let onDispose: () -> Void

  private var detectionInFlight = false
  private var lastDetectionAttempt = Date.distantPast
  private let detectionInterval: TimeInterval = 0.1  // ~10 Hz — matches the Android side

  init(
    frame: CGRect,
    events: ArEventBridge,
    onDispose: @escaping () -> Void
  ) {
    sceneView = ARSCNView(frame: frame)
    self.events = events
    self.onDispose = onDispose
    super.init()

    sceneView.scene = SCNScene()
    sceneView.automaticallyUpdatesLighting = false
    sceneView.session = session
    session.delegate = self
    session.delegateQueue = DispatchQueue.main

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
    events.clearStatus()
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

    // The buffer is owned by `frame`, and ARKit recycles its pool. The Vision pass below runs on
    // another queue and outlives this function, so the frame has to be held for the duration or a
    // long pass can read a buffer ARKit has already handed to a newer frame — occasional garbled
    // detections with nothing in the log. `detectionInFlight` keeps it to one at a time, which is
    // why this has stayed rare rather than impossible.
    let pixelBuffer = frame.capturedImage
    let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
    let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
    let cgOrientation = Self.exifOrientation(for: interfaceOrientation)
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
      // Explicitly `-> Void`: with the single-expression form the closure returns `Void?` (from
      // `try?`), which makes `withExtendedLifetime`'s own result non-Void and unused, and Swift
      // warns about it.
      withExtendedLifetime(frame) { () -> Void in
        try? handler.perform([request])
      }
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

  /// How the UI is currently laid out, which is what the camera buffer has to be interpreted
  /// against — **not** `UIDevice.current.orientation`.
  ///
  /// The two are different questions and the device one is wrong here twice over. It reports the
  /// physical attitude of the handset, so it answers `.faceUp` / `.faceDown` the moment the phone
  /// is held flat — which on this screen is not an edge case but *the* use case: someone holding a
  /// phone over a table of lot labels. Those cases have no image orientation at all, so the old
  /// code fell back to portrait, silently, whatever the UI was actually doing. And it is
  /// unconstrained by the app's supported orientations, so it can report a rotation the interface
  /// never adopted.
  ///
  /// The consequence is not a wrong-way-up preview — ARKit renders the passthrough itself — it is
  /// that `reportedWidth`/`reportedHeight` swap and every QR corner is normalized in a transposed
  /// frame. Bearings computed from those corners are then wrong, so the overlay chips sit on the
  /// wrong labels and the locate beacon points into the room. Android reads the interface rotation
  /// for exactly this reason (`ar/ArCameraPlatformView.kt`, `activity.display?.rotation`).
  ///
  /// Read on the main thread only, which is where `maybeDetect` runs (`session.delegateQueue`).
  private var interfaceOrientation: UIInterfaceOrientation {
    if let scene = sceneView.window?.windowScene {
      return scene.interfaceOrientation
    }
    // Not in a window yet. The app's own foreground scene is the next best answer; portrait is the
    // last resort, and matches how this screen is almost always held.
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    return scene?.interfaceOrientation ?? .portrait
  }

  /// Interface orientation → the EXIF orientation Vision needs for ARKit's captured buffer, which
  /// is always in the sensor's native landscape frame.
  ///
  /// Note the deliberate cross: `UIInterfaceOrientation.landscapeRight` is the *device* rotated
  /// left and vice versa (Apple documents the inversion). The four mappings below are therefore
  /// the same four the device-orientation version had — only the question being asked has changed.
  private static func exifOrientation(for orientation: UIInterfaceOrientation)
    -> CGImagePropertyOrientation
  {
    switch orientation {
    case .portraitUpsideDown: return .left
    case .landscapeRight: return .up
    case .landscapeLeft: return .down
    case .portrait: return .right
    default: return .right  // .unknown — portrait is this app's common case
    }
  }

  // MARK: - Event sinks (owned by ArEventBridge; see the note there on why)

  private func sendStatus(status: String, message: String?) {
    events.sendStatus(status: status, message: message)
  }

  private func sendPose(tracking: Bool, px: Double, pz: Double, fx: Double, fz: Double) {
    events.sendPose(tracking: tracking, px: px, pz: pz, fx: fx, fz: fz)
  }

  private func sendDetections(imageWidth: Int, imageHeight: Int, barcodes: [[String: Any?]]) {
    events.sendDetections(imageWidth: imageWidth, imageHeight: imageHeight, barcodes: barcodes)
  }
}
