//
//  Preflight.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Preflight

public enum Preflight {
  public struct Requirement: Sendable, Equatable {
    public let path: String
    public let hint: String

    public init(path: String, hint: String) {
      self.path = path
      self.hint = hint
    }
  }

  public struct Result: Sendable, Equatable {
    public let ok: Bool
    public let message: String
  }

  public static func missing(
    _ requirements: [Requirement],
    exists: (String) -> Bool
  ) -> [Requirement] {
    var missingRequirements: [Requirement] = []
    for requirement in requirements where !exists(requirement.path) {
      missingRequirements.append(requirement)
    }
    return missingRequirements
  }

  public static func failureMessage(_ missingRequirements: [Requirement]) -> String {
    guard !missingRequirements.isEmpty else {
      return ""
    }

    var lines = ["preflight: missing required operator files:"]
    for requirement in missingRequirements {
      lines.append("  - \(requirement.path)  (\(requirement.hint))")
    }
    return lines.joined(separator: "\n")
  }

  public static func checkFiles(_ requirements: [Requirement]) -> Result {
    let missingRequirements = missing(requirements) { path in
      FileManager.default.fileExists(atPath: path)
    }
    guard !missingRequirements.isEmpty else {
      return Result(ok: true, message: "")
    }

    let message = failureMessage(missingRequirements)
    Output.error(message)
    return Result(ok: false, message: message)
  }

  /// Ensure the Metal shader compiler is present when the consumer opts in
  /// with SWIFT_MK_PREFLIGHT_METAL=1. Apple ships it as an on-demand
  /// component, so a fresh Xcode install lacks it; the engine downloads it
  /// once and re-checks, failing loud when it still cannot be found.
  public static func ensureMetal() -> Bool {
    guard Env.get("SWIFT_MK_PREFLIGHT_METAL") == "1" else {
      return true
    }
    if Shell.run("xcrun", ["--find", "metal"]).status == 0 {
      return true
    }
    Output.log("preflight: Metal toolchain missing; downloading")
    guard Toolchain.downloadMetalToolchain() == 0 else {
      Output.error("preflight: Metal toolchain download failed")
      return false
    }
    guard Shell.run("xcrun", ["--find", "metal"]).status == 0 else {
      Output.error(
        "preflight: Metal toolchain still missing after download; check the Xcode install")
      return false
    }
    return true
  }

  public static func trustMise(in directory: String) -> Bool {
    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    let fileManager = FileManager.default
    // The shared fetched config under .config/mise/conf.d/ counts alongside
    // the root pins: any present config needs trust before mise resolves tools.
    let sharedConfigPath =
      directoryURL
      .appendingPathComponent(Env.get("SWIFT_MK_MISE_CONFIG", ".config/mise/conf.d/swift-mk.toml"))
      .path
    let configPaths = [
      directoryURL.appendingPathComponent("mise.toml").path,
      directoryURL.appendingPathComponent(".tool-versions").path,
      sharedConfigPath,
    ]
    let presentConfigs = configPaths.filter { fileManager.fileExists(atPath: $0) }
    guard !presentConfigs.isEmpty else {
      return true
    }

    let miseLookup = Shell.run("/bin/sh", ["-c", "command -v mise >/dev/null 2>&1"])
    guard miseLookup.status == 0 else {
      return true
    }

    for configPath in presentConfigs {
      let result = Shell.run("mise", ["trust", configPath])
      guard result.status == 0 else {
        Output.error("preflight: mise config is untrusted; run: mise trust \(configPath)")
        return false
      }
    }
    return true
  }
}
