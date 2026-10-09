import Foundation
import MetricKit
import UIKit

/// Native crashes and hangs, as iOS itself reports them, held until Dart sends them to the backend.
///
/// A Dart error is caught in Dart (`CrashReporter`), but a crash in Swift, a plugin or the engine
/// kills the process before anything of ours can run. MetricKit is the OS's own account of it:
/// iOS hands the app an `MXDiagnosticPayload` on a later launch with the crashing thread's stack.
/// Each one is written to a file here, and `takePendingCrashes` gives them to Dart and deletes them.
///
/// The stack comes unsymbolicated (`binary +offset`): the binary names say whose code it was, and
/// the offsets resolve against that release's dSYM.
final class CrashCapture: NSObject, MXMetricManagerSubscriber {
  static let shared = CrashCapture()

  /// More than this many waiting is a crash loop; the newest say the same as the rest.
  private static let maxPending = 10
  private static let maxFrames = 40

  private let queue = DispatchQueue(label: "com.fishauctions.app.crashcapture")

  func start() {
    MXMetricManager.shared.add(self)
  }

  // MARK: MXMetricManagerSubscriber

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      let when = ISO8601DateFormatter().string(from: payload.timeStampEnd)
      for crash in payload.crashDiagnostics ?? [] {
        save(
          kind: "native", message: Self.describe(crash),
          stack: Self.frames(crash.callStackTree), version: crash.metaData.applicationBuildVersion,
          when: when)
      }
      for hang in payload.hangDiagnostics ?? [] {
        save(
          kind: "anr", message: "Hang: main thread blocked for \(hang.hangDuration)",
          stack: Self.frames(hang.callStackTree), version: hang.metaData.applicationBuildVersion,
          when: when)
      }
    }
  }

  // MARK: Channel

  /// `{device, os_version, crashes: [...]}`; the crashes are deleted once read.
  func take() -> [String: Any] {
    var crashes: [[String: Any]] = []
    queue.sync {
      guard let directory = Self.directory(),
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
      else { return }
      for name in names.sorted() {
        let file = directory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file),
          let crash = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          crashes.append(crash)
        }
        try? FileManager.default.removeItem(at: file)
      }
    }
    return [
      "device": Self.model(),
      "os_version": "iOS \(UIDevice.current.systemVersion)",
      "crashes": crashes,
    ]
  }

  // MARK: Private

  private func save(kind: String, message: String, stack: String, version: String, when: String) {
    let crash: [String: Any] = [
      "kind": kind,
      "platform": "ios",
      "fatal": kind == "native",
      "message": message,
      "stack": stack,
      // "1.0.0+12" like Dart's: MetricKit names the build that crashed, which may be older than
      // this one, but not its version name, so that is this build's.
      "app_version": "\(Self.versionName())+\(version)",
      "occurred_at": when,
    ]
    queue.async {
      guard let directory = Self.directory(),
        let data = try? JSONSerialization.data(withJSONObject: crash)
      else { return }
      let waiting = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      if waiting.count >= Self.maxPending { return }
      let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
      try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
  }

  private static func directory() -> URL? {
    guard
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    let directory = support.appendingPathComponent("pending_crashes", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// "NSInvalidArgumentException: EXC_CRASH SIGABRT …": the most specific name first, because the
  /// backend groups crashes by what comes before the first colon.
  private static func describe(_ crash: MXCrashDiagnostic) -> String {
    var name = exceptionName(crash.exceptionType?.intValue)
    var detail = ""
    if #available(iOS 17.0, *), let reason = crash.exceptionReason {
      name = reason.className
      detail = reason.composedMessage
    }
    let parts = [
      exceptionName(crash.exceptionType?.intValue),
      signalName(crash.signal?.intValue),
      detail,
      crash.terminationReason ?? "",
    ].filter { !$0.isEmpty }
    return "\(name): " + parts.joined(separator: " ")
  }

  private static func exceptionName(_ type: Int?) -> String {
    guard let type else { return "Crash" }
    switch type {
    case 1: return "EXC_BAD_ACCESS"
    case 2: return "EXC_BAD_INSTRUCTION"
    case 3: return "EXC_ARITHMETIC"
    case 5: return "EXC_SOFTWARE"
    case 6: return "EXC_BREAKPOINT"
    case 10: return "EXC_CRASH"
    case 11: return "EXC_RESOURCE"
    case 12: return "EXC_GUARD"
    default: return "EXC_\(type)"
    }
  }

  private static func signalName(_ signal: Int?) -> String {
    guard let signal else { return "" }
    switch signal {
    case 4: return "SIGILL"
    case 5: return "SIGTRAP"
    case 6: return "SIGABRT"
    case 8: return "SIGFPE"
    case 9: return "SIGKILL"
    case 10: return "SIGBUS"
    case 11: return "SIGSEGV"
    default: return "signal \(signal)"
    }
  }

  /// The attributed thread's frames, innermost first, one "#n binary +0xoffset" per line.
  private static func frames(_ tree: MXCallStackTree) -> String {
    guard
      let json = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
      let stacks = json["callStacks"] as? [[String: Any]]
    else { return "" }
    let stack =
      stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first ?? [:]
    var lines: [String] = []
    var frame = (stack["callStackRootFrames"] as? [[String: Any]])?.first
    while let current = frame, lines.count < maxFrames {
      let binary = current["binaryName"] as? String ?? "?"
      let offset = (current["offsetIntoBinaryTextSegment"] as? NSNumber)?.intValue ?? 0
      lines.append("#\(lines.count) \(binary) +0x\(String(offset, radix: 16))")
      frame = (current["subFrames"] as? [[String: Any]])?.first
    }
    return lines.joined(separator: "\n")
  }

  private static func versionName() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
  }

  /// "iPhone15,2": the hardware model, which UIDevice only gives as "iPhone".
  private static func model() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
  }
}
