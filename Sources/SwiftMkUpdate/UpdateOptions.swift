//
//  UpdateOptions.swift
//  SwiftMkUpdate
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import Darwin
import Foundation

// MARK: - ReleaseHTTPClient

public protocol ReleaseHTTPClient {
  func get(_ url: URL, headers: [String: String]) throws -> (Data, Int)
}

// MARK: - URLSessionReleaseHTTPClient

public final class URLSessionReleaseHTTPClient: ReleaseHTTPClient {
  private static let defaultTimeout: TimeInterval = 120
  // Wait slightly longer than the request timeout so URLSession's own timeout
  // normally fires first and surfaces the real error; this grace is the backstop
  // for a completion handler that never runs at all.
  private static let waitGrace: TimeInterval = 15

  private let session: URLSession
  private let timeout: TimeInterval

  public init(
    session: URLSession = .shared,
    timeout: TimeInterval? = nil
  ) {
    self.session = session
    self.timeout = timeout ?? Self.defaultTimeout
  }

  public func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = HTTPResponseBox()
    let task = session.dataTask(with: request) { data, response, error in
      if let error {
        box.store(.failure(error))
      } else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        box.store(.success((data ?? Data(), status)))
      }
      semaphore.signal()
    }
    task.resume()
    // Bound the wait so a hung callback cannot deadlock the caller (a daemon
    // running UpdateScheduler is a stated target).
    if semaphore.wait(timeout: .now() + timeout + Self.waitGrace) == .timedOut {
      task.cancel()
      throw UpdateError.http(
        "request timed out after \(timeout + Self.waitGrace)s: \(url.absoluteString)")
    }
    return try box.result()
  }
}

// MARK: - CommandOutput

public struct CommandOutput: Equatable, Sendable {
  public let status: Int32
  public let stdout: String
  public let stderr: String

  public init(status: Int32, stdout: String, stderr: String) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }
}

// MARK: - CommandRunner

public protocol CommandRunner {
  func run(
    _ tool: String,
    _ args: [String]
  ) -> CommandOutput
}

// MARK: - ProcessCommandRunner

public final class ProcessCommandRunner: CommandRunner {
  private static let launchFailureStatus: Int32 = 127
  // Bound every external tool. A hung codesign/hdiutil/xcrun (a wedged mount, a
  // stuck notarization staple check) would otherwise block the update flow, and
  // a daemon running UpdateScheduler, forever. On timeout the process is
  // terminated, escalated to SIGKILL if it ignores SIGTERM, and reported as a
  // non-zero (timeout) status so Updater surfaces an UpdateError.
  private static let waitTimeout: TimeInterval = 300
  private static let terminateGrace: TimeInterval = 5
  private static let timeoutStatus: Int32 = 124
  // The verifier resolves its own tools rather than inheriting PATH, so a
  // manipulated PATH cannot substitute a lookalike codesign/hdiutil/xcrun and
  // bypass the signature checks. Bare tool names resolve under /usr/bin (where
  // the macOS system tools live); an absolute or relative path is honored as-is.
  private static let systemToolDirectory = "/usr/bin"

  public init() {
    UpdateDiagnostics.debug("update command runner initialized")
  }

  static func executableURL(for tool: String) -> URL {
    if tool.contains("/") {
      return URL(fileURLWithPath: tool)
    }
    return URL(fileURLWithPath: systemToolDirectory).appendingPathComponent(tool)
  }

  public func run(
    _ tool: String,
    _ args: [String]
  ) -> CommandOutput {
    UpdateDiagnostics.debug("update command run \(tool)")
    let process = Process()
    process.executableURL = Self.executableURL(for: tool)
    process.arguments = args
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    let group = DispatchGroup()
    let stdoutData = LockedData()
    let stderrData = LockedData()
    drain(stdout.fileHandleForReading, into: stdoutData, group: group)
    drain(stderr.fileHandleForReading, into: stderrData, group: group)
    // Set the termination handler before run() so a fast-exiting process cannot
    // signal before the handler is installed.
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      return CommandOutput(
        status: Self.launchFailureStatus,
        stdout: "",
        stderr: "launch \(tool): \(error.localizedDescription)\n"
      )
    }
    if exited.wait(timeout: .now() + Self.waitTimeout) == .timedOut {
      terminate(process, exited: exited)
      group.wait()
      return CommandOutput(
        status: Self.timeoutStatus,
        stdout: String(data: stdoutData.snapshot(), encoding: .utf8) ?? "",
        stderr: "timeout after \(Self.waitTimeout)s: \(tool)\n"
          + (String(data: stderrData.snapshot(), encoding: .utf8) ?? "")
      )
    }
    group.wait()
    return CommandOutput(
      status: process.terminationStatus,
      stdout: String(data: stdoutData.snapshot(), encoding: .utf8) ?? "",
      stderr: String(data: stderrData.snapshot(), encoding: .utf8) ?? ""
    )
  }

  /// Terminate a hung process: SIGTERM first, then SIGKILL if it does not exit
  /// within the grace window. Waits for the exit so terminationStatus settles.
  private func terminate(_ process: Process, exited: DispatchSemaphore) {
    process.terminate()
    if exited.wait(timeout: .now() + Self.terminateGrace) == .timedOut {
      kill(process.processIdentifier, SIGKILL)
      exited.wait()
    }
  }

  private func drain(_ handle: FileHandle, into buffer: LockedData, group: DispatchGroup) {
    group.enter()
    handle.readabilityHandler = { source in
      let chunk = source.availableData
      if chunk.isEmpty {
        source.readabilityHandler = nil
        group.leave()
      } else {
        buffer.append(chunk)
      }
    }
  }
}

