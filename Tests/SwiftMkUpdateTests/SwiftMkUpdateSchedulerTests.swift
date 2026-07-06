//
//  SwiftMkUpdateSchedulerTests.swift
//  SwiftMkUpdateTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkUpdate

// MARK: - ThrowingScheduledRunner

private struct ThrowingScheduledRunner: SchedulerUpdateRunning {
  func check(options _: UpdateOptions) throws -> CheckResult {
    throw UpdateError.http("transient failure")
  }

  func apply(options _: UpdateOptions) throws -> ApplyResult {
    throw UpdateError.http("transient failure")
  }
}

// MARK: - SwiftMkUpdateSchedulerTests

enum SwiftMkUpdateSchedulerTests {
  private static func options() -> UpdateOptions {
    let config = UpdateConfig(
      repo: "agoodkind/swift-makefile",
      binary: "swift-mk",
      teamID: "H3BMXM4W7H",
      currentVersion: "202607010000-a-abc1234")
    return UpdateOptions(
      config: config,
      targetPath: "/tmp/swift-mk",
      cacheDir: "/tmp/swift-mk-cache",
      statePath: "/tmp/swift-mk-state/state.json")
  }

  @Test
  static func iterationFailureIsLoggedAndDoesNotStopTheDaemon() throws {
    let logs = LockedBox<[String]>([])
    let relaunched = LockedBox<Bool>(false)
    let hooks = SchedulerHooks(
      enabled: { true },
      mode: { .check },
      options: { options() },
      stopForRelaunch: { relaunched.value = true },
      log: { message in logs.value += [message] })

    // A throwing iteration must be caught and logged, not propagated out of run.
    try UpdateScheduler.run(
      hooks: hooks,
      clock: TestSchedulerClock(),
      updater: ThrowingScheduledRunner(),
      runOnce: true)

    #expect(logs.value.contains { $0.contains("iteration failed") })
    #expect(relaunched.value == false)
  }
}
