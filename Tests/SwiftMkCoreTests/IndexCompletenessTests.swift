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