// MARK: - UpdateOptions

public struct UpdateOptions {
  public let config: UpdateConfig
  public let targetPath: String
  public let cacheDir: String
  public let statePath: String
  public let dryRun: Bool
  public let log: (String) -> Void
  public let httpClient: any ReleaseHTTPClient
  public let commandRunner: any CommandRunner
  public let now: () -> Date

  public init(
    config: UpdateConfig,
    targetPath: String? = nil,
    cacheDir: String? = nil,
    statePath: String? = nil,
    dryRun: Bool = false,
    log: @escaping (String) -> Void = { message in _ = message },
    httpClient: any ReleaseHTTPClient = URLSessionReleaseHTTPClient(),
    commandRunner: any CommandRunner = ProcessCommandRunner(),
    now: @escaping () -> Date = Date.init
  ) {
    self.config = config
    self.targetPath = targetPath ?? Self.defaultTargetPath()
    self.cacheDir = cacheDir ?? defaultCacheDir(binary: config.binary)
    self.statePath = statePath ?? defaultStatePath(binary: config.binary)
    self.dryRun = dryRun
    self.log = log
    self.httpClient = httpClient
    self.commandRunner = commandRunner
    self.now = now
  }

  public static func defaultTargetPath(
    arguments: [String] = CommandLine.arguments,
    currentDirectory: String = FileManager.default.currentDirectoryPath,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> String {
    let rawArgument = arguments.first ?? ProcessInfo.processInfo.processName
    let absolutePath: String
    if rawArgument.hasPrefix("/") {
      absolutePath = rawArgument
    } else if rawArgument.contains("/") {
      // A relative path such as ./swift-mk resolves against the working directory.
      absolutePath =
        URL(fileURLWithPath: currentDirectory, isDirectory: true)
        .appendingPathComponent(rawArgument)
        .path
    } else if let onPath = lookupOnPath(
      command: rawArgument, environment: environment, fileManager: fileManager)
    {
      // A bare command name means the tool was launched from PATH, so the target
      // is its PATH entry, not a same-named file in the working directory.
      absolutePath = onPath
    } else {
      absolutePath =
        URL(fileURLWithPath: currentDirectory, isDirectory: true)
        .appendingPathComponent(rawArgument)
        .path
    }
    return URL(fileURLWithPath: absolutePath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  static func lookupOnPath(
    command: String,
    environment: [String: String],
    fileManager: FileManager
  ) -> String? {
    guard let pathValue = environment["PATH"], !pathValue.isEmpty else {
      return nil
    }
    for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
      let candidate =
        URL(fileURLWithPath: String(directory), isDirectory: true)
        .appendingPathComponent(command)
        .path
      if fileManager.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}

// MARK: - HTTPResponseBox

private final class HTTPResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<(Data, Int), Error>?

  func store(_ result: Result<(Data, Int), Error>) {
    lock.lock()
    stored = result
    lock.unlock()
  }

  func result() throws -> (Data, Int) {
    lock.lock()
    let result = stored
    lock.unlock()
    guard let result else {
      // No stored result means the completion handler never ran; fail loud
      // rather than returning an empty body with HTTP 0.
      throw UpdateError.http("no HTTP response was recorded")
    }
    return try result.get()
  }
}

// MARK: - LockedData

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ chunk: Data) {
    lock.lock()
    data.append(chunk)
    lock.unlock()
  }

  func snapshot() -> Data {
    lock.lock()
    let value = data
    lock.unlock()
    return value
  }
}
