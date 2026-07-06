#!/usr/bin/env swift

import Foundation

// Keep the reusable workflow's non-trivial argument plumbing in one typed
// helper action. Swift handles JSON decoding, optional signing arguments, and
// argv construction with explicit types, while the composite action handles
// distribution to consumer repositories.

private enum WorkflowMode: String {
  case resolveExtraTargets = "resolve-extra-targets"
  case runMakeWithTeam = "run-make-with-team"
  case runMakeWithSigning = "run-make-with-signing"
  case runExtraTargets = "run-extra-targets"
  case validateSigningInputs = "validate-signing-inputs"
}

private enum WorkflowHelperError: LocalizedError {
  case missingMode
  case unknownMode(String)
  case missingEnvironmentValue(String)
  case invalidJSON(label: String, underlying: Error)
  case invalidJSONShape(label: String)
  case invalidJSONElement(label: String)
  case failedCommand(command: String, exitStatus: Int32)
  case missingSigningSecret(String)

  var errorDescription: String? {
    switch self {
    case .missingMode:
      return "workflow-helper: expected a subcommand"
    case let .unknownMode(mode):
      return "workflow-helper: unknown subcommand \(mode)"
    case let .missingEnvironmentValue(key):
      return "workflow-helper: \(key) is empty"
    case let .invalidJSON(label, underlying):
      return "\(label) must be a JSON array of strings: \(underlying.localizedDescription)"
    case let .invalidJSONShape(label):
      return "\(label) must be a JSON array of strings"
    case let .invalidJSONElement(label):
      return "\(label) must contain only strings"
    case let .failedCommand(command, exitStatus):
      return "\(command) exited with status \(exitStatus)"
    case let .missingSigningSecret(name):
      return
        "workflow-helper: \(name) is required for signed CI; "
        + "if this fails in a Dependabot run, check that the same secret name "
        + "is available as a Dependabot secret"
    }
  }
}

private struct Environment {
  private let values: [String: String]

  init(values: [String: String] = ProcessInfo.processInfo.environment) {
    self.values = values
  }

  func optional(_ key: String) -> String {
    values[key] ?? ""
  }

  func bool(_ key: String) -> Bool {
    ["1", "true", "yes"].contains(optional(key).lowercased())
  }

  func required(_ key: String) throws -> String {
    let value = optional(key)
    if value.isEmpty {
      throw WorkflowHelperError.missingEnvironmentValue(key)
    }
    return value
  }
}

private func splitWords(_ rawValue: String) -> [String] {
  rawValue.split(whereSeparator: \.isWhitespace).map(String.init)
}

private func runCommand(
  executable: String,
  arguments: [String],
  environmentOverrides: [String: String] = [:]
) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments
  process.environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, newValue in
    newValue
  }
  process.standardInput = FileHandle.standardInput
  process.standardOutput = FileHandle.standardOutput
  process.standardError = FileHandle.standardError

  try process.run()
  process.waitUntilExit()

  if process.terminationStatus != 0 {
    let renderedCommand = ([executable] + arguments).joined(separator: " ")
    throw WorkflowHelperError.failedCommand(
      command: renderedCommand,
      exitStatus: process.terminationStatus
    )
  }
}

private func makeArguments(
  target: String,
  makeArgs: String,
  signingArguments: [String]
) -> [String] {
  var commandArguments = [target]
  commandArguments.append(contentsOf: splitWords(makeArgs))
  commandArguments.append(contentsOf: signingArguments)
  return commandArguments
}

private func makeSigningArguments(
  certSHA1: String,
  codeSignKeychain: String,
  teamID: String
) -> [String] {
  var arguments: [String] = []
  if !certSHA1.isEmpty {
    arguments.append("CODE_SIGN_IDENTITY=\(certSHA1)")
  }
  if !codeSignKeychain.isEmpty {
    arguments.append("CODE_SIGN_KEYCHAIN=\(codeSignKeychain)")
  }
  if !teamID.isEmpty {
    arguments.append("DEVELOPMENT_TEAM=\(teamID)")
  }
  return arguments
}

private func requireSigningSecret(_ present: Bool, name: String) throws {
  guard present else {
    throw WorkflowHelperError.missingSigningSecret(name)
  }
}

private func validateSigningInputs(environment: Environment) throws {
  if environment.bool("IMPORT_SIGNING_CERT") {
    try requireSigningSecret(
      environment.bool("HAS_SIGNING_CERT"),
      name: "APPLE_DEVELOPER_ID_P12_BASE64"
    )
    try requireSigningSecret(
      environment.bool("HAS_SIGNING_PASSWORD"),
      name: "APPLE_DEVELOPER_ID_P12_PASSWORD"
    )
  }

  if environment.bool("INSTALL_PROVISIONING_PROFILE") {
    try requireSigningSecret(
      environment.bool("HAS_PROVISIONING_PROFILE"),
      name: "APPLE_DEVELOPER_ID_PROFILE_BASE64"
    )
  }
}

private func runMakeWithTeam(environment: Environment) throws {
  let makeTarget = try environment.required("MAKE_TARGET")
  let makeArgs = environment.optional("MAKE_ARGS")
  let teamID = environment.optional("TEAM_ID")

  var signingArguments: [String] = []
  if !teamID.isEmpty {
    signingArguments.append("DEVELOPMENT_TEAM=\(teamID)")
  }

  try runCommand(
    executable: "make",
    arguments: makeArguments(
      target: makeTarget,
      makeArgs: makeArgs,
      signingArguments: signingArguments
    )
  )
}

