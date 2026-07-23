//
//  BuildTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BuildTests

enum BuildTests {}

@Test
func inlineGatesSkipUnderGitHubActions() {
  // A real CI run sets GITHUB_ACTIONS=true and a non-empty GITHUB_RUN_ID. The
  // gate runs as its own decoupled CI job, so `build` must not re-run it inline.
  #expect(
    !Build.runsInlineGates(
      githubActions: "true", githubRunId: "123456789", skipInlineGates: ""))
}

@Test
func inlineGatesSkipWhenExplicitlyRequested() {
  #expect(
    !Build.runsInlineGates(
      githubActions: "", githubRunId: "", skipInlineGates: "1"))
}

@Test
func inlineGatesRunLocally() {
  // No GitHub Actions environment is a local or agent run, where `build` is the
  // unbypassable chokepoint and must run the gates inline.
  #expect(
    Build.runsInlineGates(
      githubActions: "", githubRunId: "", skipInlineGates: ""))
  #expect(
    Build.runsInlineGates(
      githubActions: "false", githubRunId: "", skipInlineGates: ""))
}

@Test
func inlineGatesRunWhenRunIdMissing() {
  // GITHUB_ACTIONS alone is not a CI run: without a run id there is no decoupled
  // gate job, so the inline gate must still fire rather than silently vanish.
  #expect(
    Build.runsInlineGates(
      githubActions: "true", githubRunId: "", skipInlineGates: ""))
}
