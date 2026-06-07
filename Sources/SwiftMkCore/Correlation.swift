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

  private static let traceByteCount = 16
  private static let spanByteCount = 8
  private static let traceHexLength = 32
  private static let spanHexLength = 16
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

  /// Adopt an inbound W3C traceparent, keeping its trace id and minting a fresh
  /// child span, or return nil when the value is malformed.
  public static func fromTraceparent(_ value: String) -> Correlation? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == traceparentFieldCount else {
      return nil
    }
    var fields = parts.makeIterator()
    guard let version = fields.next(), version == traceparentVersion,
      let trace = fields.next(), isLowerHex(trace, length: traceHexLength),
      let span = fields.next(), isLowerHex(span, length: spanHexLength)
    else {
      return nil
    }
    return Correlation(traceID: String(trace), spanID: randomHex(byteCount: spanByteCount))
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
