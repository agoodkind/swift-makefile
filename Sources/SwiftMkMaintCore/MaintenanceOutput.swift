//
//  MaintenanceOutput.swift
//  SwiftMkMaintCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - MaintenanceOutput

public struct MaintenanceOutput {
  public enum Level: Int {
    case debug = 0
    case error = 4
    case info = 1
    case notice = 2
    case warning = 3
  }

  private static let levelEnvironmentName = "SWIFT_MK_LOG_LEVEL"

  private let standardOutputHandler: (String) -> Void
  private let standardErrorHandler: (String) -> Void
  private let environmentProvider: () -> [String: String]

  public init(
    standardOutput: @escaping (String) -> Void = { text in
      FileHandle.standardOutput.write(Data(text.utf8))
    },
    standardError: @escaping (String) -> Void = { text in
      FileHandle.standardError.write(Data(text.utf8))
    },
    environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }
  ) {
    self.standardOutputHandler = standardOutput
    self.standardErrorHandler = standardError
    self.environmentProvider = environment
  }

  public static func log(_ message: String) {
    Self().log(message)
  }

  public static func logError(_ message: String) {
    Self().logError(message)
  }

  public static func debug(_ message: String) {
    Self().debug(message)
  }

  public static func info(_ message: String) {
    Self().info(message)
  }

  public static func notice(_ message: String) {
    Self().notice(message)
  }

  public static func warning(_ message: String) {
    Self().warning(message)
  }

  public static func error(_ message: String) {
    Self().error(message)
  }

  public func log(_ message: String) {
    standardOutputHandler(message + "\n")
  }

  public func logError(_ message: String) {
    standardErrorHandler(message + "\n")
  }

  public func debug(_ message: String) {
    diagnose(message, at: .debug)
  }

  public func info(_ message: String) {
    diagnose(message, at: .info)
  }

  public func notice(_ message: String) {
    diagnose(message, at: .notice)
  }

  public func warning(_ message: String) {
    diagnose(message, at: .warning)
  }

  public func error(_ message: String) {
    logError(message)
  }

  private func diagnose(_ message: String, at level: Level) {
    guard let threshold = thresholdLevel(), level.rawValue >= threshold.rawValue else {
      return
    }
    logError(message)
  }

  private func thresholdLevel() -> Level? {
    let raw = environmentProvider()[Self.levelEnvironmentName, default: ""].lowercased()
    switch raw {
    case "debug":
      return .debug
    case "info":
      return .info
    case "notice":
      return .notice
    case "warning":
      return .warning
    case "error":
      return .error
    default:
      return nil
    }
  }
}
