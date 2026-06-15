//
//  GateProof.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(Darwin)
  import Darwin
#endif

// MARK: - GateProof

/// Proof that a compile is running inside a swift-mk gated invocation.
///
/// `make build` is the chokepoint: `swift-mk build` runs the lint gates, then
/// runs the consumer's build command. The real compile lives downstream of the
/// gate, so a dev tool's compile subcommand invoked directly skips it. A static
/// env token cannot close that hole: an agent reads the name and sets it. The
/// proof here is unsatisfiable by setting a value; it requires actually running
/// the gate, and it layers three factors:
///
///   A. Freshness stamp: a passing gated entry writes `.make/.gate/stamp` with an
///      expiry, plus a digest of the tracked sources. The expiry is enforced; the
///      source digest is reported for diagnostics but not enforced, since
///      mid-build code generation can legitimately change a tracked source.
///   B. Live ancestor: the stamp names the gate process's pid. The verifier
///      requires that pid to be a live swift-mk process in its own ancestry. An
///      agent cannot make a swift-mk gate process its ancestor without running
///      the gate, so this factor is not forgeable by writing files or env.
///   C. Process identity: the stamp records the gate process's start time, and
///      the verifier requires the live ancestor's start time to match. This binds
///      factor B to the exact process instance that ran the gate, so a recycled
///      pid (a new process reusing the gate's old pid) cannot satisfy it. The
///      stamp carries it rather than an inherited fd, which Foundation's process
///      spawning drops, and rather than the environment, which Foundation caches.
///
/// Honest limit: on a single-user machine with readable source nothing is
/// cryptographically unforgeable. The goal is that the lazy path is to gate and
/// any bypass is deliberate. A hand-run `swift build` in the shell is out of
/// scope; this guards the project's own build entrypoints.
public enum GateProof {
  /// The stamp path relative to the repo root.
  static let stampRelativeComponents = [".make", ".gate", "stamp"]

  /// How long a stamp authorizes compiles after it is written. A real build can
  /// be long, so the window is generous; factor B (live ancestor) is what stops
  /// a stale stamp from authorizing a later ungated compile.
  static let freshnessWindowSeconds: Double = 3_600

  /// The process status returned when a compile is refused for lack of proof.
  /// `EX_SOFTWARE` (70) marks an internal precondition failure.
  static let refusedExitStatus: Int32 = 70

  /// Maximum ancestry depth walked when looking for the gate process, a backstop
  /// against a pid cycle.
  static let maxAncestorDepth = 64

  /// Bytes of randomness in a stamp nonce.
  static let nonceByteCount = 16

  /// Microseconds per second, converting a process start time to seconds.
  static let microsecondsPerSecond: Double = 1_000_000

  // MARK: Producer

  /// Mark this process as a gated invocation. Called at the top of every gated
  /// entrypoint. Idempotent within a process: a second call is a no-op so nested
  /// gates (lint inside build) do not rewrite the stamp. Being inside a gated
  /// entry means the gate is on the call stack; if the gates fail, the entry
  /// returns before any compile runs, so the mark authorizing compiles is sound.
  public static func mark(context: PathContext = .current()) {
    let myPid = currentPid()
    if markedPid == myPid {
      return
    }
    markedPid = myPid

    let stamp = Stamp(
      nonce: randomNonce(),
      sourceHash: sourceDigest(context: context),
      gatePid: myPid,
      gateStartTime: processStartTime(of: myPid) ?? 0,
      createdAt: nowSeconds())
    writeStamp(stamp, context: context)
  }

  // MARK: Verifier

  /// The refusal status for a compile that lacks the gate proof, or nil when the
  /// proof holds. Emits the loud cause before returning a status, so a
  /// status-returning caller (the toolchain build) reports it without an
  /// `exit()` inside the library. Returns `refusedExitStatus` when ungated.
  public static func refusal(
    entry: String, context: PathContext = .current(), requireLiveAncestor: Bool = true
  ) -> Int32? {
    if isGated(context: context, requireLiveAncestor: requireLiveAncestor) {
      return nil
    }
    Output.error(
      "\(entry): refused. This compile did not run inside the swift-mk lint gate, "
        + "so it would produce an ungated artifact. Run `make build` (it runs "
        + "log-audit, swift-format, swiftlint, complexity, periphery, then this "
        + "compile). Invoking the dev tool's compile subcommand directly, or "
        + "`swift-mk toolchain build` outside `make build`, bypasses the gate and "
        + "is refused.")
    return refusedExitStatus
  }

