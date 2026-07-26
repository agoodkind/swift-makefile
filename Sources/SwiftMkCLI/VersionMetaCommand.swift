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

/// `swift-mk version-meta`: print the release metadata contract the release
/// workflow appends to `$GITHUB_OUTPUT`.
struct VersionMetaCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "version-meta",
    abstract: "Print release metadata for the release workflow."
  )

  func run() throws {
    let version = try VersionMeta.resolve()
    let releaseTrack = version.track?.rawValue ?? ""
    Output.log("tag=\(version.tag)")
    Output.log("release_tag=\(version.tag)")
    Output.log("release_track=\(releaseTrack)")
    Output.log("artifact_version=\(version.artifact)")
    Output.log("build_version=\(version.build)")
    Output.log("marketing_version=\(version.marketing)")
  }
}
