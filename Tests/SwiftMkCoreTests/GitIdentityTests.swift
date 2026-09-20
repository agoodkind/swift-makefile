//
//  GitIdentityTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - GitIdentityTests

@Test
func gitIdentityLoadReadsLocalNameAndEmail() throws {
  let repo = try makeIsolatedGitRepo()
  defer { removeTemporary(repo.path) }
  runGit(["config", "user.name", "Test User"], in: repo)
  runGit(["config", "user.email", "test@example.com"], in: repo)

  let loaded = GitIdentity.load(directory: repo.path, environment: isolatedGitEnvironment(in: repo))
  #expect(loaded == .success(GitIdentity(name: "Test User", email: "test@example.com")))
}

@Test
func gitIdentityLoadFailsWhenNameIsMissing() throws {
  let repo = try makeIsolatedGitRepo()
  defer { removeTemporary(repo.path) }
  runGit(["config", "user.email", "test@example.com"], in: repo)

  let loaded = GitIdentity.load(directory: repo.path, environment: isolatedGitEnvironment(in: repo))
  #expect(loaded == .failure(.missingName))
}

@Test
func gitIdentityLoadFailsWhenEmailIsMissing() throws {
  let repo = try makeIsolatedGitRepo()
  defer { removeTemporary(repo.path) }
  runGit(["config", "user.name", "Test User"], in: repo)

  let loaded = GitIdentity.load(directory: repo.path, environment: isolatedGitEnvironment(in: repo))
  #expect(loaded == .failure(.missingEmail))
}

@Test
func gitIdentityRegexEscapesEmailDots() {
  let identity = GitIdentity(name: "Test User", email: "test@example.com")
  #expect(identity.regexEscapedHeaderValues["GIT_USER_NAME"] == "Test User")
  #expect(identity.regexEscapedHeaderValues["GIT_USER_EMAIL"] == "test@example\\.com")
}

// MARK: - Git fixture helpers

private func makeIsolatedGitRepo() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-git-identity-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  runGit(["init", "-q"], in: url)
  let emptyHooks = url.appendingPathComponent(".git/no-hooks", isDirectory: true)
  try FileManager.default.createDirectory(at: emptyHooks, withIntermediateDirectories: true)
  runGit(["config", "core.hooksPath", emptyHooks.path], in: url)
  return url
}

private func isolatedGitEnvironment(in repo: URL) -> [String: String] {
  let empty = repo.appendingPathComponent("empty.gitconfig").path
  if !FileManager.default.fileExists(atPath: empty) {
    let created = FileManager.default.createFile(atPath: empty, contents: Data())
    if !created {
      Output.error("git-identity-test: could not create \(empty)")
    }
  }
  return [
    "GIT_CONFIG_GLOBAL": empty,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_SYSTEM": empty,
  ]
}

@discardableResult
private func runGit(_ arguments: [String], in directory: URL) -> Shell.Result {
  Shell.run("git", ["-C", directory.path] + arguments)
}
