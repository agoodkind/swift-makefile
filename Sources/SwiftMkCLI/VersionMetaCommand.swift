//
//  VersionMetaCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkCore

// MARK: - VersionMetaCommand

/// `swift-mk version-meta`: print the release metadata triple (`tag`,
/// `build_version`, `marketing_version`) the release workflow's meta job appends
/// to `$GITHUB_OUTPUT`. It computes the same scheme the build chokepoint stamps,
/// so the version a release ships and the version a local build carries come from
/// one source.
struct VersionMetaCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "version-meta",
    abstract: "Print tag, build_version, and marketing_version for the release."
  )

  func run() throws {
    let version = try VersionMeta.resolve()
    Output.log("tag=\(version.tag)")
    Output.log("build_version=\(version.build)")
    Output.log("marketing_version=\(version.marketing)")
  }
}
