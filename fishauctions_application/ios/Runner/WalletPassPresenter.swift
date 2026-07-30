import Flutter
import PassKit
import UIKit

/// Presents Apple's own "Add to Apple Wallet" sheet for a `.pkpass` the app has
/// already downloaded (`DownloadService`), instead of handing the file to
/// `UIDocumentInteractionController`.
///
/// Why native: the backend serves club membership cards as signed `.pkpass`
/// files (`auctions/apple_wallet.py`, with a live PassKit web service pushing
/// updates), and tapping "Add to Apple Wallet" in the WebView should feel like
/// tapping it in Safari — one sheet, one "Add", done. Routing the file through
/// the generic document-preview path instead gives a file preview the user then
/// has to notice they can add from, which reads like a download went wrong.
///
/// The results are strings rather than an enum so the Dart side can treat an
/// unknown value as "fall back to opening the file" and never crash on a value
/// added later:
///
///   `presented`   the Wallet sheet is up; the user completes it there
///   `already`     this exact pass is already in the library — nothing to do
///   `unsupported` the device/OS can't add passes (e.g. Wallet unavailable)
///   `invalid`     the bytes aren't a pass Wallet will accept
///
/// The presenter retains itself until the sheet finishes: PassKit requires the
/// delegate to do the dismissing, and nothing else here would hold it alive.
final class WalletPassPresenter: NSObject, PKAddPassesViewControllerDelegate {
  private static var active: WalletPassPresenter?

  /// Adds the pass in [data] to Wallet, reporting one of the strings above.
  /// Never throws into Flutter — a failure is a result value, because the
  /// caller's fallback (open the file with the OS) is a perfectly good outcome.
  static func addPass(data: FlutterStandardTypedData?, result: @escaping FlutterResult) {
    guard PKAddPassesViewController.canAddPasses() else {
      result("unsupported")
      return
    }
    guard let bytes = data?.data, !bytes.isEmpty else {
      result("invalid")
      return
    }
    let pass: PKPass
    do {
      pass = try PKPass(data: bytes)
    } catch {
      result("invalid")
      return
    }
    // A membership card the user already holds: the sheet would offer nothing
    // ("Add" is disabled), so say so and let the caller show a message instead.
    if PKPassLibrary().containsPass(pass) {
      result("already")
      return
    }
    guard
      let controller = PKAddPassesViewController(pass: pass),
      let presenter = topViewController()
    else {
      result("invalid")
      return
    }
    let delegate = WalletPassPresenter()
    active = delegate
    controller.delegate = delegate
    presenter.present(controller, animated: true) {
      result("presented")
    }
  }

  func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
    controller.dismiss(animated: true) {
      Self.active = nil
    }
  }

  /// The view controller to present from: the foreground scene's root, walked
  /// past anything already presented (the app runs a single window scene, and
  /// the pass can be triggered from a WebView sitting under a bottom sheet).
  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
