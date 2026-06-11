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

  /// The verdict of the consumer-injected preflight rail, pure for tests.
  public enum RailOutcome: Equatable, Sendable {
    case ensured
    case failed(message: String)
    case inert
    case passed
  }

  /// A check invocation's exit status and combined output.
  public struct CheckRun: Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
      self.status = status
      self.output = output
    }
  }

  /// Run the consumer-injected requirement rail. The engine owns only the
  /// pattern: run the check, on a miss run the ensure, re-check, fail loud.
  /// Both commands are opaque consumer strings, so no component policy ever
  /// lives here. An empty check with a set ensure runs the ensure every time,
  /// so that command must be idempotent.
  public static func ensureConsumerRequirement(
    check: String,
    ensure: String,
    runCheck: (String) -> CheckRun,
    runEnsure: (String) -> Int32
  ) -> RailOutcome {
    let checkCommand = check.trimmingCharacters(in: .whitespacesAndNewlines)
    let ensureCommand = ensure.trimmingCharacters(in: .whitespacesAndNewlines)
    if checkCommand.isEmpty, ensureCommand.isEmpty {
      return .inert
    }
    if checkCommand.isEmpty {
      guard runEnsure(ensureCommand) == 0 else {
        return .failed(message: "preflight: ensure command failed: \(ensureCommand)")
      }
      return .ensured
    }
    let firstCheck = runCheck(checkCommand)
    if firstCheck.status == 0 {
      return .passed
    }
    guard !ensureCommand.isEmpty else {
      return .failed(message: checkFailureMessage(command: checkCommand, run: firstCheck))
    }
    Output.log("preflight: check failed; running ensure: \(ensureCommand)")
    guard runEnsure(ensureCommand) == 0 else {
      return .failed(message: "preflight: ensure command failed: \(ensureCommand)")
    }
    let secondCheck = runCheck(checkCommand)
    guard secondCheck.status == 0 else {
      return .failed(message: checkFailureMessage(command: checkCommand, run: secondCheck))
    }
    return .ensured
  }

  /// The loud failure line for a failed check: the command and its verbatim
  /// output inline, never a log path.
  static func checkFailureMessage(command: String, run: CheckRun) -> String {
    let trimmedOutput = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedOutput.isEmpty else {
      return "preflight: check failed (exit \(run.status)): \(command)"
    }
    return "preflight: check failed (exit \(run.status)): \(command)\n\(trimmedOutput)"
  }

  /// Environment entry point: SWIFT_PREFLIGHT_CHECK_CMD asserts a consumer
  /// requirement and SWIFT_PREFLIGHT_ENSURE_CMD establishes it on a miss. The
  /// check runs captured so a pass stays silent; the ensure forwards output
  /// live so a long component download is visible as it happens.
  public static func ensureConsumerRequirement() -> Bool {
    let outcome = ensureConsumerRequirement(
      check: Env.get("SWIFT_PREFLIGHT_CHECK_CMD"),
      ensure: Env.get("SWIFT_PREFLIGHT_ENSURE_CMD"),
      runCheck: { command in
        let result = Shell.sh(command)
        return CheckRun(status: result.status, output: result.combined)
      },
      runEnsure: { command in
        Shell.runForwardingOutput("/bin/sh", ["-c", command])
      }
    )
    guard case .failed(let message) = outcome else {
      return true
    }
    Output.error(message)
    return false
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
