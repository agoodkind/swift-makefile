//
//  BootstrapLockTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

// MARK: - BootstrapLockTests

enum BootstrapLockTests {}

private let fifoMode: mode_t = 0o600
private let readerWaitSeconds = 10.0
private let readerPollMicroseconds: useconds_t = 10_000
private let contenderSettleSeconds = 2

private func lockDirectoryPath(consumer: String, temporaryDirectory: String) async -> String {
  let script = #"cd "$1" && printf '%s' "$(pwd -P)" | shasum | cut -d' ' -f1"#
  let result = await OffPoolWork.run {
    Shell.run("/bin/bash", ["-c", script, "lock-digest", consumer])
  }
  let digest = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  return temporaryDirectory + "/swift-mk-lock-" + digest
}

private func deadProcessIdentifier() async throws -> Int32 {
  try await OffPoolWork.run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
  }
}

private func openWriterOnceReaderArrives(_ path: String) async -> Int32 {
  await OffPoolWork.run {
    let deadline = Date().addingTimeInterval(readerWaitSeconds)
    while Date() < deadline {
      let descriptor = open(path, O_WRONLY | O_NONBLOCK)
      if descriptor >= 0 {
        return descriptor
      }
      usleep(readerPollMicroseconds)
    }
    return -1
  }
}

@Test
func staleLockReclaimLeavesALiveReplacementLockInPlace() async throws {
  let directory = try temporaryConsumer()
  try FileManager.default.createDirectory(
    atPath: directory + "/.make", withIntermediateDirectories: true)
  let temporaryDirectory = directory + "/tmp"
  try FileManager.default.createDirectory(
    atPath: temporaryDirectory, withIntermediateDirectories: true)
  let lockDirectory = await lockDirectoryPath(
    consumer: directory, temporaryDirectory: temporaryDirectory)
  let stalePidPath = lockDirectory + "/pid"
  let replacedStaleLock = lockDirectory + ".replaced"
  let deadHolder = try await deadProcessIdentifier()
  let liveHolder = ProcessInfo.processInfo.processIdentifier
  let liveHolderRecord = "\(liveHolder)\n"

  try FileManager.default.createDirectory(atPath: lockDirectory, withIntermediateDirectories: false)
  try #require(mkfifo(stalePidPath, fifoMode) == 0)

  async let contender = runHelper(
    directory: directory,
    environment: ["TMPDIR": temporaryDirectory, "SWIFT_MK_DEV_DIR": directory])

  // The pipe blocks the contender after it opens the stale lock's pid.
  // The test swaps locks between the stale pid read and the reclaim attempt.
  let writer = await openWriterOnceReaderArrives(stalePidPath)
  #expect(writer >= 0, "the contender never opened the stale lock's pid file")
  try FileManager.default.moveItem(atPath: lockDirectory, toPath: replacedStaleLock)
  try FileManager.default.createDirectory(atPath: lockDirectory, withIntermediateDirectories: false)
  try liveHolderRecord.write(toFile: lockDirectory + "/pid", atomically: true, encoding: .utf8)
  if writer >= 0 {
    let deadHolderRecord = Array("\(deadHolder)\n".utf8)
    let written = write(writer, deadHolderRecord, deadHolderRecord.count)
    #expect(written == deadHolderRecord.count)
    close(writer)
  }

  try await Task.sleep(for: .seconds(contenderSettleSeconds))
  let lockName = (lockDirectory as NSString).lastPathComponent
  let recordedHolder = readConsumerFile(directory, "tmp/" + lockName + "/pid")
  let removalMessage =
    "the contender removed a lock held by live process \(liveHolder) "
    + "after checking dead process \(deadHolder)"
  #expect(recordedHolder == liveHolderRecord, "\(removalMessage)")

  removeIfPresent(lockDirectory)
  let result = await contender
  #expect(result.status == 0, "\(result.stderr)")
  removeIfPresent(replacedStaleLock)
  removeIfPresent(directory)
}
