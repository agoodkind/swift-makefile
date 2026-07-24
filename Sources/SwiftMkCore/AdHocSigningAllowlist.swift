//
//  AdHocSigningAllowlist.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - AdHocSigningAllowlist

/// The single, hardcoded carve-out to the no-ad-hoc-signing rule.
///
/// Some build-time helpers are embedded into a product that re-signs them: the
/// desktop-via-clyde shim is a raw Mach-O compiled into a Go binary which the product
/// signs, so in a no-certificate dev or CI run the inner shim only needs a runnable
/// ad-hoc signature. This allowlist names the SwiftPM packages permitted that ad-hoc
/// fallback when swift-mk resolves no real identity.
///
/// There is deliberately no flag, environment variable, or consumer-facing knob: a
/// discoverable mechanism is one an agent pattern-matches to exempt itself. Instead the
/// allowlist is compiled into the swift-mk binary, and agent-gate blocks edits to this
/// file, so a consumer cannot grant itself the exception. Adding a package is a
/// deliberate human edit to this one file, glaring in review, never a copyable pattern.
public enum AdHocSigningAllowlist {
  /// SwiftPM package names permitted ad-hoc fallback when no real identity is set.
  static let packages: Set<String> = ["Shim"]

  /// The allowlisted package name for the SwiftPM manifest in `directory`, or nil
  /// when there is no manifest, its name is not parseable, or it is not allowlisted.
  /// Returns the name so the caller can name it in the audit line it prints.
  public static func allowedPackageName(inDirectory directory: String = ".") -> String? {
    guard let name = packageName(inDirectory: directory), packages.contains(name) else {
      return nil
    }
    return name
  }

  /// The `name:` of the SwiftPM `Package(...)` manifest in `directory`. The package
  /// name is the first `name:` in the manifest, before any target's `name:`, so the
  /// first match is taken. Returns nil when the manifest is absent or unparseable.
  static func packageName(inDirectory directory: String) -> String? {
    let manifest = (directory as NSString).appendingPathComponent("Package.swift")
    let contents: String
    do {
      contents = try String(contentsOfFile: manifest, encoding: .utf8)
    } catch {
      return nil
    }
    let quote = CharacterSet(charactersIn: "\"")
    for rawLine in contents.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("name:") else {
        continue
      }
      var value = String(line.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
      if value.hasSuffix(",") {
        value = String(value.dropLast())
      }
      value = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quote)
      if !value.isEmpty {
        return value
      }
    }
    return nil
  }
}

// Validation: exercise the collapsed Verify gate end to end.
