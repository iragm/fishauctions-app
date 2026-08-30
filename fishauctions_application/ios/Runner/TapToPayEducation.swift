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
/// No entitlement is *documented* for this — `ProximityReaderDiscovery` only
/// presents educational material, unlike `PaymentCardReader`, which is what the
/// `com.apple.developer.proximity-reader.payment.acceptance` entitlement gates
/// (and which we never touch directly; Square's SDK owns the actual card read).
/// That claim is load-bearing — it is what makes the entitlement-review videos
/// recordable before the grant — and as of 2026-08-30 it is unverified on
/// hardware, which is why the failure paths below name themselves precisely.
enum TapToPayEducationPresenter {
  /// Whether Apple's education sheet can be shown on this OS. False below
  /// iOS 18, where the caller falls back to its own (text-only) explanation.
  static var isAvailable: Bool {
    if #available(iOS 18.0, *) {
      return true
    }
    return false
  }

  /// The controller Apple's sheet should be presented from.
  ///
  /// Deliberately not `connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first`,
  /// which is what this used to be and is wrong three ways. `connectedScenes`
  /// is a **`Set`**, so `.first` picks an arbitrary scene rather than the one
  /// the user is looking at; a scene that is backgrounded or unattached has no
  /// key window at all, so an app with more than one scene can resolve to nil
  /// while plainly on screen; and presenting from a controller that is already
  /// presenting something throws rather than stacking, so the walk up
  /// `presentedViewController` matters even though Flutter's own routes are
  /// widgets rather than UIKit modals — a plugin's sheet is not.
  @MainActor
  private static func presentingViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene =
      scenes.first { $0.activationState == .foregroundActive }
      ?? scenes.first { $0.activationState == .foregroundInactive }
      ?? scenes.first
    guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    else {
      return nil
    }
    var controller = window.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }

  /// Everything an unknown framework error can tell us, in one string.
  ///
  /// `localizedDescription` alone is close to useless for a Swift error that
  /// isn't `LocalizedError` — it flattens to "The operation couldn't be
  /// completed" — while `String(describing:)` gives the actual enum case and
  /// the bridged `NSError` gives the domain and code. On a build with no
  /// debugger attached this string is the entire diagnosis, so it carries all
  /// three.
  private static func describe(_ error: Error) -> String {
    let bridged = error as NSError
    return "\(String(describing: error)) [\(bridged.domain) \(bridged.code)]: \(bridged.localizedDescription)"
  }

  /// Presents the "how to tap" topic and resolves once the sheet is dismissed.
  ///
  /// Resolves `"presented"` on a completed showing, `"unsupported"` on iOS 17
  /// and earlier — a value rather than an error, since the Dart side treats it
  /// as a normal fallback path, not a failure. Every other outcome is a
  /// `FlutterError` whose **code names the step that failed**, because the two
  /// awaits below fail for entirely different reasons: `content` is a fetch of
  /// region-localized material from Apple (network, region, availability),
  /// while `presentContent` is UIKit presentation. Collapsing both into one
  /// "education_failed" is what made this undiagnosable from a TestFlight
  /// build.
  static func present(result: @escaping FlutterResult) {
    guard #available(iOS 18.0, *) else {
      result("unsupported")
      return
    }
    Task { @MainActor in
      guard let viewController = presentingViewController() else {
        result(
          FlutterError(
            code: "no_view_controller",
            message: "No foreground window scene to present the education sheet from",
            details: nil))
        return
      }
      // Which of the two awaits threw. Set before each so the catch can name
      // it without repeating the block.
      var step = "content"
      do {
        let discovery = ProximityReaderDiscovery()
        // `.payment(.howToTap)` is the only payment topic Apple publishes today.
        // Fetching the content and presenting it are separate calls because the
        // fetch is what localizes/regionalizes it against the device.
        let content = try await discovery.content(for: .payment(.howToTap))
        step = "present"
        try await discovery.presentContent(content, from: viewController)
        result("presented")
      } catch {
        result(
          FlutterError(
            code: "education_failed_\(step)",
            message: describe(error),
            details: nil))
      }
    }
  }
}
