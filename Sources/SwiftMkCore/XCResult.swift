//
//  XCResult.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation

private let xcResultOneBasedLineOffset = 1
private let xcResultKeyValuePairPartCount = 2

// MARK: - XCResult

public enum XCResult {
  public struct Issue: Sendable, Equatable {
    public let severity: String
    public let message: String
    public let file: String
    public let line: Int

    public init(severity: String, message: String, file: String = "", line: Int = 0) {
      self.severity = severity
      self.message = message
      self.file = file
      self.line = line
    }
  }

  // Decode the JSON that `xcrun xcresulttool get build-results --format json`
  // prints from the Xcode 16+ surface.
  public static func issuesFromBuildResultsJSON(_ data: Data) -> [Issue] {
    let payload: XCResultBuildResultsPayload
    do {
      payload = try JSONDecoder().decode(
        XCResultBuildResultsPayload.self,
        from: data
      )
    } catch {
      return []
    }

    let errors = payload.errors?.compactMap { $0.issue(severity: "error") } ?? []
    let warnings = payload.warnings?.compactMap { $0.issue(severity: "warning") } ?? []
    return errors + warnings
  }
}

// MARK: - XCResultBuildResultsPayload

private struct XCResultBuildResultsPayload: Decodable {
  let errorCount: Int?
  let warningCount: Int?
  let errors: [XCResultIssuePayload]?
  let warnings: [XCResultIssuePayload]?

  enum CodingKeys: String, CodingKey {
    case errorCount
    case warningCount
    case errors
    case warnings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.errorCount = try container.decodeIfPresent(Int.self, forKey: .errorCount)
    self.warningCount = try container.decodeIfPresent(Int.self, forKey: .warningCount)
    self.errors = try container.decodeIfPresent([XCResultIssuePayload].self, forKey: .errors)
    self.warnings = try container.decodeIfPresent([XCResultIssuePayload].self, forKey: .warnings)
  }
}

// MARK: - XCResultIssuePayload

private struct XCResultIssuePayload: Decodable {
  let className: String?
  let issueType: String?
  let message: String?
  let sourceURL: String?
  let targetName: String?

  enum CodingKeys: String, CodingKey {
    case className
    case issueType
    case message
    case sourceURL
    case targetName
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.className = try container.decodeIfPresent(String.self, forKey: .className)
    self.issueType = try container.decodeIfPresent(String.self, forKey: .issueType)
    self.message = try container.decodeIfPresent(String.self, forKey: .message)
    self.sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
    self.targetName = try container.decodeIfPresent(String.self, forKey: .targetName)
  }

  func issue(severity: String) -> XCResult.Issue? {
    guard let message else {
      return nil
    }

    let location = XCResultSourceLocation(sourceURL: sourceURL)
    return XCResult.Issue(
      severity: severity,
      message: message,
      file: location.file,
      line: location.line
    )
  }
}

// MARK: - XCResultSourceLocation

private struct XCResultSourceLocation {
  let file: String
  let line: Int

  init(sourceURL: String?) {
    guard let sourceURL else {
      self.file = ""
      self.line = 0
      return
    }
    guard let url = URL(string: sourceURL), url.scheme == "file" else {
      self.file = ""
      self.line = 0
      return
    }

    self.file = url.path
    self.line = Self.startingLineNumber(from: url.fragment)
  }

  private static func startingLineNumber(from fragment: String?) -> Int {
    guard let fragment else {
      return 0
    }

    let parameters = fragment.split(separator: "&", omittingEmptySubsequences: true)
    for parameter in parameters {
      let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == xcResultKeyValuePairPartCount else {
        continue
      }
      guard pair[0] == "StartingLineNumber" else {
        continue
      }
      guard let zeroBasedLine = Int(pair[1]), zeroBasedLine >= 0 else {
        return 0
      }
      return zeroBasedLine + xcResultOneBasedLineOffset
    }

    return 0
  }
}
