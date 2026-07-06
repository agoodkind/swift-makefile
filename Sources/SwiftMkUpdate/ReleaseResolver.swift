//
//  ReleaseResolver.swift
//  SwiftMkUpdate
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - ReleaseAsset

public struct ReleaseAsset: Equatable {
  public let name: String
  public let browserDownloadURL: URL
  public let digest: String?

  public init(name: String, browserDownloadURL: URL, digest: String?) {
    self.name = name
    self.browserDownloadURL = browserDownloadURL
    self.digest = digest
  }
}

// MARK: - Release

public struct Release: Equatable {
  public let tag: String
  public let assets: [ReleaseAsset]

  public init(tag: String, assets: [ReleaseAsset]) {
    self.tag = tag
    self.assets = assets
  }
}

// MARK: - ReleaseResolver

public enum ReleaseResolver {
  private static let successStatusCode = 200
  private static let timestampPrefixLength = 12

  public static func latestRelease(
    config: UpdateConfig,
    httpClient: any ReleaseHTTPClient
  ) throws -> Release {
    try config.validate()
    if config.allowPrerelease {
      let url = try releaseURL(config: config, path: "releases")
      let data = try fetchJSON(url: url, config: config, httpClient: httpClient)
      let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
      // Select the non-draft release with the greatest tag timestamp rather than
      // trusting API order, so a late-published older tag cannot become the
      // target. Tags without a timestamp sort lowest.
      let candidates = releases.filter { !$0.draft }
      guard
        let release = candidates.max(by: { lhs, rhs in
          (timestampPrefix(lhs.tagName) ?? Int64.min) < (timestampPrefix(rhs.tagName) ?? Int64.min)
        })
      else {
        throw UpdateError.release("no non-draft releases found for \(config.repo)")
      }
      return release.toRelease()
    }
    let url = try releaseURL(config: config, path: "releases/latest")
    let data = try fetchJSON(url: url, config: config, httpClient: httpClient)
    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    if release.draft || release.prerelease {
      throw UpdateError.release("latest release \(release.tagName) is not stable")
    }
    return release.toRelease()
  }

  public static func release(
    config: UpdateConfig,
    httpClient: any ReleaseHTTPClient,
    tag: String
  ) throws -> Release {
    try config.validate()
    let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedTag.isEmpty {
      throw UpdateError.validation("release tag is required")
    }
    let encodedTag = try encodedPathComponent(trimmedTag, context: "release tag")
    let url = try releaseURL(config: config, path: "releases/tags/\(encodedTag)")
    let data = try fetchJSON(url: url, config: config, httpClient: httpClient)
    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    if release.draft {
      throw UpdateError.release("release \(release.tagName) is draft")
    }
    return release.toRelease()
  }

  static func downloadHeaders(config: UpdateConfig, url: URL) -> [String: String] {
    var headers = ["Accept": "application/octet-stream"]
    // Attach the bearer token only when the download host matches the API base
    // host. Release asset URLs come from the API response and usually point at a
    // different host (e.g. objects.githubusercontent.com), so sending the token
    // there would leak it to an unintended endpoint.
    let apiHost = (config.apiBaseURL ?? URL(string: UpdateConfig.defaultAPIBaseURL))?.host
    if let token = config.authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty,
      let apiHost,
      url.host?.caseInsensitiveCompare(apiHost) == .orderedSame
    {
      headers["Authorization"] = "Bearer \(token)"
    }
    return headers
  }

  /// A binary built from source (not a stamped release) reports "dev" or
  /// "unknown". The single definition here is shared by isNewer, the scheduler,
  /// and the updater so the three call sites cannot drift.
  public static func isDevelopmentVersion(_ version: String) -> Bool {
    version == "dev" || version == "unknown"
  }

  public static func isNewer(latest: String, current: String) -> Bool {
    guard let latestTimestamp = timestampPrefix(latest) else {
      return false
    }
    if isDevelopmentVersion(current) {
      return true
    }
    guard let currentTimestamp = timestampPrefix(current) else {
      return false
    }
    return latestTimestamp > currentTimestamp
  }

  public static func assetURL(assets: [ReleaseAsset], assetName: String) -> URL? {
    for asset in assets where asset.name == assetName {
      return asset.browserDownloadURL
    }
    return nil
  }

  public static func expectedSHA256(checksumsText: String, assetName: String) -> String? {
    // A shasum line is "<hash><whitespace><name>". Split only on the first
    // whitespace run so an asset name containing spaces still matches; the "*"
    // marks binary mode.
    for line in checksumsText.split(separator: "\n") {
      let trimmed = String(line).trimmingCharacters(in: .whitespaces)
      guard let firstWhitespace = trimmed.firstIndex(where: \.isWhitespace) else {
        continue
      }
      let hash = String(trimmed[trimmed.startIndex..<firstWhitespace])
      var name = String(trimmed[firstWhitespace...]).trimmingCharacters(in: .whitespaces)
      if name.hasPrefix("*") {
        name.removeFirst()
      }
      if name == assetName {
        return hash
      }
    }
    return nil
  }

  public static func codesignTeamIdentifier(output: String) -> String? {
    for line in output.split(separator: "\n") {
      let text = String(line).trimmingCharacters(in: .whitespaces)
      guard text.hasPrefix("TeamIdentifier=") else {
        continue
      }
      let value = text.dropFirst("TeamIdentifier=".count)
      return String(value)
    }
    return nil
  }

  private static func fetchJSON(
    url: URL,
    config: UpdateConfig,
    httpClient: any ReleaseHTTPClient
  ) throws -> Data {
    let (data, status) = try httpClient.get(url, headers: githubHeaders(config: config))
    guard status == successStatusCode else {
      throw UpdateError.http("GET \(url.absoluteString): HTTP \(status)")
    }
    return data
  }

  private static func githubHeaders(config: UpdateConfig) -> [String: String] {
    var headers = ["Accept": "application/vnd.github+json"]
    if let token = config.authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    {
      headers["Authorization"] = "Bearer \(token)"
    }
    return headers
  }

  private static func releaseURL(config: UpdateConfig, path: String) throws -> URL {
    let baseURL = config.apiBaseURL ?? URL(string: UpdateConfig.defaultAPIBaseURL)
    guard let baseURL else {
      throw UpdateError.validation("update API base URL is invalid")
    }
    let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(base)/repos/\(config.repo)/\(path)") else {
      throw UpdateError.validation("update release URL is invalid")
    }
    return url
  }

  private static func encodedPathComponent(_ value: String, context: String) throws -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
      !encoded.isEmpty
    else {
      throw UpdateError.validation("\(context) is invalid")
    }
    return encoded
  }

  private static func timestampPrefix(_ value: String) -> Int64? {
    guard value.count >= timestampPrefixLength else {
      return nil
    }
    let prefix = value.prefix(timestampPrefixLength)
    guard prefix.allSatisfy(\.isNumber) else {
      return nil
    }
    return Int64(prefix)
  }

  // MARK: - GitHubRelease

  private struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
      case assets
      case draft
      case prerelease
      case tagName = "tag_name"
    }

    func toRelease() -> Release {
      Release(tag: tagName, assets: assets.map { $0.toReleaseAsset() })
    }
  }

  // MARK: - GitHubAsset

  private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
      case browserDownloadURL = "browser_download_url"
      case digest
      case name
    }

    func toReleaseAsset() -> ReleaseAsset {
      ReleaseAsset(name: name, browserDownloadURL: browserDownloadURL, digest: digest)
    }
  }
}
