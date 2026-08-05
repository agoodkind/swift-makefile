//
//  OffPoolWork.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - OffPoolWork

/// Runs work that blocks its thread somewhere other than Swift Testing's cooperative
/// thread pool.
///
/// Swift Testing runs `@Test` bodies as tasks on the cooperative pool, whose width is
/// the machine's core count. A blocking call made straight from a test body holds one
/// of those threads for its whole duration, so enough concurrent blocking tests hold
/// every thread at once. The pool shares its worker threads with the default-quality
/// libdispatch queues, so once it is full, nothing libdispatch schedules there can
/// start either. Any blocking call that is released by such a scheduled block then
/// waits forever, because the thread that would release it can only come from the pool
/// the wait is helping to exhaust. The whole run stalls with no thread able to make
/// progress and almost no processor time consumed.
///
/// Suspending on a thread of our own has neither problem: the cooperative thread is
/// released for the duration, and the blocking call runs on a thread the operating
/// system schedules directly rather than one drawn from a bounded pool.
enum OffPoolWork {
  /// Run `body` on a dedicated thread and suspend the caller until it returns.
  static func run<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      let worker = Thread {
        continuation.resume(returning: body())
      }
      worker.name = "swift-mk-tests.blocking"
      worker.start()
    }
  }

  /// Run a throwing `body` on a dedicated thread and suspend the caller until it returns.
  static func run<Value: Sendable>(
    _ body: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let worker = Thread {
        // Result carries the success or the thrown error to the continuation in
        // one step, so the error reaches the awaiting call site rather than being
        // caught and dropped on this thread.
        continuation.resume(with: Result { try body() })
      }
      worker.name = "swift-mk-tests.blocking"
      worker.start()
    }
  }
}
