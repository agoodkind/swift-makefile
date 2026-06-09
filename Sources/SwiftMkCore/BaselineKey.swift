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
      if let usr = finding.usr, !usr.isEmpty {
        return "\(finding.file)\t\(usr)"
      }

      return "\(finding.file)\t\(finding.ruleId)\t\(finding.symbol ?? "")"
    }

    return "\(finding.file)\t\(finding.ruleId)"
  }
}
