//
//  EnvTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - EnvTests

/// Covers `Env.shellWords`, the shell tokenizer the coverage build uses to read a
/// consumer's forwarded `SWIFT_XCODE_BUILD_SETTINGS`, where a `KEY="value with spaces"`
/// pair must stay one token with the quotes removed.
@Suite(.serialized)
enum EnvTests {
  @Test
  static func shellWordsSplitsUnquotedTokensOnWhitespace() {
    #expect(Env.shellWords("A=1 B=2\tC=3") == ["A=1", "B=2", "C=3"])
  }

  @Test
  static func shellWordsKeepsADoubleQuotedValueWithSpacesAsOneToken() {
    #expect(
      Env.shellWords("NAME=\"Fan Curve Hardware Helper\"")
        == ["NAME=Fan Curve Hardware Helper"])
  }

  @Test
  static func shellWordsStripsQuotesFromAValueWithNoSpaces() {
    #expect(
      Env.shellWords("URL=\"https://example.com/appcast.xml\"")
        == ["URL=https://example.com/appcast.xml"])
  }

  @Test
  static func shellWordsHandlesMultipleQuotedAndUnquotedPairs() {
    #expect(
      Env.shellWords("ID=io.example.app NAME=\"My App\" FLAG=YES")
        == ["ID=io.example.app", "NAME=My App", "FLAG=YES"])
  }

  @Test
  static func shellWordsHandlesSingleQuotes() {
    #expect(Env.shellWords("NAME='My App'") == ["NAME=My App"])
  }

  @Test
  static func shellWordsKeepsAnEmptyQuotedValueAsAToken() {
    // An explicitly empty value (KEY="") is a real token, not dropped, so a setting
    // that clears a value survives tokenization.
    #expect(Env.shellWords("KEY=\"\"") == ["KEY="])
  }

  @Test
  static func shellWordsIsEmptyForBlankInput() {
    #expect(Env.shellWords("").isEmpty)
    #expect(Env.shellWords("   \t  ").isEmpty)
  }
}
