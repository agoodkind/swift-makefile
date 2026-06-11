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
