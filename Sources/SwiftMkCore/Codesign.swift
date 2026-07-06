//
//  Codesign.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright (c) 2026, all rights reserved.
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
    identifier: String?,
    keychain: String? = nil
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
    let trimmedKeychain = keychain?.trimmingCharacters(in: .whitespaces) ?? ""
    if !trimmedKeychain.isEmpty {
      arguments += ["--keychain", trimmedKeychain]
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

  /// Resolve the optional keychain path from an explicit CLI value first, then the
  /// same signing inputs used for build-time signing.
  static func resolveKeychain(explicit: String?, localXcconfigPaths: [String]) -> String {
    let explicitKeychain = explicit?.trimmingCharacters(in: .whitespaces) ?? ""
    if !explicitKeychain.isEmpty {
      return explicitKeychain
    }
    let inputs = SigningBuildConfig.resolvedInputs(localXcconfigPaths: localXcconfigPaths)
    return inputs.keychain.trimmingCharacters(in: .whitespaces)
  }

  /// The codesign identifier for one artifact. An explicit identifier wins for
  /// every path; otherwise a prefix derives `<prefix>.<basename without
  /// extension>`, the per-product bundle-id form a multi-artifact CLI signs each
  /// of its binaries and resource bundles with; otherwise nil (codesign keeps the
  /// path's own identifier). Pure so tests cover the derivation without codesign.
  static func identifier(forPath path: String, explicit: String?, prefix: String?) -> String? {
    if let explicit, !explicit.isEmpty {
      return explicit
    }
    guard let prefix, !prefix.isEmpty else {
      return nil
    }
    let base = (path as NSString).lastPathComponent
    let stem = (base as NSString).deletingPathExtension
    return "\(prefix).\(stem)"
  }

  /// Top-level `*.bundle` resource bundles in a directory, sorted for a stable
  /// signing order. Matches the runtime discovery a multi-artifact CLI does for
  /// the resource bundles its build drops alongside the binaries; an empty or
  /// missing directory yields none, so an unbuilt or bundle-less product signs
  /// cleanly. Pure file listing, no codesign.
  static func discoverBundles(in directory: String) -> [String] {
    let contents: [String]
    do {
      contents = try FileManager.default.contentsOfDirectory(atPath: directory)
    } catch {
      // A missing or unreadable directory means no resource bundles to sign.
      return []
    }
    let bundles = contents.filter { ($0 as NSString).pathExtension == "bundle" }
    return bundles.sorted().map { (directory as NSString).appendingPathComponent($0) }
  }

  /// Sign every path with the canonical flags for the mode and verify each
  /// signature strictly. Fails loud when no identity resolves or any codesign
  /// invocation exits nonzero.
  public static func run(
    paths: [String],
    mode: Mode,
    identifier: String?,
    identifierPrefix: String? = nil,
    bundlesDirectory: String? = nil,
    keychain: String? = nil,
    localXcconfigPaths: [String] = ["Config/local.xcconfig"]
  ) -> Bool {
    let identity = resolveIdentity(localXcconfigPaths: localXcconfigPaths)
    let resolvedKeychain = resolveKeychain(
      explicit: keychain,
      localXcconfigPaths: localXcconfigPaths)
    guard !identity.isEmpty else {
      Output.error(
        "codesign-run: no signing identity resolves "
          + "(set CODE_SIGN_IDENTITY or SWIFT_MK_SIGN_IDENTITY, or fill Config/local.xcconfig)"
      )
      return false
    }
    var allPaths = paths
    if let bundlesDirectory, !bundlesDirectory.isEmpty {
      allPaths += discoverBundles(in: bundlesDirectory)
    }
    guard !allPaths.isEmpty else {
      Output.error("codesign-run: no paths given")
      return false
    }
    for path in allPaths {
      guard FileManager.default.fileExists(atPath: path) else {
        Output.error("codesign-run: missing path \(path)")
        return false
      }
      let pathIdentifier = Self.identifier(
        forPath: path, explicit: identifier, prefix: identifierPrefix)
      let sign = Shell.run(
        "codesign",
        arguments(
          path: path,
          mode: mode,
          identity: identity,
          identifier: pathIdentifier,
          keychain: resolvedKeychain))
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
