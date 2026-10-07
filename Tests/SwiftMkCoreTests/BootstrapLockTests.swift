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

private let abandonedClaimAgeSeconds = 60.0
private let abandonedClaimRecoveryLimitSeconds = 20.0
private let checkedTokenSuffix = " 1000 11"
private let replacementTokenSuffix = " 2000 22"

private let consumerTemporarySubdirectory = "/tmp"

private func makeLockConsumer() async throws -> (directory: String, lockDirectory: String) {
  let directory = try temporaryConsumer()
  try FileManager.default.createDirectory(
    atPath: directory + "/.make", withIntermediateDirectories: true)
  let temporaryDirectory = directory + consumerTemporarySubdirectory
  try FileManager.default.createDirectory(
    atPath: temporaryDirectory, withIntermediateDirectories: true)
  let lockDirectory = await lockDirectoryPath(
    consumer: directory, temporaryDirectory: temporaryDirectory)
  return (directory: directory, lockDirectory: lockDirectory)
}

private func runLockContender(
  _ consumer: (directory: String, lockDirectory: String)
) async -> BootstrapHelperRunner.Result {
  await runHelper(
    directory: consumer.directory,
    environment: [
      "TMPDIR": consumer.directory + consumerTemporarySubdirectory,
      "SWIFT_MK_DEV_DIR": consumer.directory,
    ])
}

@Test
func staleLockReclaimLeavesALiveReplacementLockInPlace() async throws {
  let deadHolder = try await deadProcessIdentifier()
  let liveHolder = ProcessInfo.processInfo.processIdentifier
  try await expectReplacementLockSurvivesReclaim(
    checkedRecord: "\(deadHolder)\n",
    replacementRecord: "\(liveHolder)\n",
    removalMessage: "the contender removed a lock held by live process \(liveHolder) "
      + "after checking dead process \(deadHolder)")
}

private let rereadSettleMilliseconds = 500

private func isFifo(_ path: String) -> Bool {
  var information = stat()
  if lstat(path, &information) != 0 {
    return false
  }
  return (information.st_mode & S_IFMT) == S_IFIFO
}

private func writeRecord(_ record: String, onceReaderOpens path: String) async -> Bool {
  let writer = await openWriterOnceReaderArrives(path)
  if writer < 0 {
    return false
  }
  let bytes = Array(record.utf8)
  let written = write(writer, bytes, bytes.count)
  close(writer)
  return written == bytes.count
}

@Test
func staleLockReclaimLeavesAReplacementLockWithAReusedPidInPlace() async throws {
  let consumer = try await makeLockConsumer()
  let lockDirectory = consumer.lockDirectory
  let pidPath = lockDirectory + "/pid"
  let replacedStaleLock = lockDirectory + ".replaced"
  let deadHolder = try await deadProcessIdentifier()
  let liveHolder = ProcessInfo.processInfo.processIdentifier
  try FileManager.default.createDirectory(atPath: lockDirectory, withIntermediateDirectories: false)
  try #require(mkfifo(pidPath, fifoMode) == 0)

  async let contender = runLockContender(consumer)

  let staleWriter = await openWriterOnceReaderArrives(pidPath)
  #expect(staleWriter >= 0, "the contender never opened the stale lock's pid file")
  try FileManager.default.moveItem(atPath: lockDirectory, toPath: replacedStaleLock)
  try FileManager.default.createDirectory(atPath: lockDirectory, withIntermediateDirectories: false)
  try #require(mkfifo(pidPath, fifoMode) == 0)
  if staleWriter >= 0 {
    let checkedBytes = Array("\(deadHolder)\(checkedTokenSuffix)\n".utf8)
    #expect(write(staleWriter, checkedBytes, checkedBytes.count) == checkedBytes.count)
    close(staleWriter)
  }

  let reread = await writeRecord(
    "\(deadHolder)\(replacementTokenSuffix)\n", onceReaderOpens: pidPath)
  #expect(reread, "the contender never re-read the replacement lock's pid file")
  try await Task.sleep(for: .milliseconds(rereadSettleMilliseconds))
  let removalMessage =
    "the contender removed a replacement lock that reused PID \(deadHolder) "
    + "with a different token"
  #expect(isFifo(pidPath), "\(removalMessage)")
  let nextIteration = await writeRecord(
    "\(liveHolder)\(replacementTokenSuffix)\n", onceReaderOpens: pidPath)
  #expect(nextIteration, "the contender never read the replacement lock on its next attempt")

  removeIfPresent(lockDirectory)
  let result = await contender
  #expect(result.status == 0, "\(result.stderr)")
  removeIfPresent(replacedStaleLock)
  removeIfPresent(consumer.directory)
}

