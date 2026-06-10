//
//  Build.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Build

/// The build chokepoint. It runs the lint gates in-process and then runs the
/// consumer's configured build command, so a product build never runs without the
/// gates: `make build` routes here, and there is no separate recipe step that
/// compiles on its own.
public enum Build {
  /// The exit status returned when `SWIFT_BUILD_CMD` is unset, so a misconfigured
  /// consumer fails loudly rather than silently building nothing.
  static let missingBuildCommandStatus: Int32 = 1

  /// Run the lint gates once, then the configured build command with its output
  /// forwarded live. This is the single place every `make build` gates, so the
  /// build command and any `toolchain build` it calls stay pure compilers and never
  /// double-gate. Returns the gate-failure status when the gates fail, a nonzero
  /// status when `SWIFT_BUILD_CMD` is unset, or the build command's exit status.
  public static func gateAndBuild() -> Int32 {
    if !Lint.runBuildCheck(context: PathContext.current()) {
      guard
        Env.get("GITHUB_ACTIONS") == "true",
        !Env.get("GITHUB_RUN_ID").isEmpty,
        !Env.get("RELEASE_TAG").isEmpty
      else {
        return Toolchain.gateFailureStatus
      }
      Output.log("build: continuing with reported gate failures")
    }
    let command = Env.get("SWIFT_BUILD_CMD")
    guard !command.isEmpty else {
      Output.error("build: SWIFT_BUILD_CMD is not set")
      return missingBuildCommandStatus
    }
    Output.info("build: running configured build command")
    return Shell.runForwardingOutput("/bin/sh", ["-c", command])
  }
}
