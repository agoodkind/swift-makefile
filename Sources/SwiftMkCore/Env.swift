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

  /// Split on unquoted whitespace, honoring single and double quotes and stripping
  /// them from the token, the way a POSIX shell tokenizes a command line. A consumer
  /// writes build settings as `KEY="value with spaces"`, which `words` would split on
  /// the inner space and leave the quotes on; this keeps `KEY=value with spaces` as one
  /// token with the quotes removed. Escapes are not interpreted, which is enough for the
  /// `KEY="value"` shape these settings use.
  public static func shellWords(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var inSingle = false
    var inDouble = false
    var started = false
    for character in text {
      if inSingle {
        if character == "'" {
          inSingle = false
        } else {
          current.append(character)
        }
        continue
      }
      if inDouble {
        if character == "\"" {
          inDouble = false
        } else {
          current.append(character)
        }
        continue
      }
      switch character {
      case "'":
        inSingle = true
        started = true
      case "\"":
        inDouble = true
        started = true
      case " ", "\t", "\n":
        if started {
          tokens.append(current)
          current = ""
          started = false
        }
      default:
        current.append(character)
        started = true
      }
    }
    if started {
      tokens.append(current)
    }
    return tokens
  }
}
