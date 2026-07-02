//
//  Toolchain+Generate.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Xcode-app DerivedData redirect

extension Toolchain {
  /// Generate the project (and, for Tuist, the workspace). On success, point the
  /// generated container's Xcode-app DerivedData at the same per-worktree
  /// `.derived-data` the CLI uses, so opening the worktree in Xcode.app stops writing
  /// to the global `~/Library/.../DerivedData/<Name>-<hash>` pile.
  @discardableResult
  public static func generate(_ generator: Generator, extraArguments: [String] = []) -> Int32 {
    let status: Int32
    switch generator {
    case .tuist:
      Output.info("toolchain: tuist generate")
      status = Shell.runForwardingOutput("tuist", ["generate", "--no-open"] + extraArguments)
    case .xcodegen:
      Output.info("toolchain: xcodegen generate")
      status = Shell.runForwardingOutput("xcodegen", ["generate"] + extraArguments)
    }
    if status == 0 {
      redirectGuiDerivedData(generator: generator)
    }
    return status
  }

  /// Point the generated container's Xcode-app DerivedData at the same per-worktree
  /// `.derived-data` the CLI uses, via an absolute path so the relative-base ambiguity
  /// between Xcode versions cannot misplace it. Best-effort: a write failure only means
  /// Xcode keeps its default location, so it never fails generation.
  static func redirectGuiDerivedData(generator: Generator) {
    let cwd = FileManager.default.currentDirectoryPath
    guard let workspace = generatedWorkspacePath(generator: generator, in: cwd) else {
      Output.log("toolchain: no generated workspace found to redirect DerivedData")
      return
    }
    let derivedData = resolvedDerivedDataPath()
    do {
      try writeDerivedDataRedirect(workspace: workspace, derivedDataPath: derivedData)
      Output.info("toolchain: Xcode DerivedData -> \(derivedData)")
    } catch {
      Output.log("toolchain: could not redirect Xcode DerivedData: \(error)")
    }
  }

  /// Write the per-user `WorkspaceSettings.xcsettings` that pins the container's Xcode
  /// DerivedData to `derivedDataPath`. Separated from env/cwd lookup so it is testable.
  static func writeDerivedDataRedirect(workspace: String, derivedDataPath: String) throws {
    let settingsDir =
      (workspace as NSString)
      .appendingPathComponent("xcuserdata")
      + "/\(NSUserName()).xcuserdatad"
    let settingsPath =
      (settingsDir as NSString)
      .appendingPathComponent("WorkspaceSettings.xcsettings")
    try FileManager.default.createDirectory(
      atPath: settingsDir, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: derivedDataRedirectSettings(derivedDataPath: derivedDataPath),
      format: .xml,
      options: 0)
    try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
  }

  /// The plist keys Xcode reads for a custom DerivedData location. `AbsolutePath`
  /// avoids the relative-base ambiguity between Xcode versions.
  static func derivedDataRedirectSettings(derivedDataPath: String) -> [String: String] {
    [
      "DerivedDataLocationStyle": "AbsolutePath",
      "DerivedDataCustomLocation": derivedDataPath,
      "BuildLocationStyle": "UseAppPreferences",
    ]
  }

  /// The per-worktree DerivedData path, resolved to absolute. Honors
  /// `SWIFT_MK_DERIVED_DATA` (the make layer sets it), else `<cwd>/.derived-data`.
  static func resolvedDerivedDataPath() -> String {
    let configured =
      Env.get("SWIFT_MK_DERIVED_DATA")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let path = configured.isEmpty ? ".derived-data" : configured
    if (path as NSString).isAbsolutePath {
      return path
    }
    let cwd = FileManager.default.currentDirectoryPath
    return (cwd as NSString).appendingPathComponent(path)
  }

  /// Locate the generated container in `directory`: the `.xcworkspace` a Tuist generate
  /// emits, or the xcodegen project's embedded `project.xcworkspace`. Entries are sorted
  /// so the choice is deterministic when more than one container is present.
  static func generatedWorkspacePath(generator: Generator, in directory: String) -> String? {
    let entries = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    switch generator {
    case .tuist:
      guard let workspace = entries.first(where: { $0.hasSuffix(".xcworkspace") }) else {
        return nil
      }
      return (directory as NSString).appendingPathComponent(workspace)
    case .xcodegen:
      guard let project = entries.first(where: { $0.hasSuffix(".xcodeproj") }) else {
        return nil
      }
      return
        (directory as NSString)
        .appendingPathComponent(project) + "/project.xcworkspace"
    }
  }
}
