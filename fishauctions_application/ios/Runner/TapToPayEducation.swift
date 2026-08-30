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
/// **This needs the Tap to Pay entitlement, despite presenting education rather
/// than operating a card reader.** Apple's documentation for
/// `ProximityReaderDiscovery` never mentions an entitlement, and this file used
/// to say so — but measured on 2026-08-30, `content(for:)` fails with
/// `ContentError.unknown` in a TestFlight build and succeeds in the identical
/// build signed with a development profile carrying
/// `com.apple.developer.proximity-reader.payment.acceptance`. `unknown` is the
/// framework's catch-all and names none of the six real causes, so the failure
/// paths below stay verbose: they are the only way this is diagnosable from a
/// build with no debugger attached.
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

  /// How many education topics Apple has for this device, as a string for the
  /// error message.
  ///
  /// Worth the extra round trip on a failure because it separates two causes
  /// that `ContentError.unknown` cannot: Apple documents `contentList` as
  /// *"specific to the country of the current device. The array can be empty if
  /// no content is available for the current country."* A non-empty list means
  /// content exists here and something else refused it.
  @available(iOS 18.0, *)
  private static func inventory(_ discovery: ProximityReaderDiscovery) async -> String {
    do {
      let list = try await discovery.contentList
      return "contentList=\(list.count)"
    } catch {
      return "contentList threw \(describe(error))"
    }
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
      let discovery = ProximityReaderDiscovery()
      // Which of the two awaits threw. Set before each so the catch can name
      // it without repeating the block.
      var step = "content"
      do {
        // `.payment(.howToTap)` is the only payment topic Apple publishes today.
        // Fetching the content and presenting it are separate calls because the
        // fetch is what localizes/regionalizes it against the device.
        let content = try await discovery.content(for: .payment(.howToTap))
        step = "present"
        try await discovery.presentContent(content, from: viewController)
        result("presented")
      } catch {
        var message = describe(error)
        if step == "content" {
          message += " — \(await inventory(discovery))"
        }
        result(
          FlutterError(
            code: "education_failed_\(step)",
            message: message,
            details: nil))
      }
    }
  }
}
