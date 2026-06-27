//
//  GitIgnoreBatchTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - GitIgnoreBatchTests

enum GitIgnoreBatchTests {}

@Test
func gitIgnoredPathsHandlesLargeListWithoutOverflow() {
  // A single `git check-ignore` exec overflows the process argument limit past a
  // few thousand paths (Process raises NSInvalidArgumentException, aborting the
  // process). The batched implementation must complete instead, and still report
  // a known-ignored path that lands in a later batch. `git check-ignore` runs in
  // the process working directory, so this serializes against the gate tests that
  // temporarily chdir into a scratch checkout.
  TestGlobalLock.withLock {
    let pathCount = 5_000
    var paths = (0..<pathCount).map { "nonexistent-\($0).swift" }
    paths.append(".build/marker")
    let ignored = Lint.gitIgnoredPaths(paths)
    #expect(ignored.count <= paths.count)
    #expect(ignored.contains(".build/marker"))
  }
}
