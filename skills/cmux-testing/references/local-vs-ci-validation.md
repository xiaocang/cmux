# Local vs CI Validation

Local tests are allowed in the local development environment when they are useful for validating a change. Prefer the narrowest relevant test target first, then broaden only when the change risk warrants it.

## `reload.sh`

`reload.sh` builds the Debug app for a tag. It does not compile the test target.

A successful reload proves the app target built. It does not prove:

- `cmuxTests` compile
- `cmuxUITests` compile
- package test targets compile
- test-only imports still resolve

For package/refactor work, treat reload as insufficient by itself.

## Unit test target

Local unit tests are allowed. `xcodebuild -scheme cmux-unit` is safe because it does not launch the app. Use the relevant scheme/package target, such as `cmux-unit` or SwiftPM package tests for touched packages — especially when package/refactor changes can break tests while the app target still builds.

Use a tagged derived data path:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build
```

For `cmuxApp` or `AppDelegate` churn, include the repo's known GlobalISel workaround flag if required by current project instructions.

## E2E and UI tests

Local E2E/UI runs are allowed when needed. Use a tagged Debug build and keep the run isolated from the user's main app. CI can still be triggered when remote proof is needed:

```bash
gh workflow run test-e2e.yml
```

Do not launch an untagged app locally to satisfy socket/UI tests.

## Python socket tests

Python socket tests under `tests_v2/` connect to a running cmux instance socket. If they must be run locally, use a tagged build socket:

```bash
CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock
```

Never launch or target an untagged `cmux DEV.app` for these tests. It can conflict with the user's running debug instance.
