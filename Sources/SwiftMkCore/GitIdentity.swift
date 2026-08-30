//
//  GitIdentity.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - GitIdentity

/// The author identity `git config` reports for file headers and Xcode macros.
public struct GitIdentity: Equatable, Sendable {
  public let name: String
  public let email: String

  /// Why `git config user.name` or `user.email` could not be read.
  public enum LoadFailure: Error, Equatable, Sendable {
    case missingEmail
    case missingName
  }

  public init(name: String, email: String) {
    self.name = name
    self.email = email
  }

  /// Read `user.name` and `user.email` from git config in `directory`.
  ///
  /// `environment` overrides the child environment so tests can hide a host
  /// global gitconfig. An empty name or email is a failure, not a skip.
  public static func load(
    directory: String,
    environment: [String: String] = [:]
  ) -> Result<GitIdentity, LoadFailure> {
    Output.debug("git-identity: reading user.name and user.email in \(directory)")
    let name = configValue("user.name", directory: directory, environment: environment)
    let email = configValue("user.email", directory: directory, environment: environment)
    if name.isEmpty {
      Output.error("git-identity: git config user.name is empty")
      return .failure(.missingName)
    }
    if email.isEmpty {
      Output.error("git-identity: git config user.email is empty")
      return .failure(.missingEmail)
    }
    return .success(GitIdentity(name: name, email: email))
  }

  /// Unescaped tokens for Xcode FILEHEADER templates.
  public var headerValues: [String: String] {
    ["GIT_USER_EMAIL": email, "GIT_USER_NAME": name]
  }

  /// Regex-escaped tokens for SwiftLint `file_header.required_pattern`.
  public var regexEscapedHeaderValues: [String: String] {
    [
      "GIT_USER_EMAIL": NSRegularExpression.escapedPattern(for: email),
      "GIT_USER_NAME": NSRegularExpression.escapedPattern(for: name),
    ]
  }

  private static func configValue(
    _ key: String,
    directory: String,
    environment: [String: String]
  ) -> String {
    let result = Shell.run(
      "git",
      ["-C", directory, "config", "--get", key],
      environment: environment)
    if result.status != 0 {
      Output.debug(
        "git-identity: git config --get \(key) exited \(result.status)")
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
