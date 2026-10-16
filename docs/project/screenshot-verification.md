# Screenshot verification

The existing capture pipeline builds an optimized **Release** app and uses bundled synthetic photos. It never needs access to a personal Photos library or export destination. Run from an unlocked Mac; the terminal host needs Screen Recording permission in System Settings → Privacy & Security. Accessibility and Automation permissions are unnecessary.

```bash
scripts/screenshots/capture.sh --list
scripts/screenshots/capture.sh                         # original nine marketing surfaces, 2880x1800
scripts/screenshots/capture.sh 1440x900 timeline collections-favorites
scripts/screenshots/capture.sh 1440x900 dev-onboarding dev-empty dev-destination-unavailable dev-paused
```

The original keys and numbered filenames remain stable. The Paris album alias is also selectable. Development captures show the existing onboarding, empty month, unavailable destination, and paused progress UI. No fixture exports bytes. Each launch uses its own preferences suite and scratch records/destination/AutoSync directories; production observers are not attached. The runner terminates and waits for its own process before removing its scratch data and preferences. It does not quit a user's other app instances.

## Agent UI verification loop

1. Make a focused change and run the relevant behavioral tests.
2. List states and capture the affected state plus a representative normal state at the same size.
3. Open the resulting PNGs, inspect content, text, spacing, clipping, controls and placeholders, and fix visible regressions. A successful command proves the readiness protocol completed; it does not replace inspection or assert accessibility behavior.
4. Recapture after a fix. In the PR, state the command, macOS/Xcode versions, states inspected, and observations. Attach the synthetic PNGs by dragging them into the PR description/comment, or link an explicitly saved review artifact. The ignored `screenshots/` directory is a local output, not a pixel baseline to commit by default.

Subset runs replace only requested PNGs. A failed recapture removes that state's old PNG so it cannot look like fresh evidence; unrelated images survive. A build/argument failure leaves existing output untouched. Each requested state also gets a `.log` and a `.json` readiness report. Inspect these when a capture fails. Keep evidence from the same run together.

## Readiness and troubleshooting

The shared catalog is `photo-export/Resources/screenshot-states.json`. The runner validates keys before building. Each state starts a fresh executable PID with a UUID session. An atomic report under `/tmp/photo-export-capture-<UUID>/readiness.json` identifies the session, state, PID, window ID, work generation and pending view work. The app waits for the focused content load, visible image/count tasks, window sizing, and a layout pass with no intervening registered work. New work invalidates readiness. The runner accepts only the current launch's ready report; a global window-id file is no longer used.

The default readiness deadline is 30 seconds, configurable with `--timeout 60`. A timeout, child exit, invalid report, or `screencapture` error fails the command and prints diagnostic paths. It never captures on timeout. Check the last pending work list and launch log, verify the Mac is unlocked, and grant Screen Recording to the shell host if `screencapture` reports that it cannot create an image. Do not bypass the deadline or present an uninspected PNG as verified UI evidence.

```bash
python3 -B -m unittest discover -s scripts/ci/tests -p test_ci_screenshots.py
xcodebuild -project photo-export.xcodeproj -scheme photo-export -destination 'platform=macOS' \
  -only-testing:photo-exportTests/ScreenshotSessionTests CODE_SIGNING_ALLOWED=NO test
```

These tests validate readiness, isolation, catalog compatibility and runner failure behavior. They are not a screenshot assertion framework.
