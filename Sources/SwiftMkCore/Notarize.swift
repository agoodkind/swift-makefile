//
//  Notarize.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//
//  The one notarization channel. Credentials come from the App Store Connect
//  key trio (CI) or a notarytool keychain profile (local). Stapling follows
//  the artifact's shape: a dmg or pkg staples directly, a zip carrying .app
//  bundles is expanded, stapled, and rebuilt, and a zip of bare binaries
//  ships notarized without a staple because Gatekeeper fetches its ticket
//  online on first launch.
//

import Foundation

// MARK: - Notarize

public enum Notarize {
  /// How notarytool authenticates. The key trio wins over a profile so CI,
  /// which sets both kinds of variables, never depends on runner keychains.
  public enum Credentials: Equatable, Sendable {  // gitleaks:allow
    case keychainProfile(name: String)
    case keyFile(path: String, keyId: String, issuerId: String)
  }

  /// The decoded fields of `notarytool submit --output-format json`.
  struct SubmitResult: Decodable {
    let id: String?
    let status: String?
  }

  static let acceptedStatus = "Accepted"

  /// Resolve credentials from an environment snapshot, pure for tests. The
  /// base64 key is written by the caller, so this layer only sees a path.
  static func credentials(
    keyPath: String?,
    keyId: String,
    issuerId: String,
    profile: String
  ) -> Credentials? {
    if let keyPath, !keyPath.isEmpty, !keyId.isEmpty, !issuerId.isEmpty {
      return .keyFile(path: keyPath, keyId: keyId, issuerId: issuerId)
    }
    if !profile.isEmpty {
      return .keychainProfile(name: profile)
    }
    return nil
  }

  /// The notarytool submit arguments for one artifact, pure for tests.
  static func submitArguments(
    artifact: String,
    credentials: Credentials  // gitleaks:allow
  ) -> [String] {
    var arguments = ["notarytool", "submit", artifact]
    switch credentials {
    case let .keyFile(path, keyId, issuerId):
      arguments += ["--key", path, "--key-id", keyId, "--issuer", issuerId]
    case .keychainProfile(let name):
      arguments += ["--keychain-profile", name]
    }
    arguments += ["--wait", "--output-format", "json"]
    return arguments
  }

  /// Decode the base64 App Store Connect key, tolerating whitespace the way
  /// the shell `base64 --decode` this replaced did: a secret set with line
  /// wrapping or a trailing newline decodes identically to a clean one.
  static func decodeKeyBase64(_ text: String) -> Data? {
    // An all-invalid string decodes to empty Data under .ignoreUnknownCharacters on
    // some Foundation versions and to nil on others; a real .p8 key is never empty,
    // so treat an empty decode as undecodable for a consistent result across runners.
    guard
      let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
      !data.isEmpty
    else {
      return nil
    }
    return data
  }

  /// Decode the env credentials, materializing APPLE_NOTARY_KEY_BASE64 into a
  /// temp key file when present. A set-but-undecodable key fails loud with its
  /// own message, never the misleading no-credentials one. Returns nil with a
  /// loud error when neither mode is configured.
  static func resolveCredentialsFromEnvironment() -> Credentials? {
    var keyPath: String?
    let keyBase64 = Env.get("APPLE_NOTARY_KEY_BASE64")
    if !keyBase64.isEmpty {
      guard let keyData = decodeKeyBase64(keyBase64) else {
        Output.error(
          "notarize: APPLE_NOTARY_KEY_BASE64 is set but does not decode as base64; "
            + "re-set it from the .p8 key file")
        return nil
      }
      let path =
        NSTemporaryDirectory()
        + "swift-mk-notary-key-\(ProcessInfo.processInfo.processIdentifier).p8"
      FileManager.default.createFile(
        atPath: path, contents: keyData, attributes: [.posixPermissions: 0o600])
      keyPath = path
    }
    let resolved = credentials(
      keyPath: keyPath,
      keyId: Env.get("APPLE_NOTARY_KEY_ID"),
      issuerId: Env.get("APPLE_NOTARY_ISSUER_ID"),
      profile: Env.get("NOTARY_PROFILE")
    )
    if resolved == nil {
      Output.error(
        "notarize: no credentials; set APPLE_NOTARY_KEY_BASE64 + APPLE_NOTARY_KEY_ID + "
          + "APPLE_NOTARY_ISSUER_ID, or NOTARY_PROFILE for a notarytool keychain profile")
    }
    return resolved
  }