  /// Whether a valid gate proof covers this process. Pure of side effects so it
  /// is testable; `refusal` wraps it with the loud message and a status.
  ///
  /// With `requireLiveAncestor` (the default, for a product-compile leaf), three
  /// factors are enforced: freshness, a live swift-mk ancestor, and that
  /// ancestor's process identity (start time). A secondary or helper build (a
  /// Metal or resource compile, an install/deploy step) runs after the gated
  /// `make build` process has exited, so it passes `false` and only freshness is
  /// enforced: a recent gate proves the build flow ran, while a cold standalone
  /// compile with no gate at all still has no stamp and is refused. The recorded
  /// source digest is diagnostic only, not enforced: mid-build code generation
  /// can legitimately rewrite a tracked source between the gate and the compile,
  /// and the forgery resistance comes from the live-ancestor and identity factors,
  /// which a file or env write cannot satisfy.
  static func isGated(
    context: PathContext = .current(), requireLiveAncestor: Bool = true
  ) -> Bool {
    guard let stamp = readStamp(context: context) else {
      return false
    }
    // (A) Freshness: a gate wrote the stamp within the window.
    guard nowSeconds() - stamp.createdAt <= freshnessWindowSeconds else {
      return false
    }
    // A helper build cannot require a live gate ancestor: the gated build that
    // produced the fresh stamp has already exited by the time it runs.
    guard requireLiveAncestor else {
      return true
    }
    // (B) The gate pid is a live swift-mk process in this process's ancestry.
    guard ancestorPids().contains(stamp.gatePid), processIsSwiftMk(stamp.gatePid) else {
      return false
    }
    // (C) The live ancestor is the same process instance that wrote the stamp:
    // its start time matches. Skipped only when the gate could not record a start
    // time (stored 0), so an unavailable start time never false-refuses.
    if stamp.gateStartTime != 0 {
      guard processStartTime(of: stamp.gatePid) == stamp.gateStartTime else {
        return false
      }
    }
    return true
  }

  // MARK: Diagnostics

  /// A one-line verdict a child process prints, so a parent gate can confirm the
  /// proof crosses a real process boundary. Reports each factor so a failure
  /// names which one did not hold.
  public static func probeReport(context: PathContext = .current()) -> String {
    guard let stamp = readStamp(context: context) else {
      return "gated=false reason=no-stamp"
    }
    let fresh = nowSeconds() - stamp.createdAt <= freshnessWindowSeconds
    let sourceMatch = stamp.sourceHash == sourceDigest(context: context)
    let ancestor = ancestorPids().contains(stamp.gatePid)
    let isSwiftMk = processIsSwiftMk(stamp.gatePid)
    let startMatch =
      stamp.gateStartTime == 0
      || processStartTime(of: stamp.gatePid) == stamp.gateStartTime
    let gated = fresh && sourceMatch && ancestor && isSwiftMk && startMatch
    return
      "gated=\(gated) fresh=\(fresh) source=\(sourceMatch) ancestor=\(ancestor) "
      + "swiftmk=\(isSwiftMk) startMatch=\(startMatch) gatePid=\(stamp.gatePid)"
  }

