//
//  BaselineMigrationRunner.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - BaselineMigrationRunner

public enum BaselineMigrationRunner {
  public struct Outcome: Sendable {
    public let label: String
    public let migrated: Int
    public let jsonlPath: String
  }

  private struct Tool: Sendable {
    let label: String
    let baselineEnv: String
    let defaultTxtPath: String
  }

  private static let textSuffix = ".txt"
  private static let jsonlSuffix = ".jsonl"

  private static let swiftlintDefaultTxtPath = ".swiftlint-baseline.txt"
  private static let swiftlintComplexityDefaultTxtPath =
    ".swiftlint-complexity-baseline.txt"
  private static let swiftcheckExtraDefaultTxtPath =
    ".swiftcheck-extra-baseline.txt"
  private static let peripheryDefaultTxtPath = ".periphery-baseline.txt"

  private static let textTools = [
    Tool(
      label: "swiftlint",
      baselineEnv: "SWIFTLINT_BASELINE",
      defaultTxtPath: swiftlintDefaultTxtPath
    ),
    Tool(
      label: "swiftlint-complexity",
      baselineEnv: "SWIFTLINT_COMPLEXITY_BASELINE",
      defaultTxtPath: swiftlintComplexityDefaultTxtPath
    ),
    Tool(
      label: "swiftcheck-extra",
      baselineEnv: "SWIFTCHECK_EXTRA_BASELINE",
      defaultTxtPath: swiftcheckExtraDefaultTxtPath
    ),
    Tool(
      label: "periphery",
      baselineEnv: "PERIPHERY_BASELINE",
      defaultTxtPath: peripheryDefaultTxtPath
    ),
  ]

  @discardableResult
  public static func migrateOne(
    label: String,
    txtPath: String,
    jsonlPath: String,
    context: PathContext = PathContext.current()
  ) throws -> Outcome {
    guard FileManager.default.fileExists(atPath: txtPath) else {
      return Outcome(label: label, migrated: 0, jsonlPath: jsonlPath)
    }

    do {
      let lines = Text.readLines(txtPath)
      let records = try BaselineMigration.recordsFromTextBaseline(
        label: label,
        lines: lines
      )
      let currentFindings = try captureCurrentFindings(label: label, context: context)
      let now = Baseline.iso8601Now()
      let migratedRecords = recordsForMigration(
        oldRecords: records,
        current: currentFindings,
        now: now
      )
      try BaselineStore.write(migratedRecords, to: jsonlPath)
      try FileManager.default.removeItem(atPath: txtPath)
      return Outcome(label: label, migrated: migratedRecords.count, jsonlPath: jsonlPath)
    } catch {
      Output.error(
        "baseline-migrate: could not migrate \(label) from \(txtPath) "
          + "to \(jsonlPath): \(error)"
      )
      throw error
    }
  }

  public static func migrateTextTools() throws -> [Outcome] {
    var outcomes: [Outcome] = []
    let context = PathContext.current()
    for tool in textTools {
      let txtPath = configuredTxtPath(for: tool)
      let jsonlPath = structuredPath(from: txtPath)
      outcomes.append(
        try migrateOne(
          label: tool.label,
          txtPath: txtPath,
          jsonlPath: jsonlPath,
          context: context
        )
      )
    }
    return outcomes
  }

  static func recordsForMigration(
    oldRecords: [BaselineRecord],
    current: [Finding],
    now: String
  ) -> [BaselineRecord] {
    var oldKeys = Set<String>()
    var firstAddedByKey: [String: String] = [:]
    for record in oldRecords {
      oldKeys.insert(record.key)
      guard let existingFirstAdded = firstAddedByKey[record.key] else {
        firstAddedByKey[record.key] = record.firstAdded
        continue
      }
      if record.firstAdded < existingFirstAdded {
        firstAddedByKey[record.key] = record.firstAdded
      }
    }

    var migratedRecords: [BaselineRecord] = []
    for finding in current {
      let key = BaselineKey.of(finding)
      guard oldKeys.contains(key) else {
        continue
      }
      migratedRecords.append(
        BaselineRecord.from(
          finding,
          firstAdded: firstAddedByKey[key] ?? now,
          lastSeen: now
        )
      )
    }
    return migratedRecords
  }

  private static func captureCurrentFindings(
    label: String,
    context: PathContext
  ) throws -> [Finding] {
    prepareCurrentCapture(label: label, context: context)
    Capture.ensureMakeDir()
    let rawPath = ".make/\(label)-baseline.raw.out"
    let findingsPath = ".make/\(label)-baseline.out"
    return try BaselineRunner.captureStructuredFindings(
      label: label,
      rawPath: rawPath,
      findingsPath: findingsPath,
      context: context
    )
  }

  private static func prepareCurrentCapture(label: String, context: PathContext) {
    switch label {
    case "swiftlint", "swiftlint-complexity", "periphery":
      _ = Lint.runTools(context: context)
    case "swiftcheck-extra":
      _ = Swiftcheck.resolveBin()
    default:
      break
    }
  }

  private static func configuredTxtPath(for tool: Tool) -> String {
    let configuredPath = Env.get(tool.baselineEnv)
    guard configuredPath.hasSuffix(textSuffix) else {
      return tool.defaultTxtPath
    }
    return configuredPath
  }

  private static func structuredPath(from txtPath: String) -> String {
    guard txtPath.hasSuffix(textSuffix) else {
      return txtPath + jsonlSuffix
    }
    return String(txtPath.dropLast(textSuffix.count)) + jsonlSuffix
  }
}
