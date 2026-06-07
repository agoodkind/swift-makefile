//
//  Env.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Env

/// Environment access with `${VAR:-default}` semantics: a default substitutes
/// for an unset or empty value.
public enum Env {
  public static func get(_ name: String, _ fallback: String = "") -> String {
    let value = ProcessInfo.processInfo.environment[name] ?? ""
    return value.isEmpty ? fallback : value
  }

  /// Word-split on whitespace (approximation of shell word splitting).
  public static func words(_ text: String) -> [String] {
    text.split { $0 == " " || $0 == "\t" || $0 == "\n" }.map(String.init)
  }
}
