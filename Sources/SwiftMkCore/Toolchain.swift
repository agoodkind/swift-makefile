//
//  Toolchain.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Toolchain

/// The single sanctioned driver of the Xcode build toolchain. It is the one and
/// only place in the fleet allowed to spawn `tuist`, `xcodegen`, or `xcodebuild`.
/// Make consumers reach it through `swift-mk toolchain <op>`; Swift dev tools reach
/// it through a typed `import SwiftMkCore`. A swiftcheck rule and a make audit forbid
/// any other site from naming those tools, with no opt-out.
///
/// Why a chokepoint: a consumer that ran `tuist xcodebuild build` forwarded a bare
/// `xcodebuild -scheme` with no container, so xcodebuild auto-discovered the app
/// project and missed a Tuist-integrated external SPM dependency wired only at the
/// workspace level (the Automerge break). The fix is verified: native `tuist build`
/// and `tuist test --no-selective-testing` drive Tuist's own workspace and resolve
/// the dependency. So for a Tuist consumer this type emits native `tuist` commands,
/// never `tuist xcodebuild`. For an xcodegen consumer it emits an explicit
/// `xcodebuild -project ... -scheme ...`, never a bare auto-discovering invocation.
public enum Toolchain {
    /// The project generator a consumer uses.
    public enum Generator: String, Sendable {
        case tuist
        case xcodegen
    }

    /// A build/test request. A Tuist build names the `.xcworkspace`; an xcodegen
    /// build names the `.xcodeproj`. Either way xcodebuild is given an explicit
    /// container so it never auto-discovers, which is the Automerge-break fix.
    public struct Request: Sendable {
        public let generator: Generator
        public let scheme: String
        public let configuration: String
        public let workspace: String?
        public let project: String?
        public let destination: String?
        public let derivedDataPath: String?
        public let extraSettings: [String: String]
        /// Passthrough xcodebuild flags that are not `KEY=value` settings, such as
        /// `-allowProvisioningUpdates`, App Store Connect authentication options, or
        /// build-cache flags. A dev tool that needs these passes them here rather
        /// than naming xcodebuild itself.
        public let extraArguments: [String]

        public init(
            generator: Generator,
            scheme: String,
            configuration: String = "Debug",
            workspace: String? = nil,
            project: String? = nil,
            destination: String? = nil,
            derivedDataPath: String? = nil,
            extraSettings: [String: String] = [:],
            extraArguments: [String] = []
        ) {
            self.generator = generator
            self.scheme = scheme
            self.configuration = configuration
            self.workspace = workspace
            self.project = project
            self.destination = destination
            self.derivedDataPath = derivedDataPath
            self.extraSettings = extraSettings
            self.extraArguments = extraArguments
        }
    }

    // MARK: Project generation and dependencies

    /// Resolve external SPM dependencies. Tuist fetches into `Tuist/.build`; xcodegen
    /// has no dependency step.
    @discardableResult
    public static func installDependencies(_ generator: Generator) -> Int32 {
        switch generator {
        case .tuist:
            Output.info("toolchain: tuist install")
            return Shell.runForwardingOutput("tuist", ["install"])
        case .xcodegen:
            Output.info("toolchain: xcodegen has no dependency install step")
            return 0
        }
    }

    /// Generate the project (and, for Tuist, the workspace).
    @discardableResult
    public static func generate(_ generator: Generator) -> Int32 {
        switch generator {
        case .tuist:
            Output.info("toolchain: tuist generate")
            return Shell.runForwardingOutput("tuist", ["generate", "--no-open"])
        case .xcodegen:
            Output.info("toolchain: xcodegen generate")
            return Shell.runForwardingOutput("xcodegen", ["generate"])
        }
    }

    // MARK: Build and test

    /// Build the scheme. Both generators build with xcodebuild against an explicit
    /// container (workspace for Tuist, project for xcodegen). xcodebuild is used
    /// rather than `tuist build` because a consumer that packages its product reads
    /// it from a known `-derivedDataPath`, and `tuist build` writes to Tuist's own
    /// DerivedData instead. The explicit `-workspace` is what resolves a
    /// Tuist-integrated external SPM dependency (the Automerge-break fix).
    @discardableResult
    public static func build(_ request: Request) -> Int32 {
        Shell.runForwardingOutput(
            "xcodebuild", buildArguments(request), environment: signingEnvironment())
    }

    /// The signing override the chokepoint applies to a build, so swift-mk owns
    /// build-time signing on every path, including a Swift dev tool that calls
    /// `Toolchain.build` directly without the make signing prelude. A caller that
    /// already exported `XCODE_XCCONFIG_FILE` (the make prelude) keeps it, since
    /// inheriting the parent environment carries that value. Otherwise the override
    /// is written from the environment's identity and team; with neither set,
    /// `SigningBuildConfig.write` returns nil and the build keeps its own signing.
    /// This never injects ad-hoc: the style follows the identity a consumer set.
    static func signingEnvironment() -> [String: String] {
        if !Env.get("XCODE_XCCONFIG_FILE").isEmpty {
            return [:]
        }
        guard let path = SigningBuildConfig.write() else {
            return [:]
        }
        return ["XCODE_XCCONFIG_FILE": path]
    }

