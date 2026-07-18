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
    /// GitHub checks out `refs/pull/N/merge`, a merge of the base branch and the PR
    /// head, and a pull-request checkout has no `origin/<default>` and often cannot
    /// fetch one. The detector must still resolve the feature-branch merge-base from
    /// the merge ref's two parents, with no network fetch. The regression this guards:
    /// without the merge-ref parent path, the detector could not compute the merge-base
    /// on any PR and ran every gate every time.
    @Test
    func resolvesMergeBaseFromPullRequestMergeRefWithoutFetching() throws {
      let root = try makeTempDirectory()
      defer { removeTemporary(root.path) }
      let repo = root.appendingPathComponent("repo", isDirectory: true)

      try initRepository(repo)
      run(["checkout", "-q", "-b", "main"], in: repo)
      try writeFile(repo, "base.txt", "base\n")
      run(["add", "-A"], in: repo)
      run(["commit", "-qm", "base"], in: repo)
      let branchPoint = capture(["rev-parse", "HEAD"], in: repo)

      run(["checkout", "-q", "-b", "feature"], in: repo)
      try writeFile(repo, "feat.txt", "feat\n")
      run(["add", "-A"], in: repo)
      run(["commit", "-qm", "feat"], in: repo)
      let prHead = capture(["rev-parse", "HEAD"], in: repo)

      // main advances past the branch point, so the branch point is older than main's
      // tip and only a real merge-base (not "main's tip") is correct.
      run(["checkout", "-q", "main"], in: repo)
      try writeFile(repo, "advance.txt", "advance\n")
      run(["add", "-A"], in: repo)
      run(["commit", "-qm", "advance"], in: repo)

      // Build the pull-request merge commit (base merged with the PR head) like
      // refs/pull/N/merge, then detach onto it. There is no `origin` remote, so the
      // detector cannot fetch and must use the merge ref's parents.
      run(["checkout", "-q", "-b", "prmerge", "main"], in: repo)
      run(["merge", "-q", "--no-edit", "feature"], in: repo)
      let mergeCommit = capture(["rev-parse", "HEAD"], in: repo)
      run(["checkout", "-q", "--detach", mergeCommit], in: repo)

      let saved = FileManager.default.currentDirectoryPath
      defer { _ = FileManager.default.changeCurrentDirectoryPath(saved) }
      #expect(FileManager.default.changeCurrentDirectoryPath(repo.path))

      let mergeBase = CiChanged.featureBranchMergeBase(defaultBranch: "main", head: prHead)
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
