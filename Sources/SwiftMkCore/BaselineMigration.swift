//
//  BaselineMigration.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - BaselineMigration

public enum BaselineMigration {
  public enum MigrationError: Error, Equatable {
    case unparsableLine(String)
    case unsupportedTool(String)
  }

  private enum ToolShape {
    case periphery
    case swiftcheckExtra
    case swiftlint
  }

  private struct LocatedFinding {
    let file: String
    let line: Int
    let column: Int
    let rest: String
  }

  private struct ParsedBaselineLine {
    let findingText: String
    let firstAdded: String
    let lastSeen: String
  }

  private static var locationPattern: Regex<Substring> { /:[0-9]+:[0-9]+:/ }
  private static let keyValueFieldCount = 2
  private static let locationFieldCount = 2
  private static let peripheryTool = "periphery"
  private static let swiftlintTool = "swiftlint"
  private static let swiftcheckExtraTool = "swiftcheck-extra"

  public static func recordsFromTextBaseline(
    label: String,
    lines: [String]
  ) throws -> [BaselineRecord] {
    let toolShape = try toolShape(for: label)
    var records: [BaselineRecord] = []

    for line in lines {
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        continue
      }
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
        continue
      }

      let parsedLine = splitMetadata(line, label: label)
      let locatedFinding = try parseLocatedFinding(parsedLine.findingText)
      let finding = try finding(
        from: locatedFinding,
        toolShape: toolShape,
        originalLine: parsedLine.findingText
      )
      let record = BaselineRecord(
        tool: finding.tool,
        rule: finding.ruleId,
        file: finding.file,
        key: BaselineKey.of(finding),
        display: parsedLine.findingText,
        firstAdded: parsedLine.firstAdded,
        lastSeen: parsedLine.lastSeen
      )
      records.append(record)
    }

    return records
  }

  private static func toolShape(for label: String) throws -> ToolShape {
    switch label {
    case peripheryTool:
      return .periphery
    case "swiftlint", "swiftlint-complexity":
      return .swiftlint
    case swiftcheckExtraTool:
      return .swiftcheckExtra
    default:
      throw MigrationError.unsupportedTool(label)
    }
  }

  private static func splitMetadata(
    _ line: String,
    label: String
  ) -> ParsedBaselineLine {
    let marker = "\t# \(label):"
    guard let markerRange = line.range(of: marker) else {
      return ParsedBaselineLine(findingText: line, firstAdded: "", lastSeen: "")
    }

    let findingText = String(line[line.startIndex..<markerRange.lowerBound])
    let metadata = String(line[markerRange.upperBound...])
    let fields = metadataFields(metadata)
    return ParsedBaselineLine(
      findingText: findingText,
      firstAdded: fields["first_added"] ?? "",
      lastSeen: fields["last_seen"] ?? ""
    )
  }

  private static func metadataFields(_ metadata: String) -> [String: String] {
    var fields: [String: String] = [:]
    for field in metadata.split(whereSeparator: { $0.isWhitespace }) {
      let parts = field.split(
        separator: "=",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      if parts.count != keyValueFieldCount {
        continue
      }
      fields[String(parts[0])] = String(parts[1])
    }
    return fields
  }

  private static func parseLocatedFinding(_ text: String) throws -> LocatedFinding {
    guard let locationRange = text.firstRange(of: locationPattern) else {
      throw MigrationError.unparsableLine(text)
    }

    let file = String(text[text.startIndex..<locationRange.lowerBound])
    let coordinateText = text[locationRange].split(separator: ":")
    guard coordinateText.count == locationFieldCount,
      let line = Int(coordinateText[0]),
      let column = Int(coordinateText[1])
    else {
      throw MigrationError.unparsableLine(text)
    }

    var rest = String(text[locationRange.upperBound...])
    if rest.hasPrefix(" ") {
      rest.removeFirst()
    }

    return LocatedFinding(file: file, line: line, column: column, rest: rest)
  }

  private static func finding(
    from locatedFinding: LocatedFinding,
    toolShape: ToolShape,
    originalLine: String
  ) throws -> Finding {
    switch toolShape {
    case .periphery:
      return try peripheryFinding(from: locatedFinding, originalLine: originalLine)
    case .swiftlint:
      return try swiftlintFinding(from: locatedFinding, originalLine: originalLine)
    case .swiftcheckExtra:
      return try swiftcheckExtraFinding(from: locatedFinding, originalLine: originalLine)
    }
  }

  private static func swiftlintFinding(
    from locatedFinding: LocatedFinding,
    originalLine: String
  ) throws -> Finding {
    guard let ruleId = lastParenthesizedToken(in: locatedFinding.rest) else {
      throw MigrationError.unparsableLine(originalLine)
    }
    let severity: Finding.Severity
    if locatedFinding.rest.hasPrefix("error:") {
      severity = .error
    } else {
      severity = .warning
    }

    return Finding(
      tool: swiftlintTool,
      ruleId: ruleId,
      file: locatedFinding.file,
      line: locatedFinding.line,
      column: locatedFinding.column,
      severity: severity,
      message: locatedFinding.rest
    )
  }

  private static func peripheryFinding(
    from locatedFinding: LocatedFinding,
    originalLine: String
  ) throws -> Finding {
    guard let symbol = firstSingleQuotedToken(in: locatedFinding.rest) else {
      throw MigrationError.unparsableLine(originalLine)
    }

    return Finding(
      tool: peripheryTool,
      ruleId: "",
      file: locatedFinding.file,
      line: locatedFinding.line,
      column: locatedFinding.column,
      severity: .warning,
      message: locatedFinding.rest,
      usr: nil,
      symbol: symbol
    )
  }

  private static func swiftcheckExtraFinding(
    from locatedFinding: LocatedFinding,
    originalLine: String
  ) throws -> Finding {
    guard let separatorRange = locatedFinding.rest.range(of: ": ") else {
      throw MigrationError.unparsableLine(originalLine)
    }

    return Finding(
      tool: swiftcheckExtraTool,
      ruleId: String(locatedFinding.rest[..<separatorRange.lowerBound]),
      file: locatedFinding.file,
      line: locatedFinding.line,
      column: locatedFinding.column,
      severity: .warning,
      message: locatedFinding.rest
    )
  }

  private static func firstSingleQuotedToken(in text: String) -> String? {
    guard let openIndex = text.firstIndex(of: "'") else {
      return nil
    }

    let tokenStart = text.index(after: openIndex)
    guard let closeIndex = text[tokenStart...].firstIndex(of: "'") else {
      return nil
    }

    return String(text[tokenStart..<closeIndex])
  }

  private static func lastParenthesizedToken(in text: String) -> String? {
    var token: String?
    var searchIndex = text.startIndex

    while let openIndex = text[searchIndex...].firstIndex(of: "(") {
      let tokenStart = text.index(after: openIndex)
      guard let closeIndex = text[tokenStart...].firstIndex(of: ")") else {
        break
      }

      token = String(text[tokenStart..<closeIndex])
      searchIndex = text.index(after: closeIndex)
    }

    return token
  }
}