  /// Submit one artifact and wait for the verdict; on anything but Accepted,
  /// print the submission output and the notary log so the cause is inline.
  static func submit(
    artifact: String,
    credentials: Credentials  // gitleaks:allow
  ) -> Bool {
    Output.log("notarize: submitting \(artifact)")
    let result = Shell.runForwardingAndCapturing(
      "xcrun",
      submitArguments(artifact: artifact, credentials: credentials))  // gitleaks:allow
    let decoded: SubmitResult?
    do {
      decoded = try JSONDecoder().decode(SubmitResult.self, from: Data(result.stdout.utf8))
    } catch {
      Output.error("notarize: submit output was not JSON: \(error)")
      decoded = nil
    }
    let status = decoded?.status ?? ""
    if result.status == 0, status == acceptedStatus {
      Output.log("notarize: \(artifact) Accepted")
      return true
    }
    Output.error(
      "notarize: \(artifact) was not accepted (status: \(status.isEmpty ? "unknown" : status))")
    if let submissionId = decoded?.id, !submissionId.isEmpty {
      var logArguments = ["notarytool", "log", submissionId]
      switch credentials {
      case let .keyFile(path, keyId, issuerId):
        logArguments += ["--key", path, "--key-id", keyId, "--issuer", issuerId]
      case .keychainProfile(let name):
        logArguments += ["--keychain-profile", name]
      }
      Shell.runForwardingAndCapturing("xcrun", logArguments)
    }
    return false
  }

  /// Whether a path staples directly, by extension. Zips never staple in
  /// place; bundles inside them might.
  static func staplesDirectly(_ artifact: String) -> Bool {
    !artifact.hasSuffix(".zip")
  }

  /// Staple an artifact by shape. A zip is expanded, every contained .app is
  /// stapled, and the zip is rebuilt; a zip with no .app ships as-is.
  static func staple(artifact: String) -> Bool {
    if staplesDirectly(artifact) {
      let result = Shell.runForwardingAndCapturing(
        "xcrun", ["stapler", "staple", artifact])
      guard result.status == 0 else {
        Output.error("notarize: stapler failed for \(artifact)")
        return false
      }
      return true
    }
    let expandDir = NSTemporaryDirectory() + "swift-mk-staple-\(UUID().uuidString)"
    defer {
      do {
        try FileManager.default.removeItem(atPath: expandDir)
      } catch {
        Output.error("notarize: could not remove temp dir \(expandDir): \(error)")
      }
    }
    guard
      Shell.runForwardingOutput("ditto", ["-x", "-k", artifact, expandDir]) == 0
    else {
      Output.error("notarize: could not expand \(artifact) for stapling")
      return false
    }
    let apps = appBundles(under: expandDir)
    guard !apps.isEmpty else {
      Output.log("notarize: \(artifact) carries no .app to staple; the ticket is online-only")
      return true
    }
    for app in apps {
      let result = Shell.runForwardingAndCapturing(
        "xcrun", ["stapler", "staple", app])
      guard result.status == 0 else {
        Output.error("notarize: stapler failed for \(app)")
        return false
      }
    }
    do {
      try FileManager.default.removeItem(atPath: artifact)
    } catch {
      Output.error("notarize: could not replace \(artifact): \(error)")
      return false
    }
    guard
      Shell.runForwardingOutput("ditto", ["-c", "-k", expandDir, artifact]) == 0
    else {
      Output.error("notarize: could not rebuild \(artifact) after stapling")
      return false
    }
    Output.log("notarize: stapled \(apps.count) app bundle(s) inside \(artifact)")
    return true
  }

  /// Directory entries, with an unreadable directory contributing nothing.
  private static func directoryEntries(of path: String, with fileManager: FileManager) -> [String] {
    do {
      return try fileManager.contentsOfDirectory(atPath: path)
    } catch {
      return []
    }
  }

  /// Top-two-level .app bundles inside an expanded zip, matching the layouts
  /// ditto produces with and without --keepParent.
  static func appBundles(under directory: String) -> [String] {
    let fileManager = FileManager.default
    var found: [String] = []
    let firstLevel = directoryEntries(of: directory, with: fileManager)
    for entry in firstLevel {
      let path = directory + "/" + entry
      if entry.hasSuffix(".app") {
        found.append(path)
        continue
      }
      let secondLevel = directoryEntries(of: path, with: fileManager)
      for inner in secondLevel where inner.hasSuffix(".app") {
        found.append(path + "/" + inner)
      }
    }
    return found.sorted()
  }

  /// Notarize and staple every artifact. Fails loud on the first failure.
  public static func run(paths: [String]) -> Bool {
    guard !paths.isEmpty else {
      Output.error("notarize: no artifacts given")
      return false
    }
    guard let credentials = resolveCredentialsFromEnvironment() else {  // gitleaks:allow
      return false
    }
    for path in paths {
      guard FileManager.default.fileExists(atPath: path) else {
        Output.error("notarize: missing artifact \(path)")
        return false
      }
      guard submit(artifact: path, credentials: credentials) else {  // gitleaks:allow
        return false
      }
      guard staple(artifact: path) else {
        return false
      }
    }
    return true
  }
}
