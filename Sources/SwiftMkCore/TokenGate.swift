//
//  TokenGate.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - DailyTokenFetch

/// Thread-safe holder for the daily-token HTTP result. The URLSession completion
/// runs on a separate queue, so the response is stored under a lock and read
/// after the semaphore wait returns.
private final class DailyTokenFetch: @unchecked Sendable {
  private let lock = NSLock()
  private var storedData: Data?
  private var storedStatus = 0

  func store(data: Data?, statusCode: Int) {
    lock.lock()
    storedData = data
    storedStatus = statusCode
    lock.unlock()
  }

  var data: Data? {
    lock.lock()
    defer { lock.unlock() }
    return storedData
  }

  var statusCode: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedStatus
  }
}

// MARK: - TokenGate

/// Confirmation gate for baseline mutations.
///
/// Port of `scripts/swift-mk-gate.sh`. A mutation is permitted only when the
/// caller sets a truthy confirm value and supplies a token whose slug matches
/// the slug of the token command's output.
public enum TokenGate {
  /// Lowercase ASCII slug: transliterate to ASCII, keep `[A-Za-z0-9_-]`, lowercase.
  public static func slugify(_ input: String) -> String {
    let latin = input.applyingTransform(.toLatin, reverse: false) ?? input
    let ascii = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    let kept = ascii.unicodeScalars.filter { scalar in
      (scalar >= "A" && scalar <= "Z")
        || (scalar >= "a" && scalar <= "z")
        || (scalar >= "0" && scalar <= "9")
        || scalar == "_" || scalar == "-"
    }
    return String(String.UnicodeScalarView(kept)).lowercased()
  }

  private static func confirmed(_ value: String) -> Bool {
    ["1", "y", "yes", "Y", "YES"].contains(value)
  }

  /// Evaluate the gate. Returns true when the mutation is permitted.
  public static func passes(
    confirmValue: String,
    tokenValue: String,
    tokenCommand: String
  ) -> Bool {
    guard confirmed(confirmValue) else { return false }
    guard !tokenCommand.isEmpty else { return false }
    let result = Shell.sh(tokenCommand)
    guard result.status == 0 else { return false }
    let expected = slugify(result.stdout)
    let actual = slugify(tokenValue)
    guard !expected.isEmpty, !actual.isEmpty else { return false }
    return expected == actual
  }

  /// Wikimedia featured-feed endpoint. The day path is appended at call time.
  private static let dailyTokenURL =
    "https://en.wikipedia.org/api/rest_v1/feed/featured/"

  /// Wikimedia rejects the default URLSession user agent, so identify the
  /// client with a contact URL per their API etiquette.
  private static let dailyTokenUserAgent =
    "swift-mk/1.0 (https://goodkind.io/swift-makefile)"

  /// Request timeout in seconds for the daily-token fetch.
  private static let dailyTokenTimeout: TimeInterval = 10

  /// HTTP status that carries a usable body.
  private static let httpStatusOK = 200

  /// Typed slice of the featured-feed JSON: the canonical title of the day's
  /// featured article. A concrete model avoids untyped JSON dictionaries. The
  /// three levels are sibling types to stay within the two-level nesting limit.
  private struct FeaturedFeed: Decodable {
    let tfa: FeaturedArticle
  }

  private struct FeaturedArticle: Decodable {
    let titles: FeaturedTitles
  }

  private struct FeaturedTitles: Decodable {
    let canonical: String
  }

  /// Fetch the day's featured-article canonical title over HTTP, unslugified.
  /// Returns nil on any network or parse failure, so a gate that cannot reach
  /// the feed stays closed.
  static func dailyTokenRaw() -> String? {
    let day = dailyTokenDay()
    guard let url = URL(string: dailyTokenURL + day) else { return nil }
    Output.info("gate fetch featured feed: \(day)")
    var request = URLRequest(url: url, timeoutInterval: dailyTokenTimeout)
    request.setValue(dailyTokenUserAgent, forHTTPHeaderField: "User-Agent")

    let outcome = DailyTokenFetch()
    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
      var statusCode = 0
      if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
      outcome.store(data: data, statusCode: statusCode)
      semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    guard outcome.statusCode == httpStatusOK, let payload = outcome.data else { return nil }
    let feed: FeaturedFeed
    do {
      feed = try JSONDecoder().decode(FeaturedFeed.self, from: payload)
    } catch {
      return nil
    }
    let canonical = feed.tfa.titles.canonical
    guard !canonical.isEmpty else { return nil }
    return canonical
  }

  /// The current UTC date as `YYYY/MM/DD` for the feed path.
  private static func dailyTokenDay() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy/MM/dd"
    return formatter.string(from: Date())
  }

  /// The slugified daily token, the value a caller passes as BYPASS_LINT or
  /// BASELINE_TOKEN. Returns nil when the token cannot be resolved.
  public static func dailyTokenSlug() -> String? {
    guard let raw = dailyTokenRaw() else { return nil }
    return slugify(raw)
  }

  /// Evaluate the gate against the native daily token, or against an explicit
  /// token command when one is set. The override command preserves the escape
  /// hatch; otherwise the token is fetched in process.
  public static func passesNative(
    confirmValue: String,
    tokenValue: String,
    tokenCommandOverride: String
  ) -> Bool {
    guard confirmed(confirmValue) else { return false }
    let expectedSource: String?
    if tokenCommandOverride.isEmpty {
      expectedSource = dailyTokenRaw()
    } else {
      let result = Shell.sh(tokenCommandOverride)
      expectedSource = result.status == 0 ? result.stdout : nil
    }
    guard let expectedSource else { return false }
    let expected = slugify(expectedSource)
    let actual = slugify(tokenValue)
    guard !expected.isEmpty, !actual.isEmpty else { return false }
    return expected == actual
  }
}