@Test
func lockHolderCheckUsesThePidFieldOfATokenRecord() async throws {
  let consumer = try await makeLockConsumer()
  let liveHolder = ProcessInfo.processInfo.processIdentifier
  let liveHolderRecord = "\(liveHolder)\(checkedTokenSuffix)\n"
  try FileManager.default.createDirectory(
    atPath: consumer.lockDirectory, withIntermediateDirectories: false)
  try liveHolderRecord.write(
    toFile: consumer.lockDirectory + "/pid", atomically: true, encoding: .utf8)

  async let contender = runLockContender(consumer)
  try await Task.sleep(for: .seconds(contenderSettleSeconds))
  let lockName = (consumer.lockDirectory as NSString).lastPathComponent
  let recordedHolder = readConsumerFile(consumer.directory, "tmp/" + lockName + "/pid")
  #expect(
    recordedHolder == liveHolderRecord,
    "the contender removed a lock held by live process \(liveHolder)")

  removeIfPresent(consumer.lockDirectory)
  let result = await contender
  #expect(result.status == 0, "\(result.stderr)")
  removeIfPresent(consumer.directory)
}

@Test
func staleLockWithAnAbandonedReclaimClaimIsAcquiredBeforeTheTimeout() async throws {
  let consumer = try await makeLockConsumer()
  let deadHolder = try await deadProcessIdentifier()
  try FileManager.default.createDirectory(
    atPath: consumer.lockDirectory, withIntermediateDirectories: false)
  try "\(deadHolder)\n".write(
    toFile: consumer.lockDirectory + "/pid", atomically: true, encoding: .utf8)
  let claimDirectory = consumer.lockDirectory + "/reclaim.\(deadHolder)"
  try FileManager.default.createDirectory(
    atPath: claimDirectory, withIntermediateDirectories: false)
  let claimDate = Date().addingTimeInterval(-abandonedClaimAgeSeconds)
  try FileManager.default.setAttributes(
    [.modificationDate: claimDate], ofItemAtPath: claimDirectory)

  let started = Date()
  let result = await runLockContender(consumer)
  let elapsedSeconds = Date().timeIntervalSince(started)
  #expect(result.status == 0, "\(result.stderr)")
  #expect(
    elapsedSeconds < abandonedClaimRecoveryLimitSeconds,
    "the contender took \(elapsedSeconds)s to acquire a stale lock with an abandoned claim")
  removeIfPresent(consumer.directory)
}

private func expectReplacementLockSurvivesReclaim(
  checkedRecord: String, replacementRecord: String, removalMessage: String
) async throws {
  let consumer = try await makeLockConsumer()
  let directory = consumer.directory
  let lockDirectory = consumer.lockDirectory
  let stalePidPath = lockDirectory + "/pid"
  let replacedStaleLock = lockDirectory + ".replaced"

  try FileManager.default.createDirectory(atPath: lockDirectory, withIntermediateDirectories: false)
  try #require(mkfifo(stalePidPath, fifoMode) == 0)

  async let contender = runLockContender(consumer)

  // The pipe blocks the contender after it opens the stale lock's pid.
  // The test swaps locks between the stale pid read and the reclaim attempt.
  let writer = await openWriterOnceReaderArrives(stalePidPath)
  #expect(writer >= 0, "the contender never opened the stale lock's pid file")
  try FileManager.default.moveItem(atPath: lockDirectory, toPath: replacedStaleLock)
  try FileManager.default.createDirectory(atPath: lockDirectory, withIntermediateDirectories: false)
  try replacementRecord.write(toFile: lockDirectory + "/pid", atomically: true, encoding: .utf8)
  if writer >= 0 {
    let checkedBytes = Array(checkedRecord.utf8)
    let written = write(writer, checkedBytes, checkedBytes.count)
    #expect(written == checkedBytes.count)
    close(writer)
  }

  try await Task.sleep(for: .seconds(contenderSettleSeconds))
  let lockName = (lockDirectory as NSString).lastPathComponent
  let recordedHolder = readConsumerFile(directory, "tmp/" + lockName + "/pid")
  #expect(recordedHolder == replacementRecord, "\(removalMessage)")

  removeIfPresent(lockDirectory)
  let result = await contender
  #expect(result.status == 0, "\(result.stderr)")
  removeIfPresent(replacedStaleLock)
  removeIfPresent(directory)
}
