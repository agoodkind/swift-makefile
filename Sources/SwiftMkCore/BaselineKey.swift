//
//  BaselineKey.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

// MARK: - BaselineKey

public enum BaselineKey {
  public static func of(_ finding: Finding) -> String {
    if finding.tool == "periphery" {
      return "\(finding.file)\t\(finding.symbol ?? finding.ruleId)"
    }

    return "\(finding.file)\t\(finding.ruleId)"
  }
}
