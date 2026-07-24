import Flutter
import UIKit

/// Creates `ArCameraPlatformView`s for the `com.fishauctions.app/ar_camera` platform view
/// (registered in AppDelegate). Only one AR screen is ever shown at a time, so there is exactly
/// one live view per process — nothing here needs to track multiple instances.
class ArCameraViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    let poseChannel = FlutterEventChannel(
      name: "com.fishauctions.app/ar_pose", binaryMessenger: messenger)
    let detectionChannel = FlutterEventChannel(
      name: "com.fishauctions.app/ar_detections", binaryMessenger: messenger)
    return ArCameraPlatformView(
      frame: frame, poseChannel: poseChannel, detectionChannel: detectionChannel, onDispose: {})
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}
