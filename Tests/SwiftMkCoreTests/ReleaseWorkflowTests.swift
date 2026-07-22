//
//  ReleaseWorkflowTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ReleaseWorkflowTests

enum ReleaseWorkflowTests {}

@Test
func releaseCallerRunsSignedDryRunOnlyForSameRepositoryPullRequests() throws {
  let caller = try releaseWorkflowText(named: "release.yml")
  let releaseJob = try workflowSection(
    caller, from: "\n  release:\n", to: "\n  release-dry-run:\n")
  let dryRunJob = try workflowSuffix(caller, from: "\n  release-dry-run:\n")

  #expect(caller.contains("  pull_request:\n"))
  #expect(
    releaseJob.contains(
      "|| github.event.pull_request.head.repo.full_name == github.repository }}"
    ))
  #expect(releaseJob.contains("ephemeral: ${{ github.event_name == 'pull_request' }}"))
  #expect(releaseJob.contains("secrets: inherit"))

  #expect(dryRunJob.contains("name: Release (dry run)"))
  #expect(dryRunJob.contains("needs: release"))
  #expect(dryRunJob.contains("if: ${{ always() && github.event_name == 'pull_request' }}"))
  #expect(dryRunJob.contains("contents: read"))
  #expect(dryRunJob.contains("needs.release.result != 'success'"))
}

@Test
func ephemeralReleaseRequiresEverySigningCredentialAndRunsSignedStages() throws {
  let release = try releaseWorkflowText(named: "_release.yml")
  let metaJob = try workflowSection(release, from: "\n  meta:\n", to: "\n  build:\n")
  let buildJob = try workflowSection(release, from: "\n  build:\n", to: "\n  notarize:\n")
  let notarizeJob = try workflowSection(
    release, from: "\n  notarize:\n", to: "\n  publish:\n")

  #expect(release.contains("      ephemeral:\n        type: boolean\n        default: false"))
  for requiredInput in [
    "HAS_SIGNING_CERT", "HAS_SIGNING_PASSWORD", "HAS_NOTARY_KEY", "HAS_NOTARY_KEY_ID",
    "HAS_NOTARY_ISSUER_ID", "HAS_TEAM_ID",
  ] {
    #expect(metaJob.contains(requiredInput))
  }
  #expect(metaJob.contains("if: inputs.ephemeral"))
  #expect(metaJob.contains("exit 1"))

  #expect(buildJob.contains("name: Install signing certificate"))
  #expect(buildJob.contains("name: Build release artifacts"))
  #expect(notarizeJob.contains("inputs.ephemeral || inputs.notarize"))
  #expect(notarizeJob.contains("inputs.ephemeral || inputs.attest"))
}

@Test
func ephemeralReleaseSkipsPublishWhileProductionPublishRemainsUnchanged() throws {
  let release = try releaseWorkflowText(named: "_release.yml")
  let publishJob = try workflowSection(release, from: "\n  publish:\n", to: "\n  smoke:\n")
  let makefile = try releaseRepositoryFileText(named: "swift-release.mk")

  #expect(publishJob.contains("if: ${{ !inputs.ephemeral }}"))
  #expect(publishJob.contains("run: make release-publish"))
  #expect(makefile.contains(#"git tag "$$RELEASE_TAG""#))
  #expect(makefile.contains(#"git push origin "$$RELEASE_TAG""#))
  #expect(makefile.contains(#"gh release create "$$RELEASE_TAG""#))
}

@Test
func ephemeralReleaseUsesPullRequestRunnerLabelsAndDiagnostics() throws {
  let release = try releaseWorkflowText(named: "_release.yml")
  let planRunner = try releaseRepositoryFileText(
    named: ".github/actions/plan-runner/action.yml")
  let buildJob = try workflowSection(release, from: "\n  build:\n", to: "\n  notarize:\n")

  #expect(release.contains("uses: ./.github/actions/plan-runner"))
  #expect(planRunner.contains("ci-force-hosted"))
  #expect(planRunner.contains("ci-force-pool"))
  #expect(release.contains("SWIFT_MK_LOG_LEVEL: ${{ inputs.ephemeral &&"))
  #expect(release.contains("'ci-diagnostics') && 'debug' || '' }}"))

  let start = try #require(buildJob.range(of: "name: Start CI instrumentation"))
  let certificate = try #require(buildJob.range(of: "name: Install signing certificate"))
  let build = try #require(buildJob.range(of: "name: Build release artifacts"))
  let stop = try #require(buildJob.range(of: "name: Stop CI instrumentation"))
  let upload = try #require(buildJob.range(of: "name: Upload CI instrumentation"))

  #expect(start.lowerBound < certificate.lowerBound)
  #expect(certificate.lowerBound < build.lowerBound)
  #expect(build.lowerBound < stop.lowerBound)
  #expect(stop.lowerBound < upload.lowerBound)
  #expect(buildJob.contains("inputs.ephemeral"))
  #expect(buildJob.contains("ci-diagnostics/start.sh"))
  #expect(buildJob.contains("ci-diagnostics/stop.sh"))
  #expect(buildJob.contains("path: ${{ runner.temp }}/ci-diagnostics"))
}

// MARK: - ReleaseWorkflowTestError

private enum ReleaseWorkflowTestError: Error {
  case missingSection(String)
}

private func releaseWorkflowText(named name: String) throws -> String {
  try releaseRepositoryFileText(named: ".github/workflows/\(name)")
}

private func releaseRepositoryFileText(named name: String) throws -> String {
  let fileURL = releaseWorkflowRepositoryRoot().appendingPathComponent(name)
  return try String(contentsOf: fileURL, encoding: .utf8)
}

private func workflowSection(_ text: String, from start: String, to end: String) throws -> String {
  guard let startRange = text.range(of: start) else {
    throw ReleaseWorkflowTestError.missingSection(start)
  }
  guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
    throw ReleaseWorkflowTestError.missingSection(end)
  }
  return String(text[startRange.lowerBound..<endRange.lowerBound])
}

private func workflowSuffix(_ text: String, from start: String) throws -> String {
  guard let startRange = text.range(of: start) else {
    throw ReleaseWorkflowTestError.missingSection(start)
  }
  return String(text[startRange.lowerBound...])
}

private func releaseWorkflowRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
