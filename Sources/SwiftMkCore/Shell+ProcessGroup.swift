//
//  Shell+ProcessGroup.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

// Darwin imports `posix_spawnattr_t` and `posix_spawn_file_actions_t` as optional
// opaque pointers, while glibc imports them as concrete structs. The spawn helpers
// take these by `inout`, so the parameter type has to follow the platform's import.
#if canImport(Darwin)
  private typealias SpawnAttributes = posix_spawnattr_t?
  private typealias SpawnFileActions = posix_spawn_file_actions_t?
#else
  private typealias SpawnAttributes = posix_spawnattr_t
  private typealias SpawnFileActions = posix_spawn_file_actions_t
#endif

// A stdout or stderr pipe for the process-group spawn, exposing the same
// `fileHandleForReading` and `fileHandleForWriting` accessors as Foundation `Pipe`
// so the parent's drain path is identical on both platforms.
#if canImport(Darwin)
  // On Darwin the pipe is a plain `Pipe`; `POSIX_SPAWN_CLOEXEC_DEFAULT` makes the
  // spawn treat its fds as close-on-exec atomically, so nothing extra is needed.
  typealias StreamingPipe = Pipe
#else
  // On glibc the two ends are created atomically close-on-exec with
  // `pipe2(O_CLOEXEC)`. Foundation `Pipe` creates its fds without `O_CLOEXEC`, and
  // glibc has no `POSIX_SPAWN_CLOEXEC_DEFAULT`, so marking the fds close-on-exec
  // after the fact with `fcntl` left a window in which a concurrently spawning
  // sibling could inherit an end and hold a pipe open past EOF. `pipe2` closes that
  // window by creating both ends close-on-exec in a single call.
  struct StreamingPipe {
    let fileHandleForReading: FileHandle
    let fileHandleForWriting: FileHandle
  }

  // glibc's `pipe2` is a GNU extension that Swift's Glibc module map does not
  // surface (it is gated behind `_GNU_SOURCE` in the C headers), so bind the libc
  // symbol directly. Its C signature is `int pipe2(int pipefd[2], int flags)`; the
  // array decays to a pointer, so `UnsafeMutablePointer<Int32>` matches the ABI.
  @_silgen_name("pipe2")
  private func swiftMkPipe2(_ fileDescriptors: UnsafeMutablePointer<Int32>, _ flags: Int32) -> Int32
#endif

// MARK: - Timeout process-group spawn and reap

extension Shell {
  /// Grace period after SIGTERM before escalating to SIGKILL on a timed-out tree.
  static let timeoutTerminationGraceSeconds: Double = 2.0
  /// POSIX wait-status decoding: the low seven bits carry the terminating signal.
  static let waitStatusSignalMask: Int32 = 0x7f
  /// A low-seven-bits value of 0x7f marks a stopped (not terminated) child.
  static let waitStatusStoppedMarker: Int32 = 0x7f
  /// The exit code sits in the second byte of the wait status.
  static let waitStatusExitShift: Int32 = 8
  /// Mask selecting the exit-code byte after the shift.
  static let waitStatusExitByteMask: Int32 = 0xff
  /// Shell convention: a signalled child reports 128 plus the signal number.
  static let signalExitBase: Int32 = 128

  /// A subprocess spawned into its own process group for the timeout-capable
  /// `runStreamingStderr` path, with the pipes the parent drains.
  struct SpawnedStreamingProcess {
    let processIdentifier: pid_t
    let standardOutput: StreamingPipe
    let standardError: StreamingPipe
  }

