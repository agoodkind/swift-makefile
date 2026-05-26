# Agent Instructions

- Use `make help` as the public surface for this repository.
- Keep shared policy in `swift.mk`, the lint, baseline, gate, and notice logic in the `Sources/` Swift package (`SwiftMkCore` library, `SwiftMkCLI` executable, `swift-mk` product), and the custom analyzer in `swiftcheck/`. `scripts/` holds only the bootstrap, fetch, build, and sync bash that must run before the binary exists.
- Check `SWIFT_MK_DEV_DIR` before claiming which source a consumer repo is using.
- Keep baseline mutation behind `BASELINE_CONFIRM` and `BASELINE_TOKEN`.
- Do not add project-local lint targets to consumer repos when the shared target already exists.
