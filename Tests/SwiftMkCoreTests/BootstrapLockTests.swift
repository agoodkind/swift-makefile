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

// MARK: - BootstrapLockTests

enum BootstrapLockTests {}

private let contenderSettleSeconds = 2
private let deadHolderRecoveryLimitSeconds = 10.0
private let ownerRecordPrefix = "owner."
private let ownerRecordSuffix = ".1000.11"
private let checkedTokenSuffix = " 1000 11"
private let simultaneousContenderCount = 8

private let consumerTemporarySubdirectory = "/tmp"

private typealias LockConsumer = (directory: String, lockDirectory: String)

private typealias TimedContenderRun = (result: BootstrapHelperRunner.Result, finishedAt: Date)

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

private func makeLockConsumer() async throws -> LockConsumer {
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

private func runLockContender(_ consumer: LockConsumer) async -> BootstrapHelperRunner.Result {
  await runHelper(
    directory: consumer.directory,
    environment: [
      "TMPDIR": consumer.directory + consumerTemporarySubdirectory,
      "SWIFT_MK_DEV_DIR": consumer.directory,
    ])
}

private func runTimedLockContender(_ consumer: LockConsumer) async -> TimedContenderRun {
  let result = await runLockContender(consumer)
  return (result: result, finishedAt: Date())
}

private func ownerFilePath(_ consumer: LockConsumer, holder: Int32) -> String {
  consumer.lockDirectory + "/" + ownerRecordPrefix + "\(holder)" + ownerRecordSuffix
}

private func ownerFileNames(_ consumer: LockConsumer) throws -> [String] {
  if !FileManager.default.fileExists(atPath: consumer.lockDirectory) {
    return []
  }
  let names = try FileManager.default.contentsOfDirectory(atPath: consumer.lockDirectory)
  return names.filter { $0.hasPrefix(ownerRecordPrefix) }
}

private func writeLockRecord(_ consumer: LockConsumer, path: String, content: String) throws {
  try FileManager.default.createDirectory(
    atPath: consumer.lockDirectory, withIntermediateDirectories: false)
  try content.write(toFile: path, atomically: true, encoding: .utf8)
}

private func expectContenderWaitsForLiveRecord(
  _ consumer: LockConsumer, recordPath: String, liveHolder: Int32
) async throws {
  async let contender = runTimedLockContender(consumer)
  try await Task.sleep(for: .seconds(contenderSettleSeconds))
  #expect(
    FileManager.default.fileExists(atPath: recordPath),
    "the contender removed a lock held by live process \(liveHolder)")
  let releasedAt = Date()
  removeIfPresent(recordPath)

  let run = await contender
  #expect(
    run.finishedAt >= releasedAt,
    "the contender exited while live process \(liveHolder) held the lock")
  #expect(run.result.status == 0, "\(run.result.stderr)")
}

private func expectContenderAcquiresWithinLimit(_ consumer: LockConsumer) async {
  let started = Date()
  let result = await runLockContender(consumer)
  let elapsedSeconds = Date().timeIntervalSince(started)
  #expect(result.status == 0, "\(result.stderr)")
  #expect(
    elapsedSeconds < deadHolderRecoveryLimitSeconds,
    "the contender took \(elapsedSeconds)s to acquire the lock")
}

@Test
func deadOwnerFileIsRemovedAndTheLockIsAcquired() async throws {
  let consumer = try await makeLockConsumer()
  let deadHolder = try await deadProcessIdentifier()
  let deadOwnerFile = ownerFilePath(consumer, holder: deadHolder)
  try writeLockRecord(consumer, path: deadOwnerFile, content: "")

  await expectContenderAcquiresWithinLimit(consumer)
  #expect(
    !FileManager.default.fileExists(atPath: deadOwnerFile),
    "the contender left the owner file of dead process \(deadHolder) in place")
  removeIfPresent(consumer.directory)
}

@Test
func liveOwnerFileMakesTheContenderWait() async throws {
  let consumer = try await makeLockConsumer()
  let liveHolder = ProcessInfo.processInfo.processIdentifier
  let liveOwnerFile = ownerFilePath(consumer, holder: liveHolder)
  try writeLockRecord(consumer, path: liveOwnerFile, content: "")

  try await expectContenderWaitsForLiveRecord(
    consumer, recordPath: liveOwnerFile, liveHolder: liveHolder)
  removeIfPresent(consumer.directory)
}

@Test(arguments: ["", checkedTokenSuffix])
func legacyPidFileOfADeadProcessIsReclaimed(recordSuffix: String) async throws {
  let consumer = try await makeLockConsumer()
  let deadHolder = try await deadProcessIdentifier()
  try writeLockRecord(
    consumer, path: consumer.lockDirectory + "/pid", content: "\(deadHolder)\(recordSuffix)\n")

  await expectContenderAcquiresWithinLimit(consumer)
  removeIfPresent(consumer.directory)
}

@Test
func legacyPidFileOfALiveProcessMakesTheContenderWait() async throws {
  let consumer = try await makeLockConsumer()
  let liveHolder = ProcessInfo.processInfo.processIdentifier
  let pidPath = consumer.lockDirectory + "/pid"
  try writeLockRecord(consumer, path: pidPath, content: "\(liveHolder)\(checkedTokenSuffix)\n")

  try await expectContenderWaitsForLiveRecord(
    consumer, recordPath: pidPath, liveHolder: liveHolder)
  removeIfPresent(consumer.directory)
}

@Test
func releasedLockLeavesNoOwnerFileAndIsAcquiredAgain() async throws {
  let consumer = try await makeLockConsumer()

  let first = await runLockContender(consumer)
  #expect(first.status == 0, "\(first.stderr)")
  let remainingOwnerFiles = try ownerFileNames(consumer)
  #expect(
    remainingOwnerFiles.isEmpty,
    "the contender left owner files after exiting: \(remainingOwnerFiles)")

  await expectContenderAcquiresWithinLimit(consumer)
  removeIfPresent(consumer.directory)
}

@Test
func simultaneousContendersAllAcquireALockWithADeadOwnerFile() async throws {
  let consumer = try await makeLockConsumer()
  let deadHolder = try await deadProcessIdentifier()
  try writeLockRecord(
    consumer, path: ownerFilePath(consumer, holder: deadHolder), content: "")

  let results = await withTaskGroup(of: BootstrapHelperRunner.Result.self) { group in
    for _ in 0..<simultaneousContenderCount {
      group.addTask {
        await runLockContender(consumer)
      }
    }
    var collected: [BootstrapHelperRunner.Result] = []
    for await result in group {
      collected.append(result)
    }
    return collected
  }

  #expect(results.count == simultaneousContenderCount)
  for result in results {
    #expect(result.status == 0, "\(result.stderr)")
  }
  let remainingOwnerFiles = try ownerFileNames(consumer)
  #expect(
    remainingOwnerFiles.isEmpty,
    "the contender left owner files after exiting: \(remainingOwnerFiles)")
  removeIfPresent(consumer.directory)
}
