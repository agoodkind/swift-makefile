# Release Track Contract

The shared release workflow keeps pre-release and stable artifacts separate so automatic updates stay on the installed track.

Pre-release is the human-facing term. Workflow inputs, variables, and paths use `prerelease`, while tags and artifact names use `pre`.

Pre-release tags use `26.7.26-pre.202607261030+abc1234`. Their artifact versions replace `+` with `-`, so a DMG can use `FanCurve-26.7.26-pre.202607261030-abc1234.dmg`.

Stable tags use `26.7.26`, `26.7.26-r1`, and later same-day revisions. Stable DMGs use the matching tag, such as `FanCurve-26.7.26-r1.dmg`.

Every distributable build keeps `CFBundleShortVersionString` at the base calendar version. `CFBundleVersion` combines `yyyyMMddHHmm` with the six-digit `GITHUB_RUN_NUMBER`, such as `202607261030000087`. The workflow rejects missing, nonnumeric, zero, and more-than-six-digit run numbers.

A stable release normally selects a published pre-release through `candidate-tag`. The selected pre-release must contain an asset matching `candidate-asset-pattern`. An emergency stable release can select `source-sha` only when `allow-source-sha` is `true`. The workflow rejects missing and conflicting source selections.

The workflow checks out the resolved source SHA before it builds. It publishes `prerelease` builds as GitHub pre-releases and `stable` builds as normal GitHub releases. Releases serialize per repository without cancelling an active release.

Appcast generation reads `CFBundleVersion` from the app inside the DMG. It does not parse a version from the DMG filename.
