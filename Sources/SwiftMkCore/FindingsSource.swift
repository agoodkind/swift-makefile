//
//  FindingsSource.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - FindingsDecodeError

/// A tool produced output the findings layer could not decode. Empty output is
/// not an error (it means no findings); a non-empty body that does not decode is
/// unknown, not clean, so it surfaces as this error and the gate fails loud rather
/// than passing on zero findings.
public enum FindingsDecodeError: Error, CustomStringConvertible {
  case undecodable(tool: String, underlying: Error)

  public var description: String {
    switch self {
    case let .undecodable(tool, underlying):
      return "\(tool) output is not decodable JSON: \(underlying)"
    }
  }
}

// MARK: - FindingsSource

public enum FindingsSource {
  /// Decode swiftlint `--reporter json` stdout. Whitespace-only output is no
  /// findings; a non-empty body that does not decode throws.
  public static func decodeSwiftlintJSON(_ stdout: String) throws -> [Finding] {
    guard !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return []
    }
    do {
      return try Finding.fromSwiftlintJSON(Data(stdout.utf8))
    } catch {
      throw FindingsDecodeError.undecodable(tool: "swiftlint", underlying: error)
    }
  }

  /// Decode periphery `--format json` stdout, with the same empty-vs-undecodable
  /// rule as `decodeSwiftlintJSON`.
  public static func decodePeripheryJSON(_ stdout: String) throws -> [Finding] {
    guard !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return []
    }
    do {
      return try Finding.fromPeripheryJSON(Data(stdout.utf8))
    } catch {
      throw FindingsDecodeError.undecodable(tool: "periphery", underlying: error)
    }
  }

  public static func swiftlint(
    executable: String,
    arguments: [String],
    environment: [String: String] = [:]
  ) throws -> [Finding] {
    Output.debug("findings: running swiftlint --reporter json")
    let result = Shell.run(
      executable,
      arguments + ["--reporter", "json"],
      environment: environment)
    return try decodeSwiftlintJSON(result.stdout)
  }

  public static func periphery(
    executable: String,
    arguments: [String],
    environment: [String: String] = [:],
    timeoutSeconds: Double = 0
  ) throws -> [Finding] {
    Output.debug("findings: running periphery --format json")
    let result = Shell.runStreamingStderr(
      executable,
      arguments + ["--format", "json"],
      environment: environment,
      timeoutSeconds: timeoutSeconds)
    if result.timedOut {
      throw FindingsDecodeError.undecodable(
        tool: "periphery",
        underlying: PeripheryTimeout(seconds: timeoutSeconds))
    }
    return try decodePeripheryJSON(result.stdout)
  }
}

// MARK: - PeripheryTimeout

private struct PeripheryTimeout: Error, CustomStringConvertible {
  let seconds: Double
  var description: String { "timed out after \(seconds)s" }
}
