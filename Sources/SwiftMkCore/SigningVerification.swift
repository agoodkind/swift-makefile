//
//  SigningVerification.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  swift-mk: signing-not-required
//  This file runs `xcodebuild -showBuildSettings` only to read the resolved
//  settings, never to build or sign, so it does not route through
//  applyEnvironmentOverride; the opt-out marker above keeps the unrouted-xcodebuild
//  gate from flagging it.

import Foundation

// MARK: - SigningVerification

/// Verifies the build-time signature actually matches what swift-mk resolves, so a
/// setting that beats the `XCODE_XCCONFIG_FILE` override is caught rather than
/// assumed away.
///
/// Two complementary checks, both comparing against `SigningBuildConfig`'s resolved
/// inputs so the expectation is inferred, never restated:
///
/// - `verifySettings` reads `xcodebuild -showBuildSettings` before a build and
///   fails when a target's effective signing does not match the override.
/// - `verifyArtifacts` reads `codesign` on the produced bundles after a build and
///   fails when an artifact is ad-hoc where a team was expected, or carries the
///   wrong `TeamIdentifier`.
///
/// When neither an identity nor a team is set, both checks pass: an unsigned build
/// is a valid configuration and swift-mk forces nothing.
public enum SigningVerification {
    static let adHocIdentity = "-"

    // MARK: - Artifacts (post-build codesign)

    /// Verify each artifact's on-disk signature against the resolved inputs.
    @discardableResult
    public static func verifyArtifacts(
        paths: [String], localXcconfigPaths: [String] = []
    ) -> Bool {
        let expected = SigningBuildConfig.resolvedInputs(localXcconfigPaths: localXcconfigPaths)
        let identity = expected.identity.trimmingCharacters(in: .whitespaces)
        let team = expected.team.trimmingCharacters(in: .whitespaces)
        if identity.isEmpty, team.isEmpty {
            Output.info("verify-signing: no signing values set; skipping artifact check")
            return true
        }
        let expectAdHoc = identity == adHocIdentity
        var allPass = true
        for path in paths {
            let signed = verifyArtifact(
                path: path, expectAdHoc: expectAdHoc, expectedTeam: team)
            if !signed {
                allPass = false
            }
        }
        return allPass
    }

    private static func verifyArtifact(
        path: String, expectAdHoc: Bool, expectedTeam: String
    ) -> Bool {
        Output.info("verify-signing: codesign \(path)")
        let result = Shell.run("codesign", ["-dvvv", path])
        let satisfied = artifactSignatureSatisfies(
            output: result.combined,
            status: result.status,
            expectAdHoc: expectAdHoc,
            expectedTeam: expectedTeam)
        if satisfied {
            Output.info("verify-signing: \(path) signature ok")
        } else {
            let teamValue = firstValue(in: result.combined, prefix: "TeamIdentifier=")
            Output.error(
                "verify-signing: \(path) failed; status=\(result.status) "
                    + "TeamIdentifier=\(teamValue ?? "not set") expectedTeam=\(expectedTeam)")
        }
        return satisfied
    }

    /// The pure pass/fail decision for one artifact's `codesign` output. A non-zero
    /// status fails. When ad-hoc is expected, any readable signature passes. When a
    /// team is expected, an ad-hoc signature or a wrong/absent `TeamIdentifier`
    /// fails. Extracted from the codesign call so the decision is unit-tested.
    static func artifactSignatureSatisfies(
        output: String, status: Int32, expectAdHoc: Bool, expectedTeam: String
    ) -> Bool {
        if status != 0 {
            return false
        }
        if expectAdHoc {
            return true
        }
        if output.contains("Signature=adhoc") {
            return false
        }
        if expectedTeam.isEmpty {
            return true
        }
        return firstValue(in: output, prefix: "TeamIdentifier=") == expectedTeam
    }

    // MARK: - Settings (pre-build xcodebuild -showBuildSettings)

    /// Verify the effective build settings of a workspace scheme against the
    /// resolved inputs, catching a command-line or target value that beats the
    /// override before a build runs.
    @discardableResult
    public static func verifySettings(
        workspace: String,
        scheme: String,
        configuration: String? = nil,
        localXcconfigPaths: [String] = []
    ) -> Bool {
        let expected = SigningBuildConfig.resolvedInputs(localXcconfigPaths: localXcconfigPaths)
        let identity = expected.identity.trimmingCharacters(in: .whitespaces)
        let team = expected.team.trimmingCharacters(in: .whitespaces)
        if identity.isEmpty, team.isEmpty {
            Output.info("verify-signing: no signing values set; skipping settings check")
            return true
        }
        var arguments = ["-showBuildSettings", "-workspace", workspace, "-scheme", scheme]
        if let configuration {
            arguments.append(contentsOf: ["-configuration", configuration])
        }
        Output.info("verify-signing: reading build settings scheme=\(scheme)")
        let result = Shell.run("xcodebuild", arguments)
        if result.status != 0 {
            Output.error(
                "verify-signing: xcodebuild -showBuildSettings failed for scheme \(scheme)")
            return false
        }
        return settingsMatch(output: result.stdout, expectedIdentity: identity, expectedTeam: team)
    }

    /// The pure pass/fail decision for `xcodebuild -showBuildSettings` output.
    /// Every target's `CODE_SIGN_IDENTITY` must match the expectation (ad-hoc `-`
    /// when ad-hoc is expected, never `-` otherwise, equal to a named identity when
    /// one is set), and every `DEVELOPMENT_TEAM` must equal the expected team.
    /// Internal so it is unit-tested without invoking xcodebuild.
    static func settingsMatch(
        output: String, expectedIdentity: String, expectedTeam: String
    ) -> Bool {
        let expectAdHoc = expectedIdentity == adHocIdentity
        var allPass = true
        for value in values(in: output, key: "CODE_SIGN_IDENTITY") {
            if expectAdHoc {
                if value != adHocIdentity {
                    Output.error("verify-signing: CODE_SIGN_IDENTITY=\(value); expected ad-hoc -")
                    allPass = false
                }
                continue
            }
            if value == adHocIdentity {
                Output.error(
                    "verify-signing: a target is ad-hoc (CODE_SIGN_IDENTITY = -); expected signed")
                allPass = false
                continue
            }
            if !expectedIdentity.isEmpty, value != expectedIdentity {
                Output.error(
                    "verify-signing: CODE_SIGN_IDENTITY=\(value); expected \(expectedIdentity)")
                allPass = false
            }
        }
        if !expectedTeam.isEmpty {
            for value in values(in: output, key: "DEVELOPMENT_TEAM") where value != expectedTeam {
                Output.error("verify-signing: DEVELOPMENT_TEAM=\(value); expected \(expectedTeam)")
                allPass = false
            }
        }
        return allPass
    }

    // MARK: - Parsing

    /// The value of the first line beginning with `prefix`, or nil when absent or
    /// when codesign reports the field as `not set`.
    private static func firstValue(in output: String, prefix: String) -> String? {
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else {
                continue
            }
            let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    /// Every right-hand side of `    KEY = value` lines from `xcodebuild
    /// -showBuildSettings`, one per target that defines the key.
    private static func values(in output: String, key: String) -> [String] {
        var found: [String] = []
        let prefix = key + " = "
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(prefix) {
                found.append(
                    String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return found
    }
}
