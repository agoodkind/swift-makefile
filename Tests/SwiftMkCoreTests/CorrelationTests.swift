//
//  CorrelationTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-06.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - CorrelationTests

enum CorrelationTests {
  @Test
  static func fromTraceparentPreservesIncomingSpan() throws {
    let traceID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let spanID = "bbbbbbbbbbbbbbbb"
    let traceparent = "00-\(traceID)-\(spanID)-01"

    let correlation = try #require(Correlation.fromTraceparent(traceparent))

    #expect(correlation.traceID == traceID)
    #expect(correlation.spanID == spanID)
    #expect(correlation.traceparent == traceparent)
  }
}
