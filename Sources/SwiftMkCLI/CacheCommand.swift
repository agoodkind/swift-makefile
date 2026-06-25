//
//  CacheCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkCore

// MARK: - CacheCommand

/// `swift-mk cache`: the engine-owned cache model. `plan` emits the CI cache plan
/// (keys plus paths) to `$GITHUB_OUTPUT`; `paths`, `info`, and `clean` introspect
/// and manage the same caches locally. The path list and keys live in one place so
/// CI and local share the model instead of a parallel shell script.
struct CacheCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cache",
    abstract: "Emit the CI cache plan and manage the local build caches.",
    subcommands: [
      CachePlanCommand.self, CachePathsCommand.self, CacheInfoCommand.self, CacheCleanCommand.self,
    ]
  )
}

// MARK: - CachePlanCommand

struct CachePlanCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan",
    abstract: "Resolve the cache plan from the environment and append it to $GITHUB_OUTPUT."
  )

  func run() throws {
    let status = CacheService.runPlan()
    if status != 0 { throw ExitCode(status) }
  }
}

// MARK: - CachePathsCommand

struct CachePathsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "paths",
    abstract: "Print the canonical cacheable directories, grouped by bucket."
  )

  func run() throws {
    let status = CacheService.runPaths()
    if status != 0 { throw ExitCode(status) }
  }
}

// MARK: - CacheInfoCommand

struct CacheInfoCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "info",
    abstract: "Print each cache directory with whether it exists and its size."
  )

  func run() throws {
    let status = CacheService.runInfo()
    if status != 0 { throw ExitCode(status) }
  }
}

// MARK: - CacheCleanCommand

struct CacheCleanCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clean",
    abstract: "Remove the local cache directories."
  )

  func run() throws {
    let status = CacheService.runClean()
    if status != 0 { throw ExitCode(status) }
  }
}
