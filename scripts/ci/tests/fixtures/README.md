# Recorded xccov fixture

`xccov-app-report.json` is reduced from a real local coverage report collected on
2026-10-16 using Xcode 27.0 (27A266a), macOS 26.6.2 (25G83). The full suite passed
1,271 tests across 122 suites. Application/test Swift sources match commit
`2811d542348fdc1c6a70023a04e7c059a123577a`:

- App source tree: `519311e95aff9db12b1208ca38eae94f8f920895`
- Test source tree: `3c7a0c3750aad20978f6e682ca15b1ed9b8f143d`

Capture commands (no personal Photos data is included):

```bash
xcodebuild -project photo-export.xcodeproj -scheme photo-export \
  -destination 'platform=macOS' -enableCodeCoverage YES \
  -resultBundlePath /private/tmp/photo-export-156-coverage.xcresult \
  CODE_SIGNING_ALLOWED=NO test
xcrun xccov view --report --json /private/tmp/photo-export-156-coverage.xcresult
```

Normalization removes function details, replaces the machine checkout prefix with
`/fixture/workspace/photo-export/` in source/build paths, retains all 111 app files and
the app target counters, and retains one test-file sample to exercise exclusion.
Report-wide/test-target aggregate counters are omitted because that sample is not
the complete test target. App counts remain 15,829 covered / 24,408 executable lines;
these are independent test expectations, not derived from the summary tool.

Normalized fixture SHA256: `f0646e9c3c056161fda5ab1d0401152b8630d63f4255ac3562ec334386d135b3`.
This is a recorded synthetic-test report, not an immutable historical persistence
fixture or a coverage baseline/threshold. Replace deliberately when its input format
needs to change; keep provenance and independent expectations accurate.
