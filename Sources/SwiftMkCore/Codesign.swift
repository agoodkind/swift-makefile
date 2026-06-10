//
//  Codesign.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//
//  The one codesign channel. Consumers never invoke codesign themselves: this
//  command resolves the identity the same way the build-time override does and
//  signs with the canonical flag set for the artifact kind, then verifies.
//

import Foundation

// MARK: - Codesign

public enum Codesign {
  /// The artifact kinds the canonical channel signs, each with its fixed flag
  /// set. `binary` is a bare executable or bundle (hardened runtime plus
  /// timestamp), `sparkle` re-signs vendored Sparkle internals in place without
  /// discarding their metadata, and `dmg` signs a disk image, which takes no
  /// hardened runtime.
  public enum Mode: String, Sendable {
    case binary
    case dmg
    case sparkle
  }

  /// The codesign argument list for one path, pure so tests cover every mode
  /// without spawning codesign.
  static func arguments(
    path: String,
    mode: Mode,
    identity: String,
    identifier: String?
  ) -> [String] {
    var arguments = ["--force", "--timestamp", "--sign", identity]
    switch mode {
    case .binary:
      arguments += ["--options", "runtime"]
      if let identifier, !identifier.isEmpty {
        arguments += ["--identifier", identifier]
      }
    case .sparkle:
      arguments += ["--options", "runtime"]
      arguments += ["--preserve-metadata=identifier,entitlements,flags"]
    case .dmg:
      break
    }
    arguments.append(path)
    return arguments
  }

  /// Resolve the signing identity through the same inputs as the build-time
  /// override: environment first, then the given local xcconfig files.
  static func resolveIdentity(localXcconfigPaths: [String]) -> String {
    let inputs = SigningBuildConfig.resolvedInputs(localXcconfigPaths: localXcconfigPaths)
    return inputs.identity.trimmingCharacters(in: .whitespaces)
  }

  /// Sign every path with the canonical flags for the mode and verify each
  /// signature strictly. Fails loud when no identity resolves or any codesign
  /// invocation exits nonzero.
  public static func run(
    paths: [String],
    mode: Mode,
    identifier: String?,
    localXcconfigPaths: [String] = ["Config/local.xcconfig"]
  ) -> Bool {
    let identity = resolveIdentity(localXcconfigPaths: localXcconfigPaths)
    guard !identity.isEmpty else {
      Output.error(
        "codesign-run: no signing identity resolves "
          + "(set CODE_SIGN_IDENTITY or SWIFT_MK_SIGN_IDENTITY, or fill Config/local.xcconfig)"
      )
      return false
    }
    guard !paths.isEmpty else {
      Output.error("codesign-run: no paths given")
      return false
    }
    for path in paths {
      guard FileManager.default.fileExists(atPath: path) else {
        Output.error("codesign-run: missing path \(path)")
        return false
      }
      let sign = Shell.run(
        "codesign", arguments(path: path, mode: mode, identity: identity, identifier: identifier))
      guard sign.status == 0 else {
        Output.error("codesign-run: signing failed for \(path)")
        Output.emitStandardError(sign.combined)
        return false
      }
      let verify = Shell.run("codesign", ["--verify", "--strict", "--verbose=2", path])
      guard verify.status == 0 else {
        Output.error("codesign-run: verification failed for \(path)")
        Output.emitStandardError(verify.combined)
        return false
      }
      Output.log("codesign-run: signed \(path) (\(mode.rawValue))")
    }
    return true
  }
}
