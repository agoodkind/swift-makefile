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

import Foundation

// MARK: - BuildCache

public enum BuildCache {
  static let supportedTools = ["ccache", "sccache"]
  static let disabledValues = ["", "none", "off", "0"]

  /// The CC/CXX environment for a selection and a resolved tool path, pure
  /// for tests.
  static func wrapperEnvironment(toolPath: String) -> [String: String] {
    [
      "CC": "\(toolPath) /usr/bin/clang",
      "CXX": "\(toolPath) /usr/bin/clang++",
    ]
  }

  /// Whether a selection disables caching, pure for tests.
  static func isDisabled(_ selection: String) -> Bool {
    disabledValues.contains(selection.lowercased())
  }

  /// Resolve SWIFT_MK_BUILD_CACHE into the wrapper environment, or nil when
  /// caching is off or the selected tool is absent. An unknown selection
  /// fails loud rather than building uncached silently.
  public static func environment() -> [String: String]? {
    let selection = Env.get("SWIFT_MK_BUILD_CACHE").lowercased()
    if isDisabled(selection) {
      return nil
    }
    guard supportedTools.contains(selection) else {
      Output.error("build-cache: SWIFT_MK_BUILD_CACHE must be ccache, sccache, none, or off")
      return nil
    }
    let lookup = Shell.sh("command -v \(selection)")
    let toolPath = lookup.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard lookup.status == 0, !toolPath.isEmpty else {
      Output.log("build-cache: \(selection) selected but not installed; building uncached")
      return nil
    }
    Output.log("build-cache: compiling through \(selection)")
    return wrapperEnvironment(toolPath: toolPath)
  }
}
