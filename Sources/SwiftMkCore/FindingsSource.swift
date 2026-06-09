//
//  FindingsSource.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - FindingsSource

public enum FindingsSource {
  public static func swiftlint(
    executable: String,
    arguments: [String],
    environment: [String: String] = [:]
  ) -> [Finding] {
    let result = Shell.run(
      executable,
      arguments + ["--reporter", "json"],
      environment: environment)

    do {
      return try Finding.fromSwiftlintJSON(Data(result.stdout.utf8))
    } catch {
      Output.error("findings: swiftlint json decode failed: \(error)")
      return []
    }
  }

  public static func periphery(
    executable: String,
    arguments: [String],
    environment: [String: String] = [:],
    timeoutSeconds: Double = 0
  ) -> [Finding] {
    let result = Shell.runStreamingStderr(
      executable,
      arguments + ["--format", "json"],
      environment: environment,
      timeoutSeconds: timeoutSeconds)
    if result.timedOut {
      Output.error("findings: periphery timed out after \(timeoutSeconds)s")
      return []
    }

    do {
      return try Finding.fromPeripheryJSON(Data(result.stdout.utf8))
    } catch {
      Output.error("findings: periphery json decode failed: \(error)")
      return []
    }
  }
}
