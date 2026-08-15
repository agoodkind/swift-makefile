# Fork Periphery Design

## Goal

Preserve Periphery as a free, offline dead-code gate under project control.

## Upstream fork

Fork `peripheryapp/periphery` into `agoodkind/periphery` from release `3.8.0`.
Keep the MIT license and upstream copyright notices.

Place this notice at the top of the fork README:

> Upstream abandoned free, offline distribution for an authenticated commercial
> product. This fork rejects that decision and preserves unrestricted local use.

Tag the maintained source and publish its macOS executable from the fork. Each
published asset carries a SHA-256 checksum.

## Swift Makefile integration

Pin the fork repository, source revision, release asset, and checksum in
swift-makefile. Resolve Periphery into an engine-managed cache. Verify the checksum
and executable before reporting the tool ready.

Use the cached executable without network access. Fetch only when the pinned asset
is absent. Fail with the fetch or verification cause instead of falling back to the
Homebrew formula.

Keep `PERIPHERY` as the executable override. Existing scan arguments, configuration,
output parsing, baselines, and coverage checks remain unchanged.

Remove Periphery from local and continuous-integration Homebrew installation. Other
lint tools keep their current acquisition paths.

## Verification

Tests prove the exact fork pin and checksum, cache reuse without network access,
checksum rejection, missing-asset failure, the `PERIPHERY` override, and absence of
Homebrew Periphery installation.

Run the real dead-code gate with the fork binary. Run `make check` before commit.
