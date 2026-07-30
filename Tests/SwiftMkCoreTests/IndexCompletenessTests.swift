//
//  IndexCompletenessTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - IndexCompletenessTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `IndexCompletenessTests.swift`; the suite is written as free `@Test` functions.
enum IndexCompletenessTests {}

@Test
func indexCompletenessExcludesVendoredDependencySources() {
  #expect(
    IndexCompleteness.isVendoredDependencySource(
      "/proj/Tuist/.build/checkouts/Nimble/Sources/Nimble/Nimble.swift"))
  #expect(
    IndexCompleteness.isVendoredDependencySource(
      "/proj/build/SourcePackages/checkouts/Sparkle/Sources/A.swift"))
}

@Test
func indexCompletenessKeepsProjectOwnSources() {
  #expect(
    !IndexCompleteness.isVendoredDependencySource("/proj/Sources/CellTunnelCore/A.swift"))
  #expect(
    !IndexCompleteness.isVendoredDependencySource(
      "/proj/Apps/iOS/Services/RelayController.swift"))
}

@Test
func indexCompletenessSkipsBuildVariableSourceReference() {
  #expect(
    IndexCompleteness.isUnresolvedSourceReference(
      "/proj/${DERIVED_FILE_DIR}/Generated/Config.generated.swift"))
  #expect(
    IndexCompleteness.isUnresolvedSourceReference("/proj/$(SRCROOT)/Sources/Foo.swift"))
}

@Test
func indexCompletenessSkipsStaleReferenceToMissingFile() {
  let missing = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(UUID().uuidString)-Gone.swift").path
  #expect(IndexCompleteness.isUnresolvedSourceReference(missing))
}

@Test
func indexCompletenessKeepsRealOnDiskSource() {
  // This test's own source file is a real `.swift` on disk, so the reference
  // resolves and is kept; no temp file or cleanup is needed.
  #expect(!IndexCompleteness.isUnresolvedSourceReference(#filePath))
}

@Test
func indexCompletenessDropsTargetTheBuildNeverCompiled() {
  // A target with no indexed source was not built, so a partial build does not
  // read as incomplete: the target is out of scope.
  let targetFiles: Set<String> = ["/proj/B/One.swift", "/proj/B/Two.swift"]
  let indexed: Set<String> = ["/proj/A/Only.swift"]
  #expect(!IndexCompleteness.targetIsInScope(targetFiles: targetFiles, indexed: indexed))
}

@Test
func indexCompletenessKeepsTargetTheBuildCompiled() {
  // A target with at least one indexed source was built, so the gate expects the
  // rest of its sources too; a partially-indexed built target stays catchable.
  let targetFiles: Set<String> = ["/proj/A/One.swift", "/proj/A/Two.swift"]
  let indexed: Set<String> = ["/proj/A/One.swift"]
  #expect(IndexCompleteness.targetIsInScope(targetFiles: targetFiles, indexed: indexed))
}

@Test
func indexCompletenessTargetWithNoSourcesIsOutOfScope() {
  #expect(
    !IndexCompleteness.targetIsInScope(targetFiles: [], indexed: ["/proj/A/One.swift"]))
}

#if canImport(XcodeProj, _version: 9.15.0)
  @Test
  func indexCompletenessFindsProjectsInFileSystemSynchronizedWorkspaceGroup() throws {
    try withTemporaryWorkspaceFixture(synchronizedDirectoryExists: true) { fixture in
      let paths = try IndexCompleteness.xcodeProjectPaths(inWorkspace: fixture.workspace.path)

      #expect(
        Set(paths) == [
          fixture.normalProject.path,
          fixture.synchronizedProject.path,
          fixture.explicitProject.path,
          fixture.containerProject.path,
        ])
      #expect(paths.count == 4)
    }
  }

  @Test
  func indexCompletenessReportsMissingFileSystemSynchronizedWorkspaceDirectory() throws {
    try withTemporaryWorkspaceFixture(synchronizedDirectoryExists: false) { fixture in
      let result = Result {
        try IndexCompleteness.xcodeProjectPaths(inWorkspace: fixture.workspace.path)
      }
      guard case .failure(let error) = result else {
        Issue.record("expected synchronized directory enumeration to fail")
        return
      }
      #expect(String(describing: error).contains(fixture.synchronizedDirectory.path))
    }
  }

  private struct WorkspaceFixture {
    let workspace: URL
    let normalProject: URL
    let synchronizedDirectory: URL
    let synchronizedProject: URL
    let explicitProject: URL
    let containerProject: URL
  }

  private func withTemporaryWorkspaceFixture(
    synchronizedDirectoryExists: Bool,
    _ body: (WorkspaceFixture) throws -> Void
  ) throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "swift-mk-workspace-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      do {
        try fileManager.removeItem(at: root)
      } catch {
        Output.warning("cleanup failed: \(error.localizedDescription)")
      }
    }

    let workspace = root.appendingPathComponent("Fixture.xcworkspace", isDirectory: true)
    let normalProject = root.appendingPathComponent("Normal.xcodeproj", isDirectory: true)
    let sharedPackages = root.appendingPathComponent("SharedPackages", isDirectory: true)
    let synchronizedDirectory = sharedPackages.appendingPathComponent(
      "Infrastructure", isDirectory: true)
    let synchronizedProject = synchronizedDirectory.appendingPathComponent(
      "Nested.xcodeproj", isDirectory: true)
    let explicitProject = synchronizedDirectory.appendingPathComponent(
      "Explicit.xcodeproj", isDirectory: true)
    let containerProject = root.appendingPathComponent("Container.xcodeproj", isDirectory: true)
    try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: normalProject, withIntermediateDirectories: true)
    if synchronizedDirectoryExists {
      try fileManager.createDirectory(at: synchronizedProject, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: explicitProject, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: containerProject, withIntermediateDirectories: true)
      try fileManager.createDirectory(
        at: synchronizedProject.appendingPathComponent("Ignored.xcodeproj", isDirectory: true),
        withIntermediateDirectories: true)
    }

    let workspaceData =
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
        <FileRef location = "group:Normal.xcodeproj">
        </FileRef>
        <Group location = "group:SharedPackages">
          <FileSystemSynchronizedGroup location = "group:Infrastructure">
            <FileRef location = "group:Explicit.xcodeproj">
            </FileRef>
            <FileRef location = "container:Container.xcodeproj">
            </FileRef>
          </FileSystemSynchronizedGroup>
        </Group>
      </Workspace>
      """
    try workspaceData.write(
      to: workspace.appendingPathComponent("contents.xcworkspacedata"),
      atomically: true,
      encoding: .utf8)

    try body(
      WorkspaceFixture(
        workspace: workspace,
        normalProject: normalProject,
        synchronizedDirectory: synchronizedDirectory,
        synchronizedProject: synchronizedProject,
        explicitProject: explicitProject,
        containerProject: containerProject))
  }
#endif
