//
//  CorrelationTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - CorrelationTests

enum CorrelationTests {
  private static let traceID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  private static let spanID = "bbbbbbbbbbbbbbbb"

  @Test
  static func fromTraceparentPreservesIncomingSpan() throws {
    let traceparent = "00-\(traceID)-\(spanID)-01"

    let correlation = try #require(Correlation.fromTraceparent(traceparent))

    #expect(correlation.traceID == traceID)
    #expect(correlation.spanID == spanID)
    #expect(correlation.traceparent == traceparent)
  }

  @Test
  static func fromTraceparentAcceptsUnsampledFlagsAndNormalizes() throws {
    // An unsampled `00` flags field is valid W3C; it must be accepted and the
    // outgoing traceparent normalized to `01` rather than dropped.
    let correlation = try #require(Correlation.fromTraceparent("00-\(traceID)-\(spanID)-00"))

    #expect(correlation.traceID == traceID)
    #expect(correlation.spanID == spanID)
    #expect(correlation.traceparent == "00-\(traceID)-\(spanID)-01")
  }

  @Test
  static func fromTraceparentRejectsMalformedFlags() {
    // A one-character or non-hex flags field is not a valid traceparent.
    #expect(Correlation.fromTraceparent("00-\(traceID)-\(spanID)-1") == nil)
    #expect(Correlation.fromTraceparent("00-\(traceID)-\(spanID)-zz") == nil)
  }

  @Test
  static func fromIDsBuildsFromValidPairAndRejectsInvalid() throws {
    let correlation = try #require(Correlation.fromIDs(traceID: traceID, spanID: spanID))
    #expect(correlation.traceID == traceID)
    #expect(correlation.spanID == spanID)

    #expect(Correlation.fromIDs(traceID: "short", spanID: spanID) == nil)
    #expect(Correlation.fromIDs(traceID: traceID, spanID: "") == nil)
  }

  @Test
  static func allZeroIDsAreRejected() {
    // The all-zero trace-id and span-id are invalid per the W3C trace-context spec.
    let zeroTrace = String(repeating: "0", count: 32)
    let zeroSpan = String(repeating: "0", count: 16)
    #expect(Correlation.fromTraceparent("00-\(zeroTrace)-\(spanID)-01") == nil)
    #expect(Correlation.fromTraceparent("00-\(traceID)-\(zeroSpan)-01") == nil)
    #expect(Correlation.fromIDs(traceID: zeroTrace, spanID: spanID) == nil)
    #expect(Correlation.fromIDs(traceID: traceID, spanID: zeroSpan) == nil)
  }
}

// MARK: - CorrelationEnvironmentTests

/// `Correlation.fromEnvironment` reads process environment, so it is nested under
/// `EnvironmentSerialized` and restores the keys it touches; the parent's
/// `.serialized` trait keeps it from racing the other env-mutating suites.
extension EnvironmentSerialized {
  @Suite enum CorrelationEnvironmentTests {
    private static let traceID = "cccccccccccccccccccccccccccccccc"
    private static let spanID = "dddddddddddddddd"

    @Test
    static func fromEnvironmentAdoptsTraceparent() {
      let saved = save()
      defer { restore(saved) }
      clear()
      setenv("TRACEPARENT", "00-\(traceID)-\(spanID)-01", 1)

      let correlation = Correlation.fromEnvironment()

      #expect(correlation?.traceID == traceID)
      #expect(correlation?.spanID == spanID)
    }

    @Test
    static func fromEnvironmentAdoptsCanonicalIDPairWithoutTraceparent() {
      let saved = save()
      defer { restore(saved) }
      clear()
      setenv("TRACE_ID", traceID, 1)
      setenv("SPAN_ID", spanID, 1)

      let correlation = Correlation.fromEnvironment()

      #expect(correlation?.traceID == traceID)
      #expect(correlation?.spanID == spanID)
    }

    @Test
    static func fromEnvironmentAdoptsSwiftMkAliasPairAsLastResort() {
      let saved = save()
      defer { restore(saved) }
      clear()
      setenv("SWIFT_MK_TRACE_ID", traceID, 1)
      setenv("SWIFT_MK_SPAN_ID", spanID, 1)

      let correlation = Correlation.fromEnvironment()

      #expect(correlation?.traceID == traceID)
      #expect(correlation?.spanID == spanID)
    }

    @Test
    static func fromEnvironmentReturnsNilWhenNothingIsSet() {
      let saved = save()
      defer { restore(saved) }
      clear()

      #expect(Correlation.fromEnvironment() == nil)
    }

    private static func save() -> [String: String?] {
      var saved: [String: String?] = [:]
      for key in Correlation.environmentKeys {
        saved[key] = getenv(key).map { String(cString: $0) }
      }
      return saved
    }

    private static func clear() {
      for key in Correlation.environmentKeys {
        unsetenv(key)
      }
    }

    private static func restore(_ saved: [String: String?]) {
      for key in Correlation.environmentKeys {
        guard let savedValue = saved[key] else {
          unsetenv(key)
          continue
        }
        guard let value = savedValue else {
          unsetenv(key)
          continue
        }
        setenv(key, value, 1)
      }
    }
  }
}
