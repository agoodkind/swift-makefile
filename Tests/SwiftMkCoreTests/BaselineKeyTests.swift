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
func peripheryKeyUsesUsrWhenPresent() {
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

  #expect(BaselineKey.of(firstFinding) == "/repo/Sources/App/Foo.swift\ts:3App3FooC")
  #expect(BaselineKey.of(firstFinding) != BaselineKey.of(secondFinding))
  #expect(BaselineKey.of(firstFinding) == BaselineKey.of(movedFinding))
}

@Test
func peripheryKeyFallsBackToRuleIdAndSymbolWithoutUsr() {
  let firstFinding = Finding(
    tool: "periphery",
    ruleId: "function",
    file: "/repo/Sources/App/Foo.swift",
    line: 10,
    column: 1,
    severity: .warning,
    message: "doWork()",
    symbol: "doWork()"
  )
  let movedFinding = Finding(
    tool: "periphery",
    ruleId: "function",
    file: "/repo/Sources/App/Foo.swift",
    line: 44,
    column: 5,
    severity: .warning,
    message: "doWork() moved",
    symbol: "doWork()"
  )

  #expect(BaselineKey.of(firstFinding) == "/repo/Sources/App/Foo.swift\tfunction\tdoWork()")
  #expect(BaselineKey.of(firstFinding) == BaselineKey.of(movedFinding))
}