private func runMakeWithSigning(environment: Environment) throws {
  let makeTarget = try environment.required("MAKE_TARGET")
  let makeArgs = environment.optional("MAKE_ARGS")
  let certSHA1 = environment.optional("CERT_SHA1")
  let codeSignKeychain = environment.optional("CODE_SIGN_KEYCHAIN")
  let teamID = environment.optional("TEAM_ID")

  let signingArguments = makeSigningArguments(
    certSHA1: certSHA1,
    codeSignKeychain: codeSignKeychain,
    teamID: teamID)

  try runCommand(
    executable: "make",
    arguments: makeArguments(
      target: makeTarget,
      makeArgs: makeArgs,
      signingArguments: signingArguments
    )
  )
}

private func runExtraTargets(environment: Environment) throws {
  let rawExtraTargets = try environment.required("EXTRA_TARGETS_SHELL")
  let makeArgs = environment.optional("MAKE_ARGS")
  let certSHA1 = environment.optional("CERT_SHA1")
  let codeSignKeychain = environment.optional("CODE_SIGN_KEYCHAIN")
  let teamID = environment.optional("TEAM_ID")

  let signingArguments = makeSigningArguments(
    certSHA1: certSHA1,
    codeSignKeychain: codeSignKeychain,
    teamID: teamID)

  for target in splitWords(rawExtraTargets) {
    print("extra-targets: running \(target)")
    try runCommand(
      executable: "make",
      arguments: makeArguments(
        target: target,
        makeArgs: makeArgs,
        signingArguments: signingArguments
      )
    )
  }
}

private func parseTargets(rawJSON: String, label: String) throws -> [String] {
  let data = Data(rawJSON.utf8)

  let decodedValue: Any
  do {
    decodedValue = try JSONSerialization.jsonObject(with: data)
  } catch {
    throw WorkflowHelperError.invalidJSON(label: label, underlying: error)
  }

  guard let rawTargets = decodedValue as? [Any] else {
    throw WorkflowHelperError.invalidJSONShape(label: label)
  }

  var parsedTargets: [String] = []
  for rawTarget in rawTargets {
    guard let target = rawTarget as? String else {
      throw WorkflowHelperError.invalidJSONElement(label: label)
    }

    let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedTarget.isEmpty {
      continue
    }
    parsedTargets.append(trimmedTarget)
  }

  return parsedTargets
}

private func collectExtraTargets(
  explicitTargets: [String],
  legacyTargets: [String],
  builtInTargets: Set<String>
) -> [String] {
  var combinedTargets: [String] = []
  var seenTargets = Set<String>()

  for target in explicitTargets + legacyTargets {
    let normalizedTarget = target.lowercased()
    if builtInTargets.contains(normalizedTarget) {
      continue
    }
    if seenTargets.contains(target) {
      continue
    }

    combinedTargets.append(target)
    seenTargets.insert(target)
  }

  return combinedTargets
}

private func appendOutputLine(name: String, value: String, outputPath: String) throws {
  let line = "\(name)=\(value)\n"
  guard let lineData = line.data(using: .utf8) else {
    return
  }

  let fileURL = URL(fileURLWithPath: outputPath)
  if FileManager.default.fileExists(atPath: outputPath) {
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: lineData)
    return
  }

  try lineData.write(to: fileURL)
}

private func resolveExtraTargets(environment: Environment) throws {
  let explicitTargets = try parseTargets(
    rawJSON: environment.optional("EXTRA_TARGETS").isEmpty ? "[]" : environment.optional("EXTRA_TARGETS"),
    label: "EXTRA_TARGETS"
  )
  let legacyTargets = try parseTargets(
    rawJSON: environment.optional("LEGACY_TARGETS").isEmpty ? "[]" : environment.optional("LEGACY_TARGETS"),
    label: "LEGACY_TARGETS"
  )
  let builtInTargets = try parseTargets(
    rawJSON: environment.required("BUILTIN_TARGETS_JSON"),
    label: "BUILTIN_TARGETS_JSON"
  )
  let outputPath = try environment.required("GITHUB_OUTPUT")
  let combinedTargets = collectExtraTargets(
    explicitTargets: explicitTargets,
    legacyTargets: legacyTargets,
    builtInTargets: Set(builtInTargets.map { $0.lowercased() })
  )
  let targetsJSON = String(data: try JSONEncoder().encode(combinedTargets), encoding: .utf8) ?? "[]"
  let targetsShell = combinedTargets.joined(separator: " ")

  try appendOutputLine(name: "targets", value: targetsJSON, outputPath: outputPath)
  try appendOutputLine(name: "targets_shell", value: targetsShell, outputPath: outputPath)
  try appendOutputLine(name: "count", value: String(combinedTargets.count), outputPath: outputPath)

  print("extra-targets: resolved \(targetsJSON)")
}

private func selectedMode() throws -> WorkflowMode {
  guard CommandLine.arguments.count > 1 else {
    throw WorkflowHelperError.missingMode
  }
  let rawMode = CommandLine.arguments[1]
  guard let mode = WorkflowMode(rawValue: rawMode) else {
    throw WorkflowHelperError.unknownMode(rawMode)
  }
  return mode
}

private func main() throws {
  let mode = try selectedMode()
  let environment = Environment()

  switch mode {
  case .resolveExtraTargets:
    try resolveExtraTargets(environment: environment)
  case .runMakeWithTeam:
    try runMakeWithTeam(environment: environment)
  case .runMakeWithSigning:
    try runMakeWithSigning(environment: environment)
  case .runExtraTargets:
    try runExtraTargets(environment: environment)
  case .validateSigningInputs:
    try validateSigningInputs(environment: environment)
  }
}

do {
  try main()
} catch {
  fputs("\(error.localizedDescription)\n", stderr)
  exit(1)
}