    /// Test the scheme. The Tuist path uses native `tuist test
    /// --no-selective-testing`, the verified path that runs the full suite and
    /// resolves external SPM (selective testing otherwise skips everything). The
    /// xcodegen path tests the explicit project with xcodebuild.
    @discardableResult
    public static func test(_ request: Request) -> Int32 {
        switch request.generator {
        case .tuist:
            return Shell.runForwardingOutput("tuist", tuistTestArguments(request))
        case .xcodegen:
            return Shell.runForwardingOutput(
                "xcodebuild", xcodebuildArguments(request, action: "test"))
        }
    }

    /// Build-for-testing the scheme, the coverage build the dead-code gate runs to
    /// fill the index store. Both generators build with xcodebuild against the
    /// explicit container, so the external SPM dependency resolves and the index is
    /// written under the consumer's `-derivedDataPath`.
    @discardableResult
    public static func buildForTesting(_ request: Request) -> Int32 {
        Shell.runForwardingOutput(
            "xcodebuild", xcodebuildArguments(request, action: "build-for-testing"))
    }

    /// Static-analyze the scheme with xcodebuild against the explicit container,
    /// applying the signing override like `build` so the analyze build signs the same
    /// way a real build would.
    @discardableResult
    public static func analyze(_ request: Request) -> Int32 {
        Shell.runForwardingOutput(
            "xcodebuild", xcodebuildArguments(request, action: "analyze"),
            environment: signingEnvironment())
    }

    // MARK: Read-only toolchain queries

    public static func version() -> String {
        Shell.run("xcodebuild", ["-version"]).stdout
    }

    /// `xcodebuild -list -json` for a workspace or project, captured. A read-only
    /// query, routed here so the chokepoint stays the only site that names
    /// xcodebuild.
    public static func listSchemes(container: String, isWorkspace: Bool) -> Shell.Result {
        let flag = isWorkspace ? "-workspace" : "-project"
        return Shell.run("xcodebuild", ["-list", "-json", flag, container])
    }

    @discardableResult
    public static func downloadComponent(_ name: String) -> Int32 {
        Output.info("toolchain: downloadComponent \(name)")
        return Shell.runForwardingOutput("xcodebuild", ["-downloadComponent", name])
    }

    // MARK: Argument assembly (exposed for tests)

    /// Build argument vector for xcodebuild. Both generators name an explicit
    /// container, so xcodebuild never auto-discovers: `-workspace` for Tuist,
    /// `-project` for xcodegen.
    static func buildArguments(_ request: Request) -> [String] {
        xcodebuildArguments(request, action: "build")
    }

    /// Tuist native test argument vector: `tuist test <scheme> --configuration <c>
    /// --no-selective-testing`. Selective testing otherwise skips the whole suite.
    static func tuistTestArguments(_ request: Request) -> [String] {
        [
            "test", request.scheme, "--configuration", request.configuration,
            "--no-selective-testing",
        ]
    }

    /// xcodebuild argument vector naming an explicit container. A Tuist request
    /// names its `-workspace`; an xcodegen request names its `-project`.
    static func xcodebuildArguments(_ request: Request, action: String) -> [String] {
        var args: [String] = []
        switch request.generator {
        case .tuist:
            guard let workspace = request.workspace else {
                Output.error("toolchain: tuist \(action) requires a workspace path")
                return ["-version"]
            }
            args.append(contentsOf: ["-workspace", workspace])
        case .xcodegen:
            guard let project = request.project else {
                Output.error("toolchain: xcodegen \(action) requires a project path")
                return ["-version"]
            }
            args.append(contentsOf: ["-project", project])
        }
        args.append(contentsOf: ["-scheme", request.scheme])
        args.append(contentsOf: ["-configuration", request.configuration])
        if let destination = request.destination {
            args.append(contentsOf: ["-destination", destination])
        }
        if let derivedDataPath = request.derivedDataPath {
            args.append(contentsOf: ["-derivedDataPath", derivedDataPath])
        }
        args.append(contentsOf: request.extraArguments)
        args.append(contentsOf: settingArguments(request.extraSettings))
        args.append(action)
        return args
    }

    private static func settingArguments(_ settings: [String: String]) -> [String] {
        var result: [String] = []
        for key in settings.keys.sorted() {
            guard let value = settings[key] else {
                continue
            }
            result.append("\(key)=\(value)")
        }
        return result
    }
}
