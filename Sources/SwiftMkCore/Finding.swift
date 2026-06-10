//
//  Finding.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Finding

public struct Finding: Sendable, Equatable {
  public enum Severity: String, Sendable {
    case error
    case warning
  }

  public let tool: String
  public let ruleId: String
  public let file: String
  public let line: Int
  public let column: Int
  public let severity: Severity
  public let message: String
  public let usr: String?
  public let symbol: String?
  public let hints: [String]

  public init(
    tool: String,
    ruleId: String,
    file: String,
    line: Int,
    column: Int,
    severity: Severity,
    message: String,
    usr: String? = nil,
    symbol: String? = nil,
    hints: [String] = []
  ) {
    self.tool = tool
    self.ruleId = ruleId
    self.file = file
    self.line = line
    self.column = column
    self.severity = severity
    self.message = message
    self.usr = usr
    self.symbol = symbol
    self.hints = hints
  }

  // MARK: - JSON Decoding

  public static func fromSwiftlintJSON(_ data: Data) throws -> [Finding] {
    let payloads = try JSONDecoder().decode([SwiftlintPayload].self, from: data)
    return try payloads.map { try $0.finding() }
  }

  public static func fromPeripheryJSON(_ data: Data) throws -> [Finding] {
    let payloads = try JSONDecoder().decode([PeripheryPayload].self, from: data)
    return payloads.map { $0.finding() }
  }
}

// MARK: - SwiftlintPayload

private struct SwiftlintPayload: Decodable {
  // swiftlint emits `"character": null` for whole-file rules (file_name,
  // file_header), so the column must decode as optional.
  let column: Int?
  let file: String
  let line: Int
  let message: String
  let ruleId: String
  let severity: String

  enum CodingKeys: String, CodingKey {
    case column = "character"
    case file
    case line
    case message = "reason"
    case ruleId = "rule_id"
    case severity
  }

  func finding() throws -> Finding {
    guard let findingSeverity = Finding.Severity(rawValue: severity.lowercased()) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: [CodingKeys.severity],
          debugDescription: "Unsupported swiftlint severity: \(severity)"
        )
      )
    }

    return Finding(
      tool: "swiftlint",
      ruleId: ruleId,
      file: file,
      line: line,
      column: column ?? 0,
      severity: findingSeverity,
      message: message
    )
  }
}

// MARK: - PeripheryPayload

private struct PeripheryPayload: Decodable {
  let kind: String
  let name: String
  let ids: [String]
  let hints: [String]
  let location: String

  func finding() -> Finding {
    let parsedLocation = PeripheryLocation(location)
    let findingMessage: String
    if hints.isEmpty {
      findingMessage = name
    } else {
      findingMessage = "\(name) (\(hints.joined(separator: ", ")))"
    }

    return Finding(
      tool: "periphery",
      ruleId: kind,
      file: parsedLocation.file,
      line: parsedLocation.line,
      column: parsedLocation.column,
      severity: .warning,
      message: findingMessage,
      usr: ids.first,
      symbol: name,
      hints: hints
    )
  }
}

// MARK: - PeripheryLocation

private struct PeripheryLocation {
  let file: String
  let line: Int
  let column: Int

  init(_ location: String) {
    guard let columnSeparator = location.lastIndex(of: ":") else {
      self.file = location
      self.line = 0
      self.column = 0
      return
    }

    let columnText = String(location[location.index(after: columnSeparator)...])
    let beforeColumn = location[..<columnSeparator]
    guard let lineSeparator = beforeColumn.lastIndex(of: ":") else {
      self.file = location
      self.line = 0
      self.column = 0
      return
    }

    let lineText = String(beforeColumn[beforeColumn.index(after: lineSeparator)...])
    self.file = String(beforeColumn[..<lineSeparator])
    self.line = Int(lineText) ?? 0
    self.column = Int(columnText) ?? 0
  }
}
