# Signing

swift-makefile is the single source of truth for build-time code signing. A consumer declares an identity and a team, and the engine derives every signing setting, so a consumer carries no per-target signing configuration.

## The override wins

[`SigningBuildConfig`](../../Sources/SwiftMkCore/SigningBuildConfig.swift) writes an `XCODE_XCCONFIG_FILE` that the engine passes to the build. An `xcconfig` override outranks command-line, target, and project settings, so the engine's signing settings win over anything a consumer project declares.

## Style is inferred, not chosen

The engine infers the signing style from the identity and team rather than letting a caller pick it. Ad-hoc "Sign to Run Locally" is never a silent fallback for a release build; the allowlist for the one place ad-hoc is valid is in [AdHocSigningAllowlistTests](../../Tests/SwiftMkCoreTests/AdHocSigningAllowlistTests.swift).

## Post-build signing and notarization

[`Codesign`](../../Sources/SwiftMkCore/Codesign.swift) signs a built product, [`Notarize`](../../Sources/SwiftMkCore/Notarize.swift) submits it to Apple and staples the ticket, and [`SigningVerification`](../../Sources/SwiftMkCore/SigningVerification.swift) confirms the result. Consumer files reach the codesign binary only through the engine; [`BuildToolingAudit`](../../Sources/SwiftMkCore/BuildToolingAudit.swift) fails the gate on a direct `codesign` invocation.

## The dead-code coverage build is the one carve-out

The dead-code coverage build disables signing on purpose, because a signed build can fail provisioning and leave a partial index. That carve-out lives in the [dead-code gate](../deadcode/overview.md); every other build signs through the engine.

## Signing on the self-hosted pool

The engine needs no pool-specific configuration to sign on the self-hosted macOS runner pool. The signing action creates a keychain, imports the identity, and adds the keychain to the search list inside the runner's session, and the engine runs `codesign` in that same session.

Signing on the pool works only because the pool places the runner in the machine's graphical login session with the login user's real home folder, which is where `codesign` resolves the signing identity. The `gha-mac-broker` runner pool owns that arrangement; its `docs/runnerpool/signing.md` explains why the session and home folder decide whether signing succeeds.