  /// Mark this process as a gate, then spawn the same binary running
  /// `gate-proof probe` and report whether the child saw the proof. This
  /// exercises factors A, B, and C across a real parent/child boundary using the
  /// actual swift-mk binary, so the cross-process mechanism is verifiable without
  /// a full consumer build. Returns the child's full report line.
  public static func selftest(context: PathContext = .current()) -> String {
    mark(context: context)
    let selfPath = currentExecutablePath()
    guard !selfPath.isEmpty else {
      return "gated=false reason=no-self-path"
    }
    Output.debug("gate-proof: selftest spawning probe child at \(selfPath)")
    let result = Shell.run(selfPath, ["gate-proof", "probe"])
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Stamp model

  struct Stamp: Equatable {
    let nonce: String
    let sourceHash: String
    let gatePid: Int32
    let gateStartTime: Double
    let createdAt: Double

    /// Serialize as a small, fixed-order key=value text, one pair per line.
    func serialized() -> String {
      [
        "nonce=\(nonce)",
        "sourceHash=\(sourceHash)",
        "gatePid=\(gatePid)",
        "gateStartTime=\(gateStartTime)",
        "createdAt=\(createdAt)",
      ].joined(separator: "\n") + "\n"
    }

    /// Parse the serialized form. Returns nil when any field is missing or
    /// malformed, so a truncated or tampered stamp does not authorize.
    static func parse(_ text: String) -> Stamp? {
      var fields: [String: String] = [:]
      for line in text.split(separator: "\n") {
        guard let equals = line.firstIndex(of: "=") else {
          continue
        }
        let key = String(line[..<equals])
        let value = String(line[line.index(after: equals)...])
        fields[key] = value
      }
      guard let parsedNonce = fields["nonce"], !parsedNonce.isEmpty,
        let parsedHash = fields["sourceHash"], !parsedHash.isEmpty,
        let pidText = fields["gatePid"], let parsedPid = Int32(pidText),
        let startText = fields["gateStartTime"], let parsedStart = Double(startText),
        let createdText = fields["createdAt"], let parsedCreated = Double(createdText)
      else {
        return nil
      }
      return Stamp(
        nonce: parsedNonce,
        sourceHash: parsedHash,
        gatePid: parsedPid,
        gateStartTime: parsedStart,
        createdAt: parsedCreated)
    }
  }

  static func stampURL(context: PathContext) -> URL {
    var url = URL(fileURLWithPath: context.cwd, isDirectory: true)
    for component in stampRelativeComponents {
      url = url.appendingPathComponent(component)
    }
    return url
  }

  private static func writeStamp(_ stamp: Stamp, context: PathContext) {
    let url = stampURL(context: context)
    let directory = url.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      try stamp.serialized().write(to: url, atomically: true, encoding: .utf8)
    } catch {
      Output.error("gate-proof: could not write stamp at \(url.path): \(error)")
    }
  }

  static func readStamp(context: PathContext) -> Stamp? {
    let url = stampURL(context: context)
    let text: String
    do {
      text = try String(contentsOf: url, encoding: .utf8)
    } catch {
      // No stamp (or unreadable) means no proof; the caller refuses. A missing
      // file is the common case (no gate ran), not an error to surface.
      return nil
    }
    return Stamp.parse(text)
  }

  // MARK: Source digest

  /// Source file extensions whose content binds the proof to the working tree.
  static let sourceExtensions: Set<String> = ["swift", "mk", "h", "m", "c", "metal"]

  /// Directory names that never contribute to the source digest: build output,
  /// caches, vcs metadata, and vendored package checkouts.
  static let digestExcludedDirectories: Set<String> = [
    ".git", ".build", ".make", "DerivedData", "Derived", "Products",
    "SourcePackages", "node_modules", ".swiftpm", "build", ".tuist", "Pods",
  ]

