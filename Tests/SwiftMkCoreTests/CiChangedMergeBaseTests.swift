//
//  CiChangedMergeBaseTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-17.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - CiChangedMergeBaseTests

// Nested under EnvironmentSerialized because it changes the process working
// directory, which the .serialized parent keeps from racing other cwd/env suites.
extension EnvironmentSerialized {
  @Suite struct CiChangedMergeBaseTests {
    /// A pull-request checkout maps only the PR ref, so `origin/<default>` is absent
    /// and a plain `git fetch origin <default>` updates only FETCH_HEAD. The detector
    /// must still resolve the feature-branch merge-base by fetching the default branch
    /// into its remote-tracking ref. The regression this guards: without the explicit
    /// refspec, the retried `merge-base origin/<default> head` could not resolve and
    /// the detector ran every gate on every PR.
    @Test
    func resolvesMergeBaseUnderNarrowRefspecPullRequestCheckout() throws {
      let root = try makeTempDirectory()
      defer { removeTemporary(root.path) }

      let remote = root.appendingPathComponent("remote", isDirectory: true)
      let checkout = root.appendingPathComponent("pr", isDirectory: true)

      // Upstream: main, then a feature branch, then main advances past the branch point.
      try initRepository(remote)
      run(["checkout", "-q", "-b", "main"], in: remote)
      try writeFile(remote, "base.txt", "base\n")
      run(["add", "-A"], in: remote)
      run(["commit", "-qm", "base"], in: remote)
      let branchPoint = capture(["rev-parse", "HEAD"], in: remote)
      run(["checkout", "-q", "-b", "feature"], in: remote)
      try writeFile(remote, "feat.txt", "feat\n")
      run(["add", "-A"], in: remote)
      run(["commit", "-qm", "feat"], in: remote)
      let head = capture(["rev-parse", "HEAD"], in: remote)
      run(["checkout", "-q", "main"], in: remote)
      try writeFile(remote, "advance.txt", "advance\n")
      run(["add", "-A"], in: remote)
      run(["commit", "-qm", "advance"], in: remote)

      // PR-style checkout: origin maps only the feature ref, so origin/main is absent.
      let featureRefspec = "+refs/heads/feature:refs/remotes/origin/feature"
      try initRepository(checkout)
      run(["remote", "add", "origin", remote.path], in: checkout)
      run(["config", "remote.origin.fetch", featureRefspec], in: checkout)
      run(["fetch", "-q", "--no-tags", "origin"], in: checkout)
      run(["checkout", "-q", head], in: checkout)

      let saved = FileManager.default.currentDirectoryPath
      defer { _ = FileManager.default.changeCurrentDirectoryPath(saved) }
      #expect(FileManager.default.changeCurrentDirectoryPath(checkout.path))

      let mergeBase = CiChanged.featureBranchMergeBase(defaultBranch: "main", head: head)
      #expect(mergeBase == branchPoint)
    }

    // MARK: Fixture helpers

    private func makeTempDirectory() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-mk-mergebase-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    private func initRepository(_ directory: URL) throws {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      run(["init", "-q"], in: directory)
      run(["config", "user.email", "test@example.com"], in: directory)
      run(["config", "user.name", "Test"], in: directory)
      run(["config", "commit.gpgsign", "false"], in: directory)
    }

    private func writeFile(_ directory: URL, _ name: String, _ body: String) throws {
      try Data(body.utf8).write(to: directory.appendingPathComponent(name))
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["git"] + arguments
      process.currentDirectoryURL = directory
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()
      do {
        try process.run()
      } catch {
        return ""
      }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(data: data, encoding: .utf8) ?? ""
    }

    private func capture(_ arguments: [String], in directory: URL) -> String {
      run(arguments, in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
}
