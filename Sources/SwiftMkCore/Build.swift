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
  /// Whether `swift-mk build` runs the gates itself before compiling. It gates for
  /// a SwiftPM consumer (no `SWIFT_XCODE_SCHEME`), whose build command is a raw
  /// `swift build` with no gate of its own. An Xcode consumer's build command is
  /// `swift-mk toolchain build`, which gates in-process at that chokepoint, so
  /// gating here as well would run the gates twice; the empty-scheme check keeps a
  /// build to a single gate run.
  static func shouldGate(xcodeScheme: String) -> Bool {
    xcodeScheme.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// The exit status returned when `SWIFT_BUILD_CMD` is unset, so a misconfigured
  /// consumer fails loudly rather than silently building nothing.
  static let missingBuildCommandStatus: Int32 = 1

  /// Run the gates (when this is the gating chokepoint), then the configured build
  /// command with its output forwarded live. Returns the build command's exit
  /// status, the gate-failure status when the gates fail, or a nonzero status when
  /// `SWIFT_BUILD_CMD` is unset.
  public static func gateAndBuild() -> Int32 {
    if shouldGate(xcodeScheme: Env.get("SWIFT_XCODE_SCHEME")),
      !Lint.runBuildCheck(context: PathContext.current())
    {
      return Toolchain.gateFailureStatus
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
