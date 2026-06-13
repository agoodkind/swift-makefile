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

private let baselineKeyTestColumn = 3
private let baselineKeyTestFile = "/repo/Sources/App/Worker.swift"

private func swiftlintFinding(
  ruleId: String,
  line: Int,
  file: String = baselineKeyTestFile,
  message: String = "violation"
) -> Finding {
  Finding(
    tool: "swiftlint",
    ruleId: ruleId,
    file: file,
    line: line,
    column: baselineKeyTestColumn,
    severity: .warning,
    message: message
  )
}

@Test
func contentKeyIncludesNormalizedOffendingLine() {
  let finding = swiftlintFinding(ruleId: "identifier_name", line: 12)
  let key = BaselineKey.of(finding) { _, _ in "    let x = foo(  a,   b )  " }

  #expect(key == "/repo/sources/app/worker.swift\tidentifier_name\tlet x = foo( a, b )")
}

@Test
func contentKeyIgnoresLineMoveAndMessageDriftWhenSourceLineIsStable() {
  let firstFinding = swiftlintFinding(
    ruleId: "cyclomatic_complexity", line: 12, message: "complexity is 11")
  let secondFinding = swiftlintFinding(
    ruleId: "cyclomatic_complexity", line: 48, message: "complexity is 14")
  let sameLine: (String, Int) -> String? = { _, _ in "func handle(request: Request) {" }

  #expect(
    BaselineKey.of(firstFinding, readLine: sameLine)
      == BaselineKey.of(secondFinding, readLine: sameLine))
}

@Test
func contentKeyIgnoresReindentAndInnerSpacingChange() {
  let original = swiftlintFinding(ruleId: "line_length", line: 12)
  let reflowed = swiftlintFinding(ruleId: "line_length", line: 12)

  let originalKey = BaselineKey.of(original) { _, _ in
    "        guard let value = lookup(key)  else {"
  }
  let reflowedKey = BaselineKey.of(reflowed) { _, _ in "guard let value = lookup(key) else {" }

  #expect(originalKey == reflowedKey)
}

@Test
func contentKeyChangesWhenLineTokensAreEdited() {
  let before = swiftlintFinding(ruleId: "line_length", line: 12)
  let after = swiftlintFinding(ruleId: "line_length", line: 12)

  let beforeKey = BaselineKey.of(before) { _, _ in "let total = price * quantity" }
  let afterKey = BaselineKey.of(after) { _, _ in "let total = price * quantity * taxRate" }

  #expect(beforeKey != afterKey)
}

@Test
func contentKeyIncludesRuleIdEvenWithIdenticalLine() {
  let firstFinding = swiftlintFinding(ruleId: "identifier_name", line: 12)
  let secondFinding = swiftlintFinding(ruleId: "type_name", line: 12)
  let sameLine: (String, Int) -> String? = { _, _ in "struct X {" }

  #expect(
    BaselineKey.of(firstFinding, readLine: sameLine)
      != BaselineKey.of(secondFinding, readLine: sameLine))
}

@Test
func contentKeyCaseFoldsFilePath() {
  let firstFinding = swiftlintFinding(
    ruleId: "identifier_name", line: 12, file: "Sources/Installer/X.swift")
  let secondFinding = swiftlintFinding(
    ruleId: "identifier_name", line: 12, file: "Sources/installer/X.swift")
  let sameLine: (String, Int) -> String? = { _, _ in "let a = 1" }

  #expect(
    BaselineKey.of(firstFinding, readLine: sameLine)
      == BaselineKey.of(secondFinding, readLine: sameLine))
}

@Test
func fileScopedRulesKeepRuleKeyWithoutLineText() {
  for rule in ["file_length", "file_name", "file_header"] {
    let finding = swiftlintFinding(ruleId: rule, line: 1)
    let key = BaselineKey.of(finding) { _, _ in "// should be ignored for file-scoped rules" }
    #expect(key == "/repo/sources/app/worker.swift\t\(rule)")
  }
}

@Test
func unreadableLineFallsBackToRuleKey() {
  let nilLine = swiftlintFinding(ruleId: "identifier_name", line: 12)
  let blankLine = swiftlintFinding(ruleId: "identifier_name", line: 12)

  let nilKey = BaselineKey.of(nilLine) { _, _ in nil }
  let blankKey = BaselineKey.of(blankLine) { _, _ in "   \t  " }

  #expect(nilKey == "/repo/sources/app/worker.swift\tidentifier_name")
  #expect(blankKey == "/repo/sources/app/worker.swift\tidentifier_name")
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
