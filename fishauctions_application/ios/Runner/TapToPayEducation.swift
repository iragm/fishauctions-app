import Flutter
import ProximityReader
import UIKit

/// Apple's own Tap to Pay on iPhone merchant-education sheet
/// (`ProximityReaderDiscovery`, iOS 18+), presented over whatever the app is
/// showing.
///
/// This exists because Apple's app-review guide *requires* it: requirement 4.1
/// of the Tap to Pay on iPhone App & Marketing Requirements guide says to use
/// `ProximityReaderDiscovery` on iOS 18 and later, and doing so is what
/// satisfies requirements 4.4, 4.6, 4.7 and 4.8 — "how to accept Apple Pay and
/// other digital wallets", the PIN-entry explanation every region except JP/TW
/// must show, and the fallback-payment copy. Apple keeps that content current
/// and localized for the merchant's region, which is precisely why we must not
/// hand-write our own version: the same guide forbids creating custom
/// illustrations or copy depicting iPhone or Tap to Pay on iPhone.
///
/// No entitlement is involved. `ProximityReaderDiscovery` only presents
/// educational material — unlike `PaymentCardReader`, which is what the
/// `com.apple.developer.proximity-reader.payment.acceptance` entitlement gates
/// (and which we never touch directly; Square's SDK owns the actual card read).
/// So this works in development builds, before the publishing entitlement is
/// granted, which is what makes it recordable for the entitlement review video.
enum TapToPayEducationPresenter {
  /// Whether Apple's education sheet can be shown on this OS. False below
  /// iOS 18, where the caller falls back to its own (text-only) explanation.
  static var isAvailable: Bool {
    if #available(iOS 18.0, *) {
      return true
    }
    return false
  }

  /// Presents the "how to tap" topic and resolves once the sheet is dismissed.
  ///
  /// Resolves `"presented"` on a completed showing, `"unsupported"` on iOS 17
  /// and earlier — a value rather than an error, since the Dart side treats it
  /// as a normal fallback path, not a failure.
  static func present(from viewController: UIViewController?, result: @escaping FlutterResult) {
    guard #available(iOS 18.0, *) else {
      result("unsupported")
      return
    }
    guard let viewController else {
      result(
        FlutterError(
          code: "no_view_controller",
          message: "No view controller to present the education sheet from",
          details: nil))
      return
    }
    Task { @MainActor in
      do {
        let discovery = ProximityReaderDiscovery()
        // `.payment(.howToTap)` is the only payment topic Apple publishes today.
        // Fetching the content and presenting it are separate calls because the
        // fetch is what localizes/regionalizes it against the device.
        let content = try await discovery.content(for: .payment(.howToTap))
        try await discovery.presentContent(content, from: viewController)
        result("presented")
      } catch {
        result(
          FlutterError(
            code: "education_failed",
            message: error.localizedDescription,
            details: nil))
      }
    }
  }
}
