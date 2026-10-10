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
private let ownerRecordSuffix = ".11"
private let deadHolderStartToken = "1000"
private let unknownStartToken = "unknown"
private let mismatchedStartTokenSuffix = "0"
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

private let startTokenScript = #"""
  if [[ -e "/proc/$1/stat" ]]; then
      stat_text=$(cat "/proc/$1/stat")
      stat_text="${stat_text##*)}"
      read -r -a stat_fields <<<"${stat_text}"
      printf '%s' "${stat_fields[19]}"
  else
      LC_ALL=C ps -o lstart= -p "$1" | tr -cd 'A-Za-z0-9'
  fi
  """#

private func processStartToken(_ processIdentifier: Int32) async throws -> String {
  let result = await OffPoolWork.run {
    Shell.run("/bin/bash", ["-c", startTokenScript, "start-token", "\(processIdentifier)"])
  }
  let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  try #require(!token.isEmpty, "\(result.stderr)")
  return token
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

private func ownerFilePath(
  _ consumer: LockConsumer, holder: Int32, startToken: String
) -> String {
  let recordName = ownerRecordPrefix + "\(holder)." + startToken + ownerRecordSuffix
  return consumer.lockDirectory + "/" + recordName
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
  let deadOwnerFile = ownerFilePath(
    consumer, holder: deadHolder, startToken: deadHolderStartToken)
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
  let liveStartToken = try await processStartToken(liveHolder)
  let liveOwnerFile = ownerFilePath(consumer, holder: liveHolder, startToken: liveStartToken)
  try writeLockRecord(consumer, path: liveOwnerFile, content: "")

  try await expectContenderWaitsForLiveRecord(
    consumer, recordPath: liveOwnerFile, liveHolder: liveHolder)
  removeIfPresent(consumer.directory)
}

@Test
func ownerFileWithAnUnknownStartTokenMakesTheContenderWait() async throws {
  let consumer = try await makeLockConsumer()
  let liveHolder = ProcessInfo.processInfo.processIdentifier
  let liveOwnerFile = ownerFilePath(
    consumer, holder: liveHolder, startToken: unknownStartToken)
  try writeLockRecord(consumer, path: liveOwnerFile, content: "")

  try await expectContenderWaitsForLiveRecord(
    consumer, recordPath: liveOwnerFile, liveHolder: liveHolder)
  removeIfPresent(consumer.directory)
}

@Test
func ownerFileOfAReusedProcessIdentifierIsRemovedAndTheLockIsAcquired() async throws {
  let consumer = try await makeLockConsumer()
  let reusedHolder = ProcessInfo.processInfo.processIdentifier
  let liveStartToken = try await processStartToken(reusedHolder)
  let staleOwnerFile = ownerFilePath(
    consumer, holder: reusedHolder, startToken: liveStartToken + mismatchedStartTokenSuffix)
  try writeLockRecord(consumer, path: staleOwnerFile, content: "")

  await expectContenderAcquiresWithinLimit(consumer)
  #expect(
    !FileManager.default.fileExists(atPath: staleOwnerFile),
    "the contender left an owner file with a different start token in place")
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
    consumer,
    path: ownerFilePath(consumer, holder: deadHolder, startToken: deadHolderStartToken),
    content: "")

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
