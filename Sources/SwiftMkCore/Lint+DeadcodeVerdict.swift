//
//  Lint+DeadcodeVerdict.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-29.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Deadcode verdict

/// Shared failure classification and reporting for the two dead-code runner paths
/// (`Lint.runDeadcode` and `LintPolicy.deadcode`). The gate runs two scans, a SwiftPM
/// package scan and an Xcode-project scan, so its output can read as contradictory
/// ("No unused code detected" from one scan, a failure from the other). A failure here
/// is almost always a build or index problem, not a transient index race, yet the old
/// "index incomplete, not indexed" wording invited a clear-DerivedData-and-retry reflex.
/// These helpers print one classifying verdict line that names the cause and the action.
extension Lint {
  /// Why the dead-code gate failed before any baseline comparison.
  enum DeadcodeFailure: Equatable {
    case buildFailed
    case compileError
    case incompleteIndex
    case unknown
  }

  /// Classify a hard failure from the engine-emitted markers in the captured output.
  /// Keep the markers in sync with `IndexCompleteness.incompleteMessage` and
  /// `DeadcodeScan.diagnoseFailedCoverage`.
  static func classifyDeadcodeFailure(rawLines: [String]) -> DeadcodeFailure {
    let joined = rawLines.joined(separator: "\n")
    if joined.contains("produced no index")
      || joined.contains("unbuilt)")
      || joined.contains("no index store under")
    {
      return .incompleteIndex
    }
    if joined.contains("the coverage build failed status=") {
      return .buildFailed
    }
    return .unknown
  }

  /// The single verdict line. It names the cause and the one correct action, and rules
  /// out the clear-DerivedData-and-retry reflex on the build and index cases.
  static func deadcodeVerdict(_ failure: DeadcodeFailure, status: Int32) -> String {
    switch failure {
    case .buildFailed:
      return "lint-deadcode: verdict: the coverage build failed. Fix the build above. "
        + "Not a dead-code finding and not a flake."
    case .compileError:
      return "lint-deadcode: verdict: build failed (compile error). Fix the errors "
        + "above. Not an index flake; clearing DerivedData will not help."
    case .incompleteIndex:
      return "lint-deadcode: verdict: incomplete index from a failed coverage build. "
        + "Fix the build above. Not a transient flake."
    case .unknown:
      return "lint-deadcode: verdict: the dead-code gate failed (status \(status)); "
        + "see the output above. Not necessarily an index flake."
    }
  }

  /// Print the classified FAILED block plus the verdict line, returning true when it
  /// handled a build or index failure so the caller stops before the baseline
  /// comparison. The compile-error and unknown cases keep their detail; the classified
  /// build and index cases already printed their cause live, so only the verdict
  /// follows, which avoids resurfacing the package scan's output under the failure.
  static func reportDeadcodeBuildFailure(rawPath: String, status: Int32) -> Bool {
    let rawLines = Text.readLines(rawPath)
    let compileErrors = rawLines.filter(isSwiftCompileError)
    if !compileErrors.isEmpty {
      Output.log("lint-deadcode: FAILED")
      Output.log(
        "  The dead-code build did not compile; fix the compile error before this gate "
          + "can run.")
      Output.log("  Periphery's findings are unreliable against a partial index.\n")
      Output.log("Compile errors:")
      Output.log(compileErrors.joined(separator: "\n"))
      Output.log(deadcodeVerdict(.compileError, status: status))
      return true
    }
    if status >= deadcodeHardFailStatus {
      let failure = classifyDeadcodeFailure(rawLines: rawLines)
      Output.log("lint-deadcode: FAILED")
      if failure == .unknown {
        Output.log("  Exit status: \(status)\n")
        Output.log("Output:")
        Output.log(rawLines.joined(separator: "\n"))
      }
      Output.log(deadcodeVerdict(failure, status: status))
      return true
    }
    return false
  }
}
