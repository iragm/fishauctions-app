import Flutter
import UIKit

/// Creates `ArCameraPlatformView`s for the `com.fishauctions.app/ar_camera` platform view
/// (registered in AppDelegate). Only one AR screen is ever shown at a time, so there is exactly
/// one live view per process — nothing here needs to track multiple instances.
class ArCameraViewFactory: NSObject, FlutterPlatformViewFactory {
  private let events: ArEventBridge

  init(events: ArEventBridge) {
    self.events = events
    super.init()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    ArCameraPlatformView(frame: frame, events: events, onDispose: {})
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}
