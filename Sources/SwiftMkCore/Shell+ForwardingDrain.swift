//
//  Shell+ForwardingDrain.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkPipe

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension Shell {
  /// Time to wait for the drains to finish after the direct child exits before
  /// giving up and detaching. A descendant may keep an inherited write end open, so
  /// the reader may never see EOF; a blocked sink may keep the forwarder from
  /// flushing. Either way the wait is bounded and detach makes the drain inert.
  static let forwardingDrainGraceMilliseconds = 250

  static func waitForDirectProcess(
    _ process: Process,
    drains: [ForwardingDrain]
  ) -> Int32 {
    process.waitUntilExit()
    let status = process.terminationStatus
    let deadline =
      DispatchTime.now() + .milliseconds(forwardingDrainGraceMilliseconds)
    for drain in drains where !drain.waitUntilFinished(deadline: deadline) {
      // A drain did not finish within the grace: a descendant is holding the pipe
      // open, or a sink is blocked. Detach every drain so none can hang this caller
      // or write to a caller-owned sink after this returns, then stop waiting. The
      // captured bytes are whatever the reader accumulated before this point.
      for unfinishedDrain in drains {
        unfinishedDrain.detach()
      }
      break
    }
    return status
  }
}
