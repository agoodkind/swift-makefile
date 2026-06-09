//
//  BaselineKeyTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - BaselineKeyTests

enum BaselineKeyTests {}

@Test
func swiftlintKeyIgnoresLocationAndMessageDrift() {
  let firstFinding = Finding(
    tool: "swiftlint",
    ruleId: "cyclomatic_complexity",
    file: "/repo/Sources/App/Worker.swift",
    line: 12,
    column: 3,
    severity: .warning,
    message: "Cyclomatic complexity is 11"
  )
  let secondFinding = Finding(
    tool: "swiftlint",
    ruleId: "cyclomatic_complexity",
    file: "/repo/Sources/App/Worker.swift",
    line: 48,
    column: 7,
    severity: .warning,
    message: "Cyclomatic complexity is 14"
  )

  #expect(BaselineKey.of(firstFinding) == BaselineKey.of(secondFinding))
}

@Test
func swiftlintKeyIncludesRuleId() {
  let firstFinding = Finding(
    tool: "swiftlint",
    ruleId: "identifier_name",
    file: "/repo/Sources/App/Worker.swift",
    line: 12,
    column: 3,
    severity: .warning,
    message: "Identifier name should be longer"
  )
  let secondFinding = Finding(
    tool: "swiftlint",
    ruleId: "type_name",
    file: "/repo/Sources/App/Worker.swift",
    line: 12,
    column: 3,
    severity: .warning,
    message: "Type name should be longer"
  )

  #expect(BaselineKey.of(firstFinding) != BaselineKey.of(secondFinding))
}

@Test
func swiftlintKeyCaseFoldsFilePath() {
  let firstFinding = Finding(
    tool: "swiftlint",
    ruleId: "identifier_name",
    file: "Sources/Installer/X.swift",
    line: 12,
    column: 3,
    severity: .warning,
    message: "Identifier name should be longer"
  )
  let secondFinding = Finding(
    tool: "swiftlint",
    ruleId: "identifier_name",
    file: "Sources/installer/X.swift",
    line: 12,
    column: 3,
    severity: .warning,
    message: "Identifier name should be longer"
  )

  #expect(BaselineKey.of(firstFinding) == BaselineKey.of(secondFinding))
}

@Test
func peripheryKeyUsesSymbolWhenPresent() {
  let firstFinding = Finding(
    tool: "periphery",
    ruleId: "class",
    file: "/repo/Sources/App/Foo.swift",
    line: 10,
    column: 1,
    severity: .warning,
    message: "Foo",
    usr: "s:3App3FooC",
    symbol: "Foo"
  )
  let secondFinding = Finding(
    tool: "periphery",
    ruleId: "class",
    file: "/repo/Sources/App/Foo.swift",
    line: 10,
    column: 1,
    severity: .warning,
    message: "Bar",
    usr: "s:3App3BarC",
    symbol: "Bar"
  )
  let movedFinding = Finding(
    tool: "periphery",
    ruleId: "class",
    file: "/repo/Sources/App/Foo.swift",
    line: 42,
    column: 9,
    severity: .warning,
    message: "Foo moved",
    usr: "s:3App3FooC",
    symbol: "Foo"
  )
  let differentUsrFinding = Finding(
    tool: "periphery",
    ruleId: "class",
    file: "/repo/Sources/App/Foo.swift",
    line: 10,
    column: 1,
    severity: .warning,
    message: "Foo",
    usr: "s:3App3RenamedFooC",
    symbol: "Foo"
  )

  #expect(BaselineKey.of(firstFinding) == "/repo/sources/app/foo.swift\tFoo")
  #expect(BaselineKey.of(firstFinding) != BaselineKey.of(secondFinding))
  #expect(BaselineKey.of(firstFinding) == BaselineKey.of(movedFinding))
  #expect(BaselineKey.of(firstFinding) == BaselineKey.of(differentUsrFinding))
}

@Test
func peripheryKeyUsesRuleIdWhenSymbolIsMissing() {
  let symbolFinding = Finding(
    tool: "periphery",
    ruleId: "function",
    file: "/repo/Sources/App/Foo.swift",
    line: 10,
    column: 1,
    severity: .warning,
    message: "doWork()",
    symbol: "doWork()"
  )
  let fallbackFinding = Finding(
    tool: "periphery",
    ruleId: "function",
    file: "/repo/Sources/App/Foo.swift",
    line: 10,
    column: 1,
    severity: .warning,
    message: "Unnamed function"
  )

  #expect(BaselineKey.of(symbolFinding) == "/repo/sources/app/foo.swift\tdoWork()")
  #expect(BaselineKey.of(fallbackFinding) == "/repo/sources/app/foo.swift\tfunction")
}
