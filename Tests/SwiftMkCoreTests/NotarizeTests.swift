//
//  NotarizeTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - NotarizeTests

enum NotarizeTests {}

@Test
func keyTrioWinsOverProfile() {
  let resolved = Notarize.credentials(
    keyPath: "/tmp/key.p8",
    keyId: "KEYID",
    issuerId: "ISSUER",
    profile: "local-profile")
  #expect(resolved == .keyFile(path: "/tmp/key.p8", keyId: "KEYID", issuerId: "ISSUER"))
}

@Test
func profileUsedWhenTrioIncomplete() {
  let resolved = Notarize.credentials(
    keyPath: "/tmp/key.p8",
    keyId: "",
    issuerId: "ISSUER",
    profile: "local-profile")
  #expect(resolved == .keychainProfile(name: "local-profile"))
}

@Test
func missingCredentialsResolveToNil() {
  let resolved = Notarize.credentials(keyPath: nil, keyId: "", issuerId: "", profile: "")
  #expect(resolved == nil)
}

@Test
func submitArgumentsForKeyFile() {
  let arguments = Notarize.submitArguments(
    artifact: "/tmp/App.dmg",
    credentials: .keyFile(path: "/tmp/key.p8", keyId: "K", issuerId: "I"))  // gitleaks:allow
  #expect(
    arguments == [
      "notarytool", "submit", "/tmp/App.dmg",
      "--key", "/tmp/key.p8", "--key-id", "K", "--issuer", "I",
      "--wait", "--output-format", "json",
    ])
}

@Test
func submitArgumentsForProfile() {
  let arguments = Notarize.submitArguments(
    artifact: "/tmp/lmd.zip",
    credentials: .keychainProfile(name: "notary"))  // gitleaks:allow
  #expect(
    arguments == [
      "notarytool", "submit", "/tmp/lmd.zip",
      "--keychain-profile", "notary",
      "--wait", "--output-format", "json",
    ])
}

@Test
func keyBase64DecodesDespiteWrappingAndTrailingNewline() {
  let cleanBytes = Notarize.decodeKeyBase64("dGVzdC1rZXktY29udGVudA==")
  let wrapped = Notarize.decodeKeyBase64("dGVzdC1rZXkt\nY29udGVudA==\n")
  let leadingSpace = Notarize.decodeKeyBase64(" dGVzdC1rZXktY29udGVudA==")
  let crlf = Notarize.decodeKeyBase64("dGVzdC1rZXktY29udGVudA==\r\n")

  #expect(cleanBytes == Data("test-key-content".utf8))
  #expect(wrapped == cleanBytes)
  #expect(leadingSpace == cleanBytes)
  #expect(crlf == cleanBytes)
}

@Test
func keyBase64StaysUndecodableForMalformedInput() {
  #expect(Notarize.decodeKeyBase64("abc") == nil)
  #expect(Notarize.decodeKeyBase64("%%%") == nil)
}

@Test
func zipsNeverStapleDirectly() {
  #expect(Notarize.staplesDirectly("/tmp/App.dmg") == true)
  #expect(Notarize.staplesDirectly("/tmp/App.pkg") == true)
  #expect(Notarize.staplesDirectly("/tmp/binaries.zip") == false)
}

@Test
func appBundlesFoundAtTwoLevels() throws {
  let root = NSTemporaryDirectory() + "notarize-test-\(UUID().uuidString)"
  let fileManager = FileManager.default
  try fileManager.createDirectory(atPath: root + "/Top.app", withIntermediateDirectories: true)
  try fileManager.createDirectory(
    atPath: root + "/Nested/Inner.app", withIntermediateDirectories: true)
  let found = Notarize.appBundles(under: root)
  #expect(found == [root + "/Nested/Inner.app", root + "/Top.app"])
  try fileManager.removeItem(atPath: root)
}

// MARK: - NotarizeEnvironmentTests

/// Env-path regression for the smc-fan release failure: a whitespace-wrapped
/// APPLE_NOTARY_KEY_BASE64 (what `base64 --decode` used to accept) must
/// resolve key-trio credentials, and a malformed one must resolve nil.
@Suite(.serialized)
enum NotarizeEnvironmentTests {
  private static let environmentKeys = [
    "APPLE_NOTARY_KEY_BASE64", "APPLE_NOTARY_KEY_ID", "APPLE_NOTARY_ISSUER_ID",
    "NOTARY_PROFILE",
  ]

  private static func withTrioEnvironment(
    keyBase64: String, body: () -> Void
  ) {
    var saved: [String: String?] = [:]
    for key in environmentKeys {
      saved[key] = getenv(key).map { String(cString: $0) }
    }
    defer {
      for key in environmentKeys {
        if let value = saved[key], let value {
          setenv(key, value, 1)
        } else {
          unsetenv(key)
        }
      }
    }
    setenv("APPLE_NOTARY_KEY_BASE64", keyBase64, 1)
    setenv("APPLE_NOTARY_KEY_ID", "KEYID", 1)
    setenv("APPLE_NOTARY_ISSUER_ID", "ISSUER", 1)
    unsetenv("NOTARY_PROFILE")
    body()
  }

  @Test
  static func wrappedKeyResolvesKeyFileCredentialsFromEnvironment() {
    withTrioEnvironment(keyBase64: "dGVzdC1rZXkt\nY29udGVudA==\n") {
      let resolved = Notarize.resolveCredentialsFromEnvironment()
      guard case let .keyFile(path, keyId, issuerId) = resolved else {
        Issue.record("expected keyFile credentials, got \(String(describing: resolved))")
        return
      }
      #expect(keyId == "KEYID")
      #expect(issuerId == "ISSUER")
      let written = FileManager.default.contents(atPath: path)
      #expect(written == Data("test-key-content".utf8))
    }
  }

  @Test
  static func malformedKeyResolvesNilNotProfileFallback() {
    withTrioEnvironment(keyBase64: "%%%") {
      #expect(Notarize.resolveCredentialsFromEnvironment() == nil)
    }
  }
}
