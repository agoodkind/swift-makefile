//
//  ToolchainBuildScriptTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

// MARK: - ToolchainBuildScriptTests

enum ToolchainBuildScriptTests {
  @Test
  static func poolBuildScriptUsesOnlySwiftPMCacheFlags() throws {
    let script = try rootFile("scripts/swift-mk-build.sh")

    #expect(script.contains(#"printf "%s\n" "--cache-path""#))
    #expect(!script.contains("-clonedSourcePackagesDirPath"))
    #expect(!script.contains("-disableAutomaticPackageResolution"))
    #expect(!script.contains("--disable-automatic-resolution"))
  }

  @Test
  static func poolBuildScriptHashesPackageManifestWhenResolvedFileIsAbsent() throws {
    let script = try rootFile("scripts/swift-mk-build.sh")

    #expect(script.contains("Package.swift"))
    #expect(!script.contains("swift-mk-noresolved"))
  }

  @Test
  static func poolBuildScriptRejectsEmptySwiftPMBinPath() throws {
    let script = try rootFile("scripts/swift-mk-build.sh")
    let validation = #"if [[ -z "${bin_dir}" ]]; then"#
    let binPathAssignment = #"bin_path="${bin_dir}/swift-mk""#
    let validationIndex = script.range(of: validation)?.lowerBound
    let binPathAssignmentIndex = script.range(of: binPathAssignment)?.lowerBound

    #expect(script.contains(validation))
    #expect(script.contains("could not resolve SwiftPM binary output path"))
    #expect(binPathAssignmentIndex != nil)
    if let validationIndex, let binPathAssignmentIndex {
      #expect(validationIndex < binPathAssignmentIndex)
    }
  }

  @Test
  static func setupBuildEnvConfiguresPoolCacheByMountPresence() throws {
    let action = try rootFile(".github/actions/setup-build-env/action.yml")

    #expect(!action.contains("if: runner.environment == 'self-hosted'"))
    #expect(action.contains(#"if [[ ! -d "${POOL_CACHE_ROOT}" ]]; then"#))
  }

  private static func rootFile(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
  }
}