  /// A stable digest of the tracked source set under the repo root: for each
  /// source file, its repo-relative path, size, and modification time. Recomputed
  /// identically at mark and verify, so a source edited between the gate and the
  /// compile flips the digest and fails the freshness factor. Fast: it stats
  /// files, never reads their contents.
  static func sourceDigest(context: PathContext) -> String {
    let root = URL(fileURLWithPath: context.cwd, isDirectory: true)
    let rootPath = root.standardizedFileURL.path
    var entries: [String] = []
    let manager = FileManager.default
    guard
      let enumerator = manager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else {
      return "empty"
    }
    for case let item as URL in enumerator {
      let values: URLResourceValues?
      do {
        values = try item.resourceValues(forKeys: [
          .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
      } catch {
        // A file that cannot be stat'd does not contribute to the digest; the
        // digest is a best-effort change signal, not enforced.
        Output.warning("gate-proof: skipping unreadable source \(item.path): \(error)")
        values = nil
      }
      if values?.isDirectory == true {
        if digestExcludedDirectories.contains(item.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard sourceExtensions.contains(item.pathExtension) else {
        continue
      }
      let path = item.standardizedFileURL.path
      let relative =
        path.hasPrefix(rootPath + "/")
        ? String(path.dropFirst(rootPath.count + 1)) : path
      let size = values?.fileSize ?? 0
      let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
      entries.append("\(relative)\u{0}\(size)\u{0}\(mtime)")
    }
    entries.sort()
    return fnv1aHex(entries.joined(separator: "\n"))
  }

  /// A fast, deterministic 64-bit FNV-1a digest as lowercase hex. Used to detect
  /// a source change between the gate and the compile, not as a cryptographic
  /// boundary, so a non-cryptographic hash is the right tool: the proof's
  /// forgery resistance is the live-ancestor factor, not this digest.
  static func fnv1aHex(_ text: String) -> String {
    let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    let prime: UInt64 = 0x0000_0100_0000_01b3
    var hash = offsetBasis
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* prime
    }
    return String(format: "%016llx", hash)
  }

  // MARK: Process ancestry (Darwin)

  /// The pid chain from this process up to the root, this process first. Walks
  /// `getppid` via sysctl so a verifier can confirm the gate process is a genuine
  /// ancestor rather than merely alive.
  static func ancestorPids() -> [Int32] {
    var chain: [Int32] = []
    var pid = currentPid()
    var guardCount = 0
    while pid > 1, guardCount < maxAncestorDepth {
      chain.append(pid)
      let parent = parentPid(of: pid)
      if parent <= 0 || parent == pid {
        break
      }
      pid = parent
      guardCount += 1
    }
    return chain
  }

  #if canImport(Darwin)
    static func parentPid(of pid: Int32) -> Int32 {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
      guard result == 0, size > 0 else {
        return -1
      }
      return info.kp_eproc.e_ppid
    }

    /// Whether the process with `pid` is alive and its executable basename is
    /// `swift-mk`. A dead pid or a non-swift-mk process fails the ancestry factor.
    static func processIsSwiftMk(_ pid: Int32) -> Bool {
      var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
      guard length > 0 else {
        return false
      }
      let path = String(cString: pathBuffer)
      let basename = (path as NSString).lastPathComponent
      return basename == "swift-mk"
    }

    /// The start time of the process with `pid` in seconds since the epoch, or nil
    /// when it cannot be read. Binds the ancestry factor to the exact process
    /// instance, so a recycled pid does not satisfy the proof.
    static func processStartTime(of pid: Int32) -> Double? {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
        return nil
      }
      let started = info.kp_proc.p_un.__p_starttime
      return Double(started.tv_sec) + Double(started.tv_usec) / microsecondsPerSecond
    }
  #else
    static func parentPid(of _: Int32) -> Int32 { -1 }
    static func processIsSwiftMk(_: Int32) -> Bool { false }
    static func processStartTime(of _: Int32) -> Double? { nil }
  #endif

  // MARK: Primitives

  private static func currentPid() -> Int32 {
    getpid()
  }

  /// The absolute path of the running executable, used to spawn the same binary
  /// for the self-test. Empty when it cannot be resolved.
  static func currentExecutablePath() -> String {
    #if canImport(Darwin)
      var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      let length = proc_pidpath(getpid(), &pathBuffer, UInt32(pathBuffer.count))
      if length > 0 {
        return String(cString: pathBuffer)
      }
    #endif
    return CommandLine.arguments.first ?? ""
  }

  private static func nowSeconds() -> Double {
    Date().timeIntervalSince1970
  }

  private static func randomNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: nonceByteCount)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  // Track the pid this process marked, so `mark` is idempotent across nested
  // gated entries within one process.
  nonisolated(unsafe) private static var markedPid: Int32 = -1
}