  /// Configure the spawn attributes for a new process group and the file actions
  /// that wire the child's stdout and stderr to the pipe write ends. Returns false
  /// if any configuration call fails.
  ///
  /// On Darwin, `POSIX_SPAWN_CLOEXEC_DEFAULT` makes the kernel treat every parent
  /// descriptor as close-on-exec, so no unrelated fd leaks into the child.
  /// Foundation `Pipe` does not mark its fds close-on-exec on Darwin, so without
  /// this flag a concurrently spawning sibling's pipe write end could be inherited
  /// here and hold that sibling's pipe open past EOF, hanging its drain. Only the
  /// fds named in these file actions survive: the dup'd stdout and stderr, and
  /// stdin, which `addinherit_np` preserves so a child that reads input still works.
  ///
  /// glibc has neither flag, so the pipe ends are already close-on-exec: they come
  /// from `pipe2(O_CLOEXEC)` (see `StreamingPipe`), which marks both ends
  /// non-inheritable at creation with no fcntl window a concurrent spawn could slip
  /// through. The `_np` inherit action does not exist either, so stdin (fd 0) is
  /// left untouched and inherited by default. The dup2 duplicates at fd 1 and 2
  /// carry no close-on-exec flag, so the child's stdout and stderr survive exec and
  /// reach the pipes, while the four `addclose` actions drop the originals in the
  /// child.
  private static func configureProcessGroupSpawn(
    _ attributes: inout SpawnAttributes,
    _ fileActions: inout SpawnFileActions,
    standardOutput: StreamingPipe,
    standardError: StreamingPipe
  ) -> Bool {
    let outputRead = standardOutput.fileHandleForReading.fileDescriptor
    let outputWrite = standardOutput.fileHandleForWriting.fileDescriptor
    let errorRead = standardError.fileHandleForReading.fileDescriptor
    let errorWrite = standardError.fileHandleForWriting.fileDescriptor
    #if canImport(Darwin)
      let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
      let attributesConfigured =
        posix_spawnattr_setflags(&attributes, spawnFlags) == 0
        && posix_spawnattr_setpgroup(&attributes, 0) == 0
        && posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO) == 0
    #else
      let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
      let attributesConfigured =
        posix_spawnattr_setflags(&attributes, spawnFlags) == 0
        && posix_spawnattr_setpgroup(&attributes, 0) == 0
    #endif
    return attributesConfigured
      && posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO) == 0
      && posix_spawn_file_actions_adddup2(&fileActions, errorWrite, STDERR_FILENO) == 0
      && posix_spawn_file_actions_addclose(&fileActions, outputRead) == 0
      && posix_spawn_file_actions_addclose(&fileActions, errorRead) == 0
      && posix_spawn_file_actions_addclose(&fileActions, outputWrite) == 0
      && posix_spawn_file_actions_addclose(&fileActions, errorWrite) == 0
  }

  /// Create a stdout or stderr pipe for the process-group spawn. On Darwin this is a
  /// plain `Pipe`; on glibc it is a `pipe2(O_CLOEXEC)` pair so both ends are
  /// close-on-exec at creation. Returns nil only when `pipe2` fails.
  #if canImport(Darwin)
    private static func makeStreamingPipe() -> StreamingPipe? {
      Pipe()
    }
  #else
    private static func makeStreamingPipe() -> StreamingPipe? {
      var descriptors: [Int32] = [-1, -1]
      let created = descriptors.withUnsafeMutableBufferPointer { buffer -> Bool in
        guard let base = buffer.baseAddress else {
          return false
        }
        return swiftMkPipe2(base, Int32(O_CLOEXEC)) == 0
      }
      guard created else {
        return nil
      }
      return StreamingPipe(
        fileHandleForReading: FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
        fileHandleForWriting: FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
    }
  #endif

  /// Build argv and envp and invoke `posix_spawn`, returning the child pid or nil
  /// on failure. envp inherits the parent environment when no overrides are set.
  private static func performProcessGroupSpawn(
    _ executable: String,
    _ arguments: [String],
    _ environment: [String: String],
    fileActions: inout SpawnFileActions,
    attributes: inout SpawnAttributes
  ) -> pid_t? {
    let argv = ["/usr/bin/env", executable] + arguments
    let envpStrings = childEnvironment(environment).map { merged in
      merged.map { "\($0.key)=\($0.value)" }
    }
    var pid: pid_t = -1
    let spawnStatus = withCStringArray(argv) { argvPointer -> Int32 in
      if let envpStrings {
        return withCStringArray(envpStrings) { envpPointer in
          posix_spawn(&pid, "/usr/bin/env", &fileActions, &attributes, argvPointer, envpPointer)
        } ?? ENOMEM
      }
      return posix_spawn(&pid, "/usr/bin/env", &fileActions, &attributes, argvPointer, environ)
    }
    guard let spawnStatus, spawnStatus == 0 else {
      return nil
    }
    return pid
  }

  /// Spawn a child into its OWN process group via `posix_spawn` with
  /// `POSIX_SPAWN_SETPGROUP`, so a timeout can kill the whole tree with
  /// `kill(-pid, ...)` rather than only the direct child. Foundation `Process`
  /// cannot set the child's process group, and a child inherits the parent's
  /// group, so a plain `kill(-pid)` would target the parent's group too. stdout
  /// and stderr run through pipes the parent drains, matching the `Process` path.
  static func spawnStreamingProcessGroup(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String]
  ) -> SpawnedStreamingProcess? {
    Output.debug("Shell.spawnStreamingProcessGroup \(executable)")
    guard let standardOutput = makeStreamingPipe(), let standardError = makeStreamingPipe() else {
      return nil
    }

    #if canImport(Darwin)
      var attributes: SpawnAttributes = nil
    #else
      var attributes = SpawnAttributes()
    #endif
    guard posix_spawnattr_init(&attributes) == 0 else {
      return nil
    }
    defer { posix_spawnattr_destroy(&attributes) }

    #if canImport(Darwin)
      var fileActions: SpawnFileActions = nil
    #else
      var fileActions = SpawnFileActions()
    #endif
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      return nil
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    guard
      configureProcessGroupSpawn(
        &attributes, &fileActions, standardOutput: standardOutput, standardError: standardError),
      let pid = performProcessGroupSpawn(
        executable, arguments, environment, fileActions: &fileActions, attributes: &attributes)
    else {
      return nil
    }
    // The parent drops its copies of the write ends so the read ends reach EOF
    // once the whole child group exits; only the child holds them as fd 1 and 2.
    standardOutput.fileHandleForWriting.closeFile()
    standardError.fileHandleForWriting.closeFile()
    return SpawnedStreamingProcess(
      processIdentifier: pid,
      standardOutput: standardOutput,
      standardError: standardError)
  }

  /// Decode a `waitpid` status into a shell-style exit code: the exit status for a
  /// normal exit, or 128 plus the signal number for a signalled child.
  static func decodeWaitStatus(_ status: Int32) -> Int32 {
    if status & waitStatusSignalMask == 0 {
      return (status >> waitStatusExitShift) & waitStatusExitByteMask
    }
    let terminatingSignal = status & waitStatusSignalMask
    if terminatingSignal != waitStatusStoppedMarker {
      return signalExitBase + terminatingSignal
    }
    return (status >> waitStatusExitShift) & waitStatusExitByteMask
  }

  /// Reap `processIdentifier`, retrying across `EINTR`. Bounded in practice: the
  /// caller SIGKILLs the process first, so the kernel guarantees it exits.
  static func reapProcessBlocking(_ processIdentifier: pid_t) -> Int32 {
    var status: Int32 = 0
    while true {
      let reaped = waitpid(processIdentifier, &status, 0)
      if reaped == processIdentifier {
        return decodeWaitStatus(status)
      }
      if reaped == -1, errno != EINTR {
        return launchFailureStatus
      }
    }
  }

  /// Kill a timed-out child's whole process group and reap it. Send SIGTERM to the
  /// group, wait a bounded grace for the tree to exit by waiting on the drain group
  /// (which completes when both pipe read ends hit EOF once every process holding
  /// the write ends has exited), then SIGKILL the group while the leader is still
  /// unreaped so its PID cannot be recycled into an unrelated group before the
  /// signal lands, and so a child that ignored SIGTERM cannot outlive the wrapper
  /// as a launchd runaway. Every wait here is bounded.
  static func terminateProcessGroupAndReap(
    _ process: SpawnedStreamingProcess, drainGroup: DispatchGroup
  ) -> Int32 {
    let processIdentifier = process.processIdentifier
    _ = kill(-processIdentifier, SIGTERM)
    _ = drainGroup.wait(timeout: .now() + timeoutTerminationGraceSeconds)
    _ = kill(-processIdentifier, SIGKILL)
    let status = reapProcessBlocking(processIdentifier)
    drainAndRelease(process, drainGroup: drainGroup)
    return status
  }

  /// Wait for the drain handlers to finish, bounded so a descendant that escaped
  /// the process group and kept a pipe write end open cannot hang the wrapper. On
  /// timeout, detach the readers and close the read ends; the captured stdout is
  /// whatever arrived before then.
  static func drainAndRelease(
    _ process: SpawnedStreamingProcess, drainGroup: DispatchGroup
  ) {
    guard drainGroup.wait(timeout: .now() + timeoutTerminationGraceSeconds) == .timedOut
    else {
      return
    }
    for handle in [
      process.standardOutput.fileHandleForReading,
      process.standardError.fileHandleForReading,
    ] {
      handle.readabilityHandler = nil
      do {
        try handle.close()
      } catch {
        Output.error("Shell: closing drained read handle failed: \(error)")
      }
    }
  }

  /// Call `body` with a NULL-terminated C string array built from `strings`,
  /// freeing every duplicated string afterward. Returns nil when a `strdup`
  /// allocation fails or the built buffer has no base address.
  static func withCStringArray<Value>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Value
  ) -> Value? {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    for string in strings {
      guard let pointer = strdup(string) else {
        for pointer in pointers {
          free(pointer)
        }
        return nil
      }
      pointers.append(pointer)
    }
    pointers.append(nil)
    defer {
      for pointer in pointers {
        free(pointer)
      }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer -> Value? in
      guard let base = buffer.baseAddress else {
        return nil
      }
      return body(base)
    }
  }
}
