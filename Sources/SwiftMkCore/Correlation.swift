//
//  Correlation.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Correlation

/// The trace and span identifiers for one run, in the W3C shapes the go engine
/// and any OTLP collector use: a 32-hex-character trace id and a 16-hex-character
/// span id. swift-makefile cannot import the go logging library, so it mirrors
/// the same id scheme natively.
public struct Correlation: Sendable, Equatable {
  public let traceID: String
  public let spanID: String

  /// The environment variables that carry a run's trace and span across process
  /// boundaries, in the precedence order `fromEnvironment` reads them. The shell
  /// propagation (`Shell`) and the test suites drive their key sets from this one
  /// list; `exportCorrelation` and `fromEnvironment` reference the same keys by
  /// name, so a renamed or added key is a single, greppable change.
  public static let environmentKeys = [
    "TRACEPARENT", "TRACE_ID", "SPAN_ID", "SWIFT_MK_TRACE_ID", "SWIFT_MK_SPAN_ID",
  ]

  private static let traceByteCount = 16
  private static let spanByteCount = 8
  private static let traceHexLength = 32
  private static let spanHexLength = 16
  private static let flagsHexLength = 2
  private static let traceparentFieldCount = 4
  private static let traceparentVersion = "00"
  private static let sampledFlag = "01"

  /// A fresh trace with a new span.
  public static func new() -> Correlation {
    Correlation(
      traceID: randomHex(byteCount: traceByteCount),
      spanID: randomHex(byteCount: spanByteCount))
  }

  /// The W3C traceparent string for this correlation.
  public var traceparent: String {
    [Self.traceparentVersion, traceID, spanID, Self.sampledFlag].joined(separator: "-")
  }

  /// Adopt an inbound W3C traceparent, keeping its trace and span ids, or return
  /// nil when the value is malformed. Any well-formed two-hex trace-flags field is
  /// accepted (an unsampled `00` is valid W3C), and the outgoing `traceparent`
  /// normalizes the flags to `01`, so a valid inbound context is never dropped
  /// over the flag byte alone.
  public static func fromTraceparent(_ value: String) -> Correlation? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == traceparentFieldCount else {
      return nil
    }
    var fields = parts.makeIterator()
    guard let version = fields.next(), version == traceparentVersion,
      let trace = fields.next(), isLowerHex(trace, length: traceHexLength),
      let span = fields.next(), isLowerHex(span, length: spanHexLength),
      let flags = fields.next(), isLowerHex(flags, length: flagsHexLength)
    else {
      return nil
    }
    return Correlation(traceID: String(trace), spanID: String(span))
  }

  /// Resolve a run correlation from the environment. Adopt `TRACEPARENT` when it
  /// is well-formed, otherwise the canonical `TRACE_ID`/`SPAN_ID` pair, otherwise
  /// the `SWIFT_MK_TRACE_ID`/`SWIFT_MK_SPAN_ID` aliases, and return nil when none
  /// hold a valid value (unset or malformed) so the caller mints a fresh trace.
  /// The id pairs are the fallback a caller that exports only ids (not a full
  /// traceparent) provides, so every swift-mk child still joins the one run trace.
  /// The precedence matches the make bootstrap in scripts/swift-mk-trace.sh.
  public static func fromEnvironment() -> Correlation? {
    if let adopted = fromTraceparent(Env.get("TRACEPARENT")) {
      return adopted
    }
    if let adopted = fromIDs(traceID: Env.get("TRACE_ID"), spanID: Env.get("SPAN_ID")) {
      return adopted
    }
    return fromIDs(
      traceID: Env.get("SWIFT_MK_TRACE_ID"), spanID: Env.get("SWIFT_MK_SPAN_ID"))
  }

  /// Build a correlation from a raw trace/span id pair, or nil when either is not
  /// a well-formed lowercase-hex id of the expected length.
  public static func fromIDs(traceID: String, spanID: String) -> Correlation? {
    guard isLowerHex(Substring(traceID), length: traceHexLength),
      isLowerHex(Substring(spanID), length: spanHexLength)
    else {
      return nil
    }
    return Correlation(traceID: traceID, spanID: spanID)
  }

  private static func randomHex(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    var hex = ""
    for _ in 0..<byteCount {
      let byte = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
      hex += String(format: "%02x", byte)
    }
    return hex
  }

  private static func isLowerHex(_ value: Substring, length: Int) -> Bool {
    guard value.count == length else {
      return false
    }
    return value.allSatisfy { character in
      ("0"..."9").contains(character) || ("a"..."f").contains(character)
    }
  }
}
