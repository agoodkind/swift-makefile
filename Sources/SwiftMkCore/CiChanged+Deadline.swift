//
//  CiChanged+Deadline.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - CiChanged detector deadline

extension CiChanged {
  /// Overall wall-clock bound on the whole detector. The detector's git calls and build
  /// graph read are each unbounded (only the SwiftPM describe has its own timeout), so a
  /// hung git operation or a stalled resolve on a cold consumer could wedge the changes job
  /// to its 60-minute limit with no classification and, on the live view, no output. A
  /// generated-project consumer that never reaches describe has no timeout at all on that
  /// path. This deadline caps the whole run and fails safe to a full CI run, which is safe
  /// and self-corrects on the next run.
  private static let detectorDeadlineSeconds: Double = 90

  /// Run `decide` bounded by `detectorDeadlineSeconds`. `decide` runs on a background queue;
  /// if it does not finish by the deadline, the detector abandons it and returns a full-run
  /// decision, so no single unbounded call can wedge the job. The abandoned `decide` keeps
  /// running with whatever git subprocess it was blocked in, and `run` returns and the
  /// process exits, which orphans that subprocess rather than killing it. That is safe here:
  /// the detector runs only in the ephemeral `changes` job container, which is torn down at
  /// job end and takes the orphan with it, and the downstream gates run on separate runners
  /// with fresh checkouts, so the orphan cannot touch their git state. The classification is
  /// already decided (a full run), so the orphan's outcome no longer matters. The wait is a
  /// `DispatchGroup` timeout, so there is no sleep.
  static func decideWithinDeadline() -> Decision {
    let group = DispatchGroup()
    let holder = DecisionHolder()
    group.enter()
    DispatchQueue.global().async {
      holder.store(decide())
      group.leave()
    }
    if group.wait(timeout: .now() + detectorDeadlineSeconds) == .timedOut {
      Output.report(
        "ci-changed: detector exceeded \(Int(detectorDeadlineSeconds))s; running full CI")
      return fullRunDecision(reason: "detector exceeded \(Int(detectorDeadlineSeconds))s")
    }
    return holder.load()
  }
}

// MARK: - DecisionHolder

/// A lock-guarded box that carries the `decide` result from the background deadline queue
/// back to `decideWithinDeadline`. It defaults to a full run, so a read before a store fails
/// safe; an `NSLock` guards every access, which makes the unchecked `Sendable` conformance
/// sound.
private final class DecisionHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var decision = CiChanged.Decision(
    families: CiChanged.allGateFamilies, reason: "detector did not complete")

  func store(_ value: CiChanged.Decision) {
    lock.lock()
    defer { lock.unlock() }
    decision = value
  }

  func load() -> CiChanged.Decision {
    lock.lock()
    defer { lock.unlock() }
    return decision
  }
}
