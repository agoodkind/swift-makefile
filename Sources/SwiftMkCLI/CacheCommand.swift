//
//  CacheCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkCore
import SwiftMkMaintCore

// MARK: - CacheCommand

/// `swift-mk cache`: the engine-owned cache model. `plan` emits the CI cache plan
/// (keys plus paths) to `$GITHUB_OUTPUT`; `paths`, `info`, `clean`, and `prune`
/// introspect and manage the same caches locally. The path list and keys live in
/// one place so CI and local share the model instead of a parallel shell script.
struct CacheCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cache",
    abstract: "Emit the CI cache plan and manage the local build caches.",
    subcommands: [
      CachePlanCommand.self, CachePathsCommand.self, CacheInfoCommand.self, CacheCleanCommand.self,
      CachePruneCommand.self,
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

// MARK: - CachePruneCommand

struct CachePruneCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prune",
    abstract: "Evict least-recently-used top-level entries until a cache is at a byte cap."
  )

  @Option(name: .long, help: "Directory whose top-level entries should be pruned.")
  var path: String

  @Option(name: .customLong("max-bytes"), help: "Maximum total bytes to keep.")
  var maxBytes: UInt64

  func run() throws {
    do {
      let diagnostics = CachePruneDiagnostics(
        info: Output.info,
        warning: Output.warning,
        error: Output.error)
      let result = try CachePruner(diagnostics: diagnostics).prune(path: path, maxBytes: maxBytes)
      let entryNoun = result.evictedEntries.count == 1 ? "entry" : "entries"
      Output.log(
        "cache prune: evicted \(result.evictedEntries.count) \(entryNoun), "
          + "\(result.evictedBytes) bytes; remaining \(result.remainingBytes) bytes")
    } catch {
      Output.logError("cache prune: \(error)")
      throw ExitCode(1)
    }
  }
}
