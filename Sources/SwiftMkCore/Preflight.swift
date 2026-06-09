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

  public static func trustMise(in directory: String) -> Bool {
    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    let miseTomlPath = directoryURL.appendingPathComponent("mise.toml").path
    let toolVersionsPath = directoryURL.appendingPathComponent(".tool-versions").path
    let fileManager = FileManager.default
    guard
      fileManager.fileExists(atPath: miseTomlPath)
        || fileManager.fileExists(atPath: toolVersionsPath)
    else {
      return true
    }

    let miseLookup = Shell.run("/bin/sh", ["-c", "command -v mise >/dev/null 2>&1"])
    guard miseLookup.status == 0 else {
      return true
    }

    let result = Shell.run("mise", ["trust", directory])
    if result.status == 0 {
      return true
    }

    Output.error("preflight: mise config is untrusted; run: mise trust \(directory)")
    return false
  }
}
