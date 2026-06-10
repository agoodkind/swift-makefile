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
      // The release pipeline ships even when lint gates are red: the CI lint
      // jobs surface those failures on their own, and blocking a signed
      // release on lint debt only strands users on broken versions. Every
      // other build path stays hard-gated; only swift-release.mk sets this.
      guard Env.get("SWIFT_MK_RELEASE_NONBLOCKING_GATES") == "1" else {
        return Toolchain.gateFailureStatus
      }
      Output.log(
        "build: lint gates FAILED; continuing because the release pipeline set "
          + "SWIFT_MK_RELEASE_NONBLOCKING_GATES=1. The lint gates still report "
          + "these failures everywhere else.")
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
