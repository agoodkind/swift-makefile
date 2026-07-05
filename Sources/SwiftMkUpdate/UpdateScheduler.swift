//
//  UpdateScheduler.swift
//  SwiftMkUpdate
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - SchedulerMode

public enum SchedulerMode: String, Equatable {
  case apply
  case check
}

// MARK: - SchedulerHooks

public struct SchedulerHooks {
  public let enabled: () -> Bool
  public let mode: () -> SchedulerMode
  public let options: () -> UpdateOptions
  public let stopForRelaunch: () -> Void
  public let log: (String) -> Void

  public init(
    enabled: @escaping () -> Bool,
    mode: @escaping () -> SchedulerMode,
    options: @escaping () -> UpdateOptions,
    stopForRelaunch: @escaping () -> Void,
    log: @escaping (String) -> Void
  ) {
    self.enabled = enabled
    self.mode = mode
    self.options = options
    self.stopForRelaunch = stopForRelaunch
    self.log = log
  }
}

// MARK: - SchedulerClock

public protocol SchedulerClock {
  func sleep(for interval: TimeInterval) throws
}

// MARK: - ThreadSchedulerClock

public struct ThreadSchedulerClock: SchedulerClock {
  public init() {
    // Stateless clock waits on a semaphore with a deadline.
  }

  public func sleep(for interval: TimeInterval) {
    // Add the interval as seconds via the DispatchTime Double overload, which
    // avoids the nanosecond Int conversion that could overflow for a very large
    // interval, and blocks on a semaphore rather than a banned sleep call.
    if interval > 0 {
      _ = DispatchSemaphore(value: 0).wait(timeout: .now() + interval)
    }
  }
}

// MARK: - SchedulerUpdateRunning

public protocol SchedulerUpdateRunning {
  func check(options: UpdateOptions) throws -> CheckResult
  func apply(options: UpdateOptions) throws -> ApplyResult
}

// MARK: - DefaultSchedulerUpdateRunner

public struct DefaultSchedulerUpdateRunner: SchedulerUpdateRunning {
  public init() {
    // Stateless runner delegates each operation to a fresh updater.
  }

  public func check(options: UpdateOptions) throws -> CheckResult {
    try Updater(options: options).check()
  }

  public func apply(options: UpdateOptions) throws -> ApplyResult {
    try Updater(options: options).apply()
  }
}

// MARK: - UpdateScheduler

public enum UpdateScheduler {
  private static let minimumSleepInterval: TimeInterval = 1

  public static func run(
    hooks: SchedulerHooks,
    clock: any SchedulerClock = ThreadSchedulerClock(),
    updater: any SchedulerUpdateRunning = DefaultSchedulerUpdateRunner(),
    runOnce: Bool = false
  ) throws {
    while true {
      if hooks.enabled() {
        do {
          let shouldStop = try runIteration(hooks: hooks, updater: updater)
          if shouldStop {
            return
          }
        } catch {
          // A transient check/apply failure must not stop the daemon; log it and
          // retry on the next interval.
          UpdateDiagnostics.error("update scheduler iteration failed: \(error)")
          hooks.log("update scheduler: iteration failed: \(error)")
        }
      } else {
        hooks.log("update scheduler: disabled")
      }
      if runOnce {
        return
      }
      let options = hooks.options()
      try clock.sleep(for: max(options.config.interval, minimumSleepInterval))
    }
  }

  private static func runIteration(
    hooks: SchedulerHooks,
    updater: any SchedulerUpdateRunning
  ) throws -> Bool {
    let options = hooks.options()
    switch hooks.mode() {
    case .check:
      _ = try updater.check(options: options)
      return false
    case .apply:
      if ReleaseResolver.isDevelopmentVersion(options.config.currentVersion) {
        hooks.log("update scheduler: development build uses check mode")
        _ = try updater.check(options: options)
        return false
      }
      let result = try updater.apply(options: options)
      if result.applied {
        hooks.stopForRelaunch()
        return true
      }
      return false
    }
  }
}
