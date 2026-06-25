//
//  BuildCache.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//
//  Compiler-cache wiring for SwiftPM builds. SWIFT_MK_BUILD_CACHE selects
//  ccache or sccache, and the gated build injects two-word CC/CXX wrappers
//  into the consumer build command's environment. `swift build` word-splits
//  those values; xcodebuild does not, so a consumer step that runs xcodebuild
//  must strip CC/CXX from its child environment.
//
//  When SWIFT_MK_BUILD_CACHE is unset, an installed ccache or sccache on PATH
//  is auto-detected and used, so a consumer that installs the tool (for
//  example via brew-packages in CI) does not also have to set the variable to
//  get caching. An explicit `off`/`none`/`0` opts out.
//

import Foundation

// MARK: - BuildCache

public enum BuildCache {
  static let supportedTools = ["ccache", "sccache"]
  /// Auto-detection order when SWIFT_MK_BUILD_CACHE is unset. ccache first
  /// because it is the tool every C/C++-heavy consumer installs today.
  static let autoDetectOrder = ["ccache", "sccache"]
  /// Explicit opt-out values. An empty value is deliberately not here: unset
  /// means auto-detect, not disabled.
  static let disabledValues = ["none", "off", "0"]

  /// The CC/CXX environment for a selection and a resolved tool path, pure
  /// for tests.
  static func wrapperEnvironment(toolPath: String) -> [String: String] {
    [
      "CC": "\(toolPath) /usr/bin/clang",
      "CXX": "\(toolPath) /usr/bin/clang++",
    ]
  }

  /// Whether an explicit selection opts out of caching, pure for tests. An
  /// empty (unset) value is not disabled; it triggers auto-detection.
  static func isDisabled(_ selection: String) -> Bool {
    disabledValues.contains(selection.lowercased())
  }

  /// Resolve a selection plus a tool-path lookup into the wrapper environment,
  /// or nil when caching is off, no tool is installed, or the selection is
  /// unknown. The selection is trimmed before parsing, so a stray newline or
  /// surrounding whitespace from CI/YAML is not treated as an unknown value.
  /// Pure given `lookup`, so a test injects a fake PATH probe rather than the
  /// real `command -v`. The behavior:
  ///   - off/none/0     -> nil (explicit opt-out).
  ///   - unset ("")     -> auto-detect ccache then sccache for a `swift build`;
  ///                       skipped for an xcodebuild build (see `xcodeBuild`).
  ///   - ccache/sccache -> use it when installed, else build uncached.
  ///   - anything else  -> fail loud, so a typo never silently builds uncached.
  static func resolve(
    selection rawSelection: String,
    xcodeBuild: Bool = false,
    lookup: (String) -> String?
  ) -> [String: String]? {
    let selection = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if isDisabled(selection) {
      return nil
    }
    if selection.isEmpty {
      // Auto-detect only for `swift build`, which word-splits the two-word CC/CXX
      // wrapper. xcodebuild does not split it, so injecting it would break the
      // build; an xcodebuild consumer that wants caching must opt in explicitly.
      if xcodeBuild {
        return nil
      }
      for tool in autoDetectOrder {
        guard let toolPath = lookup(tool) else {
          continue
        }
        Output.log(
          "build-cache: auto-detected \(tool); compiling through it "
            + "(set SWIFT_MK_BUILD_CACHE=off to disable)")
        return wrapperEnvironment(toolPath: toolPath)
      }
      return nil
    }
    guard supportedTools.contains(selection) else {
      Output.error("build-cache: SWIFT_MK_BUILD_CACHE must be ccache, sccache, none, off, or 0")
      return nil
    }
    guard let toolPath = lookup(selection) else {
      Output.log("build-cache: \(selection) selected but not installed; building uncached")
      return nil
    }
    Output.log("build-cache: compiling through \(selection)")
    return wrapperEnvironment(toolPath: toolPath)
  }

  /// Resolve SWIFT_MK_BUILD_CACHE into the wrapper environment using the real
  /// PATH probe, or nil when caching is off or no tool is installed. Auto-detection
  /// is suppressed for an xcodebuild consumer (`SWIFT_MK_XCODE_BUILD == "1"`).
  public static func environment() -> [String: String]? {
    resolve(
      selection: Env.get("SWIFT_MK_BUILD_CACHE"),
      xcodeBuild: Env.get("SWIFT_MK_XCODE_BUILD") == "1",
      lookup: installedToolPath)
  }

  /// The absolute path of `tool` on PATH, or nil when it is not installed. A
  /// process boundary (`command -v`), kept out of `resolve` so the decision is
  /// pure and testable.
  static func installedToolPath(_ tool: String) -> String? {
    let lookup = Shell.sh("command -v \(tool)")
    let path = lookup.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard lookup.status == 0, !path.isEmpty else {
      return nil
    }
    return path
  }
}
