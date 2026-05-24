# Agent Instructions

- Use `make help` as the public surface for this repository.
- Keep shared policy in `swift.mk`, shared helper logic in `scripts/`, and the custom analyzer in `swiftcheck/`.
- Check `SWIFT_MK_DEV_DIR` before claiming which source a consumer repo is using.
- Keep baseline mutation behind `BASELINE_CONFIRM` and `BASELINE_TOKEN`.
- Do not add project-local lint targets to consumer repos when the shared target already exists.
