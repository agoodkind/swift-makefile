//
//  ToolchainPrebuild.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - ToolchainPrebuild

enum ToolchainPrebuild {
  private static let commandEnvName = "SWIFT_XCODE_PREBUILD_CMD"
  private static let guardEnvName = "SWIFT_MK_IN_PREBUILD"

  /// Run the consumer-declared pre-xcodebuild command once before an xcodebuild
  /// spawn. An empty command is the common no-op path for consumers with no native
  /// library prep.
  @discardableResult
  static func run() -> Bool {
    let command = Env.get(commandEnvName).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else {
      return true
    }
    guard Env.get(guardEnvName) != "1" else {
      return true
    }

    let savedGuardValue = ProcessInfo.processInfo.environment[guardEnvName]
    setenv(guardEnvName, "1", 1)
    defer {
      if let savedGuardValue {
        setenv(guardEnvName, savedGuardValue, 1)
      } else {
        unsetenv(guardEnvName)
      }
    }

    let result = Shell.sh(command)
    Output.emitStandardOutput(result.combined)
    if result.status != 0 {
      Output.error("\(failureLabel) failed status=\(result.status)")
      return false
    }
    return true
  }

  private static let failureLabel = "prebuild: SWIFT_XCODE_PREBUILD_CMD"
}
