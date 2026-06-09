//
//  BaselineRecord.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - BaselineRecord

public struct BaselineRecord: Codable, Sendable, Equatable {
  public let tool: String
  public let rule: String
  public let file: String
  public let key: String
  public let display: String
  public let firstAdded: String
  public let lastSeen: String

  enum CodingKeys: String, CodingKey {
    case tool
    case rule
    case file
    case key
    case display
    case firstAdded = "first_added"
    case lastSeen = "last_seen"
  }

  public init(
    tool: String,
    rule: String,
    file: String,
    key: String,
    display: String,
    firstAdded: String,
    lastSeen: String
  ) {
    self.tool = tool
    self.rule = rule
    self.file = file
    self.key = key
    self.display = display
    self.firstAdded = firstAdded
    self.lastSeen = lastSeen
  }

  public static func from(
    _ finding: Finding,
    firstAdded: String,
    lastSeen: String
  ) -> BaselineRecord {
    BaselineRecord(
      tool: finding.tool,
      rule: finding.ruleId,
      file: finding.file,
      key: BaselineKey.of(finding),
      display: "\(finding.file):\(finding.line):\(finding.column): \(finding.message)",
      firstAdded: firstAdded,
      lastSeen: lastSeen
    )
  }
}

// MARK: - BaselineStore

public enum BaselineStore {
  public static func parse(_ text: String) throws -> [BaselineRecord] {
    let decoder = JSONDecoder()
    var records: [BaselineRecord] = []
    for rawLine in text.components(separatedBy: .newlines) {
      if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
        continue
      }
      if rawLine.hasPrefix("#") {
        continue
      }
      let data = Data(rawLine.utf8)
      records.append(try decoder.decode(BaselineRecord.self, from: data))
    }
    return records
  }

  public static func serialize(_ records: [BaselineRecord]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let lines = sorted(records).compactMap { record -> String? in
      do {
        let data = try encoder.encode(record)
        return String(data: data, encoding: .utf8)
      } catch {
        Output.error("baseline: could not encode structured record: \(error)")
        return nil
      }
    }
    if lines.isEmpty {
      return ""
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func read(_ path: String) -> [BaselineRecord] {
    guard FileManager.default.fileExists(atPath: path) else {
      return []
    }
    let text = Text.readLines(path).joined(separator: "\n")
    do {
      return try parse(text)
    } catch {
      Output.error("baseline: could not parse \(path): \(error)")
      return []
    }
  }

  public static func write(_ records: [BaselineRecord], to path: String) throws {
    try serialize(records).write(toFile: path, atomically: true, encoding: .utf8)
  }

  public static func keyCounts(_ records: [BaselineRecord]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for record in records {
      counts[record.key, default: 0] += 1
    }
    return counts
  }

  public static func rewrite(
    current: [Finding],
    old: [BaselineRecord],
    mode: BaselineMode,
    now: String
  ) -> [BaselineRecord] {
    var firstAddedByKey: [String: String] = [:]
    var oldKeys = Set<String>()
    for record in old {
      oldKeys.insert(record.key)
      guard let existingFirstAdded = firstAddedByKey[record.key] else {
        firstAddedByKey[record.key] = record.firstAdded
        continue
      }
      if record.firstAdded < existingFirstAdded {
        firstAddedByKey[record.key] = record.firstAdded
      }
    }

    var currentKeys = Set<String>()
    var records: [BaselineRecord] = []
    for finding in current {
      let key = BaselineKey.of(finding)
      currentKeys.insert(key)
      if mode == .pruneFixed, !oldKeys.contains(key) {
        continue
      }
      let firstAdded = firstAddedByKey[key] ?? now
      records.append(
        BaselineRecord.from(finding, firstAdded: firstAdded, lastSeen: now)
      )
    }

    if mode == .acceptNew {
      records += old.filter { !currentKeys.contains($0.key) }
    }

    return records
  }

  private static func sorted(_ records: [BaselineRecord]) -> [BaselineRecord] {
    records.sorted { first, second in
      if first.key != second.key {
        return first.key < second.key
      }
      if first.firstAdded != second.firstAdded {
        return first.firstAdded < second.firstAdded
      }
      if first.tool != second.tool {
        return first.tool < second.tool
      }
      if first.rule != second.rule {
        return first.rule < second.rule
      }
      if first.file != second.file {
        return first.file < second.file
      }
      if first.display != second.display {
        return first.display < second.display
      }
      return first.lastSeen < second.lastSeen
    }
  }
}
