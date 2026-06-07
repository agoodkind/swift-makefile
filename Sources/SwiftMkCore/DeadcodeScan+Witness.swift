//
//  DeadcodeScan+Witness.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - DeadcodeScan witness filtering

extension DeadcodeScan {
  /// Remove protocol-witness false positives from periphery's output using the
  /// same index store periphery scanned. A method that satisfies a protocol
  /// requirement and is called only through the protocol has no direct reference,
  /// so periphery reports it unused; the index shows the requirement is referenced,
  /// so the finding is dropped. On any read error the original output is kept, so
  /// the filter never hides a real finding.
  static func filterWitnessFalsePositives(
    _ output: String,
    indexStore: String
  ) -> String {
    do {
      let result = try WitnessFilter.apply(
        toCombinedOutput: output, indexStorePath: indexStore)
      guard !result.dropped.isEmpty else {
        return result.text
      }
      Output.info(
        "deadcode: dropped \(result.dropped.count) protocol-witness false "
          + "positive(s) reached only through their protocol")
      for finding in result.dropped {
        Output.debug(
          "deadcode: witness retained \(finding.name) at "
            + "\(finding.file):\(finding.line)")
      }
      return result.text
    } catch {
      Output.error("deadcode: witness filter skipped, keeping all findings: \(error)")
      return output
    }
  }
}
