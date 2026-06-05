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
