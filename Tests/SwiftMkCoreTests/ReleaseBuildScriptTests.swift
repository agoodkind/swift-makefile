//
//  ReleaseBuildScriptTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ReleaseBuildScriptTests

@Suite(.serialized)
enum ReleaseBuildScriptTests {
  @Test
  static func keepsTheSemanticTagSeparateFromTheArtifactFilename() throws {
    try withHarness { harness in
      let tag = "26.7.26-pre.202607261401+c95d264"
      let artifactVersion = "26.7.26-pre.202607261401-c95d264"
      let result = harness.run(tag: tag, artifactVersion: artifactVersion)
      try #require(result.status == 0)
      let engineArguments = try harness.engineArguments()
      let checksums = try harness.checksums()

      #expect(harness.sourceArchive(version: artifactVersion).pathExtension == "gz")
      #expect(
        FileManager.default.fileExists(atPath: harness.sourceArchive(version: artifactVersion).path)
      )
      #expect(!FileManager.default.fileExists(atPath: harness.sourceArchive(version: tag).path))
      #expect(engineArguments.contains("--tag \(tag)"))
      #expect(checksums.contains("swift-makefile-\(artifactVersion).tar.gz"))
    }
  }

  @Test
  static func rejectsAnUnsafeArtifactVersion() throws {
    try withHarness { harness in
      let result = harness.run(
        tag: "26.7.26-pre.202607261401+c95d264",
        artifactVersion: "../26.7.26-pre.202607261401-c95d264")

      #expect(result.status != 0)
      #expect(result.stderr.contains("ARTIFACT_VERSION has unsafe characters"))
    }
  }

  private static func withHarness(_ body: (Harness) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-release-build-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        Output.warning("cleanup failed: \(error.localizedDescription)")
      }
    }
    try body(Harness(directory: directory))
  }

  private struct Harness {
    let directory: URL
    let binDirectory: URL
    let distDirectory: URL
    let engineArgumentsFile: URL
    let fakeEngine: URL
    let releaseBuildScript: URL

    init(directory: URL) throws {
      self.directory = directory
      binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
      distDirectory = directory.appendingPathComponent("dist", isDirectory: true)
      engineArgumentsFile = directory.appendingPathComponent("engine-arguments")
      fakeEngine = binDirectory.appendingPathComponent("swift-mk")
      let scriptsDirectory = directory.appendingPathComponent("scripts", isDirectory: true)
      releaseBuildScript = scriptsDirectory.appendingPathComponent("release-build.sh")

      try FileManager.default.createDirectory(
        at: binDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: scriptsDirectory, withIntermediateDirectories: true)
      try copyReleaseBuildScript()
      try writeFakeGit()
      try writeFakeBuildResolver(in: scriptsDirectory)
      try writeFakeEngine()
    }

    func run(tag: String, artifactVersion: String) -> Shell.Result {
      Shell.run(
        "/bin/bash",
        [releaseBuildScript.path],
        environment: [
          "ARTIFACT_VERSION": artifactVersion,
          "ENGINE_ARGUMENTS_FILE": engineArgumentsFile.path,
          "FAKE_ENGINE": fakeEngine.path,
          "PATH":
            binDirectory.path + ":" + ProcessInfo.processInfo.environment["PATH", default: ""],
          "RELEASE_TAG": tag,
          "SWIFT_MK_DIST_DIR": distDirectory.path,
        ])
    }

    func sourceArchive(version: String) -> URL {
      distDirectory.appendingPathComponent("swift-makefile-\(version).tar.gz")
    }

    func engineArguments() throws -> String {
      try String(contentsOf: engineArgumentsFile, encoding: .utf8)
    }

    func checksums() throws -> String {
      try String(
        contentsOf: distDirectory.appendingPathComponent("checksums.txt"),
        encoding: .utf8)
    }

    private func copyReleaseBuildScript() throws {
      let source = try Self.repositoryPath(for: "scripts/release-build.sh")
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: source),
        to: releaseBuildScript)
    }

    private func writeFakeGit() throws {
      let executable = binDirectory.appendingPathComponent("git")
      let script = """
        #!/usr/bin/env bash
        set -euo pipefail

        output=""
        previous=""
        for argument in "$@"; do
            if [[ "${previous}" == "--output" ]]; then
                output="${argument}"
            fi
            previous="${argument}"
        done
        if [[ "$1" != "archive" || -z "${output}" ]]; then
            printf 'unexpected git call: %s\\n' "$*" >&2
            exit 2
        fi
        printf 'archive\\n' > "${output}"
        """
      try writeExecutable(script, to: executable)
    }

    private func writeFakeBuildResolver(in scriptsDirectory: URL) throws {
      let executable = scriptsDirectory.appendingPathComponent("swift-mk-build.sh")
      let script = """
        #!/usr/bin/env bash
        set -euo pipefail

        case "${1:-}" in
            resolve)
                ;;
            path)
                printf '%s\\n' "${FAKE_ENGINE}"
                ;;
            *)
                printf 'unexpected resolver call: %s\\n' "$*" >&2
                exit 2
                ;;
        esac
        """
      try writeExecutable(script, to: executable)
    }

    private func writeFakeEngine() throws {
      let script = """
        #!/usr/bin/env bash
        set -euo pipefail

        printf '%s\\n' "$*" > "${ENGINE_ARGUMENTS_FILE}"
        dist_dir=""
        while (( "$#" > 0 )); do
            if [[ "$1" == "--dist-dir" ]]; then
                dist_dir="$2"
                shift 2
            else
                shift
            fi
        done
        if [[ -z "${dist_dir}" ]]; then
            printf 'missing --dist-dir\\n' >&2
            exit 2
        fi
        printf 'dmg\\n' > "${dist_dir}/swift-mk_darwin_arm64.dmg"
        """
      try writeExecutable(script, to: fakeEngine)
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
      try contents.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: url.path)
    }

    private static func repositoryPath(for relativePath: String) throws -> String {
      var searchDirectory = (#filePath as NSString).deletingLastPathComponent
      while searchDirectory != "/" {
        let candidate = (searchDirectory as NSString).appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: candidate) {
          return candidate
        }
        searchDirectory = (searchDirectory as NSString).deletingLastPathComponent
      }
      throw ReleaseBuildScriptTestError.fileNotFound(relativePath)
    }
  }

  private enum ReleaseBuildScriptTestError: Error {
    case fileNotFound(String)
  }
}
