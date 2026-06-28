//
//  BuildLockTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BuildLockTests

/// Serialized because `withLock` mutates the process-global lock state and the
/// `SWIFT_MK_BUILD_LOCK_HELD` environment marker.
@Suite(.serialized)
enum BuildLockTests {
  @Test
  static func withLockReturnsTheBodyValue() {
    let value = BuildLock.withLock { 7 }
    #expect(value == 7)
  }

  /// The load-bearing re-entrancy property: a nested acquire inside one process must
  /// not block on the lock the outer acquire already holds.
  @Test
  static func nestedWithLockDoesNotDeadlock() {
    let value = BuildLock.withLock {
      BuildLock.withLock { 9 }
    }
    #expect(value == 9)
  }

  @Test
  static func worktreeRootIsNonEmptyAndStable() {
    let first = BuildLock.worktreeRoot()
    let second = BuildLock.worktreeRoot()
    #expect(!first.isEmpty)
    #expect(first == second)
  }
}
