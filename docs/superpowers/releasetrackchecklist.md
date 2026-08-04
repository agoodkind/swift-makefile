# Release Track Checklist

1. Choose `prerelease` or `stable` for `release-track`.
2. Confirm that the run number is a nonzero decimal value with at most six digits.
3. For a stable dispatch, use `candidate-tag`, `source-sha` with `allow-source-sha: true`, or no override to release the selected workflow ref.
4. When using `candidate-tag`, confirm that the candidate release is a published GitHub pre-release and contains an artifact matching `candidate-asset-pattern`.
5. Confirm that the workflow output source SHA matches the commit intended for the release.
6. Confirm that the published release type matches the selected track.
7. Confirm that the app inside the DMG has the fixed-width `CFBundleVersion` and the base calendar `CFBundleShortVersionString`.
8. Confirm that appcast generation reads the app metadata inside the DMG and keeps updates on the installed track.
