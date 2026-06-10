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
    // libc getenv, not ProcessInfo.environment: Foundation caches the
    // environment snapshot at first access, so an in-process setenv (the run
    // trace handoff, test setup) would read back stale through ProcessInfo.
    let value = getenv(name).map { String(cString: $0) } ?? ""
    return value.isEmpty ? fallback : value
  }

  /// Word-split on whitespace (approximation of shell word splitting).
  public static func words(_ text: String) -> [String] {
    text.split { $0 == " " || $0 == "\t" || $0 == "\n" }.map(String.init)
  }
}
