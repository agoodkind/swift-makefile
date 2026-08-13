# Release Track Contract

The shared release workflow keeps pre-release and stable artifacts separate so automatic updates stay on the installed track.

Pre-release is the human-facing term. Workflow inputs, variables, and paths use `prerelease`, while tags and artifact names use `pre`.

Pre-release tags use `26.7.26-pre.202607261030+abc1234`. Their artifact versions replace `+` with `-`, so a DMG can use `FanCurve-26.7.26-pre.202607261030-abc1234.dmg`.

Stable tags use `26.7.26`, `26.7.26-r1`, and later same-day revisions. Stable DMGs use the matching tag, such as `FanCurve-26.7.26-r1.dmg`.

Every distributable build keeps `CFBundleShortVersionString` at the base calendar version. `CFBundleVersion` combines `yyyyMMddHHmm` with the six-digit `GITHUB_RUN_NUMBER`, such as `202607261030000087`. The workflow rejects missing, nonnumeric, zero, and more-than-six-digit run numbers.

`release-on-merge` defaults to `manual`, so a main-branch push does not publish a release. Set it to `prerelease` or `stable` to opt into publishing after a merge. A repository that runs its dry run inside CI drops the pull-request trigger here, so this workflow runs only on a merge or a manual dispatch.

A manual stable dispatch with no source override releases the selected workflow ref. `candidate-tag` selects a published pre-release containing an asset matching `candidate-asset-pattern`. `source-sha` selects a commit only when `allow-source-sha` is `true`. The workflow rejects conflicting source overrides.

The workflow checks out the resolved source SHA before it builds. It publishes `prerelease` builds as GitHub pre-releases and `stable` builds as normal GitHub releases. Releases serialize per repository without cancelling an active release.

Appcast generation reads `CFBundleVersion` from the app inside the DMG. It does not parse a version from the DMG filename.
