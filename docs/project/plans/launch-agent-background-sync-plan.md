# LaunchAgent Background Sync Plan

Date: 2026-05-18
Status: Proposed (not started). Follow-up to the MVP shipped under
`docs/project/archive/auto-sync-background-sync-plan.md` — that plan's
"closed-app coverage" sub-goal is the entire scope of this one.

## Summary

Photo Export's Auto Export MVP runs while the main app is running, with
`SMAppService.mainApp` handling launch-at-login. This plan covers the
"true closed-app" follow-up: a bundled LaunchAgent that wakes on filesystem
mount or login, filters quickly for the configured destination, and launches
the main app to perform export — **agent-mediated, not headless**. Photos
authorization, security-scoped bookmark resolution, and the record store
stay in the main-app process; the agent is a tiny dispatcher.

Two load-bearing prerequisites: an App Group container that lets the agent
and main app share preferences/bookmarks/record-store state, and signed-build
verification that mount triggers reach the agent under both Developer ID and
App Store distribution.

This plan introduces one new user-visible setting (`Run Auto Export when
Photo Export is closed`) in the existing Settings → Auto Export tab. The
MVP-era safety invariants, single-active-run gate, destination lock, and
dirty-state machinery carry over unchanged.

## Implementation Status

| Sub-phase | Status | Notes |
|---|---|---|
| A. App Group migration | Not started | Prerequisite. Move `AutoSync.*` UserDefaults + `AutoSync/` and `ExportRecords/` App Support trees into an App Group container. |
| B. Helper agent bundle | Not started | Embedded launchd plist + small Swift binary that filters mount events. |
| C. Main-app integration | Not started | Handle `--auto-export-trigger=<reason>` launch arg; suppress main window when launched by agent. |
| D. Settings UI | Not started | New `Run Auto Export when Photo Export is closed` setting with status states. |
| E. Verification & docs | Not started | Manual-heavy QA across direct + App Store builds; update website + README. |

## Goals

- Maintain Auto Export when the user has explicitly quit Photo Export.
- Wake the main app on destination-drive connect (`StartOnMount`) and on
  login if the drive is already attached.
- Keep the agent process tiny, fast, and uninvolved in actual export work.
- Preserve every existing safety invariant (no destination-file deletion,
  no Photos library mutation, single-active-run, destination lock).

## Non-Goals

- Headless Photos export from the agent process. Photos auth + bookmark +
  record-store work stay in the main app.
- LaunchDaemon (root-level). Photos access and user-selected destinations
  are per-user; root scope is the wrong fit.
- Login-item helper app. Excluded for the same reason as in the MVP plan:
  same IPC + App Group cost as the LaunchAgent with no closed-app coverage
  benefit.
- Network-share or cloud destinations as agent triggers. `StartOnMount`
  is local-filesystem; if a future destination type doesn't generate mount
  events, that's a separate plan.

## Architectural Decisions

### Agent wakes main app (not headless export)

The agent is a small Swift binary that:

1. Reads the configured destination from the App Group container.
2. Compares the just-mounted volume against the persisted `DestinationFingerprint`.
3. If it matches, spawns the main app with `--auto-export-trigger=mount`,
   then exits.
4. If it doesn't match, exits immediately. No PhotoKit calls, no record-store
   touches, no destination-lock acquisition.

Why agent-mediated: Photos authorization under signed sandboxed agent
processes is unverified territory, and the main-app export path already has
~3,471 lines of tests pinning its behavior. Reproducing that path inside a
second process is gratuitous risk for no observable user benefit.

### App Group as load-bearing prerequisite

The agent needs to know what destination the user configured *before* it
decides whether to wake the main app. That state currently lives in main-app
`UserDefaults` and the per-bundle App Support container — both invisible to
the agent.

The App Group migration is therefore prerequisite, not optional. Sub-phase A
is a gated step: if signed-build verification surfaces a blocker (App Store
entitlement rejection, sandbox permission denial), stop and redesign before
starting B.

### Quit behavior after agent-triggered run

When the agent launches the main app to handle a mount-triggered export,
the main app:

- Does not show its main window. The status bar item (already shipped in
  MVP) is the only visible surface.
- Runs the auto-export normally (dirty-state evaluation, single-active-run,
  destination lock).
- **Stays running** after the run completes. Quitting requires an explicit
  user action (status item → Quit, or Cmd-Q after opening the main window).

Rationale: a silently-quitting main app would surprise the user the next
time they try to interact with status. Staying alive matches how Time
Machine's `backupd` behaves — present, but invisible until the user opens
the system UI.

### IPC: launch argument, not XPC

The agent signals the main app by spawning it with a launch argument
(`--auto-export-trigger=<reason>`). No XPC, no Mach ports, no Distributed
Notifications. The argument is parsed during `applicationDidFinishLaunching`
and dispatched into `AutoSyncManager` as a synthetic event.

Why: the agent and main app are not running concurrently in the typical
case (agent fires, exits, main launches). XPC would impose lifetime
coupling for no benefit. If main app is already running, `NSWorkspace
.openApplication` activates the existing instance and the launch arg is
delivered via `application(_:open:)` — the dispatch path is identical.

### Detection: how the agent decides "this mount is ours"

`launchd`'s `StartOnMount` does NOT pass the mounted volume path to the
agent process. The agent enumerates currently-mounted volumes itself and
compares against the persisted `DestinationFingerprint`:

1. Read the configured `DestinationFingerprint` from the App Group container.
2. Enumerate volumes via `FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:options:)`.
3. For each volume, read `volumeUUIDStringKey`; match against the
   fingerprint's `volumeUUIDString`.
4. If a match exists *and* it wasn't already present at the agent's previous
   run, fire the trigger.

The "previous run" check is needed because the agent itself may be invoked
multiple times rapidly during boot when the system mounts everything in
parallel. The agent keeps a small `last-known-volume-uuids.json` file in the
App Group's caches directory.

## Sub-Phase A — App Group Migration

Goal: every state the agent needs to read must live in an App Group container
shared with the main app.

State moves:

- **UserDefaults**: `AutoSync.enabled`, `AutoSync.scopeSelection`, and the
  destination bookmark. Move to a `UserDefaults(suiteName: <appGroupID>)`
  instance.
- **App Support files**:
  - `AutoSync/photo-library-change-token.data`
  - `AutoSync/destinations/<destinationId>/*.json`
  - `ExportRecords/<destinationId>/{export-records,collection-records}.{snapshot.json,jsonl}`

  All move from `~/Library/Containers/<bundleID>/Data/Library/Application Support/`
  to `~/Library/Group Containers/<groupID>/Library/Application Support/`.

Migration trigger: first launch of the new app version. Steps:

1. Detect presence of legacy state in the per-bundle container.
2. If App Group container is empty, copy legacy state across.
3. Verify checksums of copied JSON files match originals.
4. Mark migration complete with a `migration-complete.marker` file in the
   App Group's caches directory so subsequent launches skip the check.
5. **Do not delete the legacy state** in this version. If the user reverts
   to an earlier version, their backup state is intact. Add a separate
   "post-rollback-window" cleanup in a later version.

Failure modes:

- **Permission denied creating App Group container** → fall back to legacy
  state, log diagnostic, surface an Auto Export blocked state with "App
  Group setup incomplete" error.
- **Disk full during copy** → abort migration, leave legacy state, retry on
  next launch.
- **Partial migration** (some files copied, some not) → detected via per-file
  `.complete` markers; resume on next launch.

App Group identifier: `group.com.valtteriluoma.photo-export.shared`. Bind
to both targets (main app + agent helper).

App Store: App Group entitlements require the group to be registered in App
Store Connect. Add this step to the existing App Store CI workflow.

## Sub-Phase B — Helper Agent Bundle

Bundle layout:

```
Photo Export.app/Contents/
  Library/
    LaunchAgents/
      com.valtteriluoma.photo-export.helper.plist
  Helpers/
    photo-export-helper          (signed Swift binary)
```

launchd plist contents:

```xml
<plist version="1.0">
<dict>
  <key>Label</key><string>com.valtteriluoma.photo-export.helper</string>
  <key>BundleProgram</key><string>Contents/Helpers/photo-export-helper</string>
  <key>StartOnMount</key><true/>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
  <key>StandardOutPath</key><string>/dev/null</string>
</dict>
</plist>
```

Notes:

- `StartOnMount=true` fires on every filesystem mount. The agent must exit
  quickly (<100 ms) for non-matching mounts.
- `RunAtLoad=true` fires when the LaunchAgent itself is loaded (login, or
  registration). The agent runs the same matching logic; it doesn't blindly
  trigger main.
- `KeepAlive=false` — agent exits after each invocation.
- `BundleProgram` is relative to the app bundle, so `SMAppService.agent(plistName:)`
  resolves it correctly across updates.

Agent binary design (~150 LOC ceiling):

```
1. Parse args (`--trigger-by=mount|load`, diagnostics only).
2. Open App Group container; read configured DestinationFingerprint.
   - If no destination configured: exit 0.
   - If Auto Export is disabled in UserDefaults: exit 0.
   - If "Run Auto Export when Photo Export is closed" is disabled: exit 0.
3. Enumerate mounted volumes; find matching volume by UUID.
   - If no match: exit 0.
4. Read `last-known-volume-uuids.json` from App Group caches.
   - If the matched UUID was already in the previous list: exit 0
     (no new connect event).
5. Spawn main app with NSWorkspace.openApplication, passing
   `arguments: ["--auto-export-trigger=mount"]`.
6. Update `last-known-volume-uuids.json` with the current set.
7. Write a `last-wake.json` diagnostic entry (timestamp, trigger reason,
   outcome) for the Settings tab to surface.
8. Exit 0.
```

The agent must NOT:

- Open the destination bookmark (security-scoped — likely won't resolve in
  agent's sandbox anyway).
- Acquire the destination lock.
- Touch the record store.
- Make any PhotoKit calls.

Signing & entitlements (agent target):

- Sandbox: enabled.
- Hardened runtime: enabled.
- App Group: same identifier as main.
- No additional entitlements (no Photos, no Files & Folders — agent never
  reads them).

## Sub-Phase C — Main-App Integration

Launch-argument handling (add to `photo_exportApp.swift`'s app-init path):

```swift
let triggerReason = ProcessInfo.processInfo.arguments
  .first(where: { $0.hasPrefix("--auto-export-trigger=") })
  .map { String($0.dropFirst("--auto-export-trigger=".count)) }
```

Behavior when launched with the trigger:

- Skip main-window presentation.
- Status bar item (already in MVP) is visible immediately.
- After `AppLifecycleCoordinator` finishes bootstrap, dispatch a new
  `AutoSyncEvent.agentTriggered(reason: ...)` into the manager.
- The reducer treats `agentTriggered` similarly to `runNow`: bypasses
  debounce and the enabled flag (the agent already gated on those), but
  still honors safety, hard blockers, and the destination lock.

`applicationShouldTerminateAfterLastWindowClosed` is already `false` when
Auto Export is enabled (MVP behavior). This plan does not change that. The
main app stays alive until the user explicitly quits, regardless of whether
the user opened or closed the main window.

Avoiding duplicate runs when both main app and agent fire:

- Main app already enforces single-active-run via `runExport`. If main is
  running when the agent tries to spawn it, `NSWorkspace.openApplication`
  activates the existing instance and the launch arg is delivered via
  `application(_:open:)`. The dispatch path is the same.
- The destination lock (from MVP Phase 0b) makes this safe even across
  the two-build (Developer ID + App Store) corner case.

## Sub-Phase D — Settings UI

Add to the existing Auto Export Settings tab:

```
Run Auto Export when Photo Export is closed         [⚪︎]

Status: Registered, enabled
Last wake attempt: Today 14:32 (drive connected, exported 12 photos)

ⓘ When the destination drive connects or you log in with the drive
  already attached, Photo Export wakes briefly to back up new
  photos. The app stays running in the menu bar after the run
  completes; quit it from the menu bar to stop background activity
  entirely.

  [Open Login Items in System Settings]
```

Status states (rendered as a single status line + optional helper button):

- `notInstalled` — the agent plist isn't registered yet. Toggling the setting
  triggers `SMAppService.agent(plistName:).register()`.
- `registered, enabled` — green checkmark.
- `requiresApproval` — surface deep link to System Settings → Login Items.
- `denied` / `disabledByUser` — explain how to re-enable via Login Items.
- `lastWakeAttempt(date, outcome)` — small footnote line.

Last-wake-attempt persistence: the agent writes `last-wake.json` to the App
Group caches on every invocation (success or no-op), and the Settings view
reads it.

Toggle behavior:

- Default **off**.
- Turning on while the App Group migration hasn't completed yet: disable the
  toggle, show "Setting up shared storage…" hint, re-enable when migration
  completes.
- Turning off: `SMAppService.agent(plistName:).unregister()`; clear
  `last-wake.json`.

## Signing & Distribution

Direct (Developer ID):

- The agent helper is signed with the same Developer ID as the main app.
- Embedded launch agent plist is bundled automatically by Xcode when the
  agent target is added as a Copy Files build phase.
- `SMAppService.agent(plistName:).register()` requires the plist to live at
  `Contents/Library/LaunchAgents/<name>.plist` inside the main app bundle.

App Store:

- Same `SMAppService` API path.
- App Group must be registered in App Store Connect.
- App Review may flag the LaunchAgent for human review. Surface clear copy
  in the App Store description ("Optional setting to back up automatically
  when you connect your backup drive — off by default") to pre-empt
  rejections.

Re-registration on app update:

- The plist's `BundleProgram` path is relative, so update-in-place generally
  works.
- BUT: on first launch after an update, call `SMAppService.agent(plistName:)
  .status` and re-register if state went stale. The existing
  `LoginItemController` (MVP) already has this pattern for
  `SMAppService.mainApp`; add a parallel `BackgroundAgentController`.

CI changes:

- `release-direct.yml` and `release-app-store.yml`: add the new agent target
  to the build, codesign-verify both binaries, notarize (direct only).
- Add a smoke test that confirms the embedded plist exists and is readable
  after build.

## Test Plan

This phase is manual-heavy because the failure modes are OS-level.

Unit tests (where possible):

- Agent volume-matching logic (run against fake `mountedVolumeURLs` + a fake
  `DestinationFingerprint`).
- App Group migration: legacy → group container copy, checksum verification,
  idempotent re-runs, partial-migration resume.
- Main-app launch-arg parsing: `--auto-export-trigger=mount` dispatches the
  right `AutoSyncEvent`.

Integration tests (in CI):

- Two builds (direct + App Store) of the agent + main: destination lock
  prevents concurrent writes when both are spawned. (Already an MVP AC;
  verify it still holds with agent triggers.)

Manual QA (must run on a clean macOS user account before release):

- Quit app, connect drive: main app launches in background, status item
  visible, run completes.
- Quit app, log out, log back in with drive attached: main app launches.
- Connect a DMG (not the destination): agent exits quickly, no main launch.
  Verify via Console log timestamps.
- Connect a USB stick that isn't the destination: same as the DMG case.
- Reject Login Items approval: setting status shows `requiresApproval`,
  deep link works.
- Revoke approval in System Settings while app is running: status updates
  next time Settings window becomes key.
- Toggle setting off: confirm `SMAppService.agent` is unregistered;
  subsequent mounts do nothing.
- Force-kill main app mid-run: next mount triggers agent → main launches →
  resumes from dirty state.
- Connect drive while main app is already running with a window open:
  agent's `NSWorkspace.openApplication` should activate the existing
  instance and re-dispatch the trigger; the open window stays open.
- App update from a version without the agent to the version with the
  agent: re-registration on first launch works.
- App update while the agent is active: the existing agent process
  completes its current invocation; the next invocation uses the new binary.
- Two builds installed (Developer ID + App Store): only one's agent fires
  per mount, or both fire and the destination lock arbitrates without
  duplicate writes.

## MVP Acceptance Criteria

- Closed-app drive-connect triggers a successful export run within 60
  seconds of mount.
- Toggling the setting off unregisters the agent; subsequent mounts do
  nothing.
- System Settings revocation is reflected in the Settings tab next time
  the window becomes key.
- A non-destination mount (DMG, USB stick, network share) causes the agent
  to exit in <100 ms with no main-app launch.
- Main app launched by the agent never shows a window unless the user
  clicks Dock icon or status item.
- No duplicate writes when the main app is already running (covered by
  the existing destination lock).
- Direct (Developer ID) and App Store builds both successfully register
  their agent via `SMAppService.agent(plistName:)`.
- App Group migration completes on first launch of the new version;
  legacy state is preserved (not deleted) so rollback is possible.

## Risks

- **App Store review.** Persistent background behavior is sensitive.
  Mitigations: setting is off by default, copy is explicit about what
  wakes the app, app exits when the user explicitly quits.
- **Photos auth under sandboxed agent.** Should be moot (agent doesn't
  call PhotoKit), but verify with a logged trace that the agent's process
  state shows no PhotoKit linkage.
- **StartOnMount load on the system.** Agent must exit fast for
  non-matching mounts. Add a Console-based timing check: <100 ms for
  non-match, <500 ms for match (excluding main-app launch time).
- **App Group migration corner cases.** Interrupted migration mid-write
  must resume cleanly on next launch. The per-file `.complete` marker is
  the load-bearing test case.
- **Re-registration on update.** If `BundleProgram` resolution breaks
  between updates, the agent silently stops firing. A self-test on first
  post-update launch is important.
- **Volume UUID identity drift.** If the user reformats their backup
  drive, the volume UUID changes; the agent will stop matching. Surface a
  hint in Settings when the persisted `DestinationFingerprint` matches no
  currently-mounted volume despite having matched within the last 7 days.
- **Two-instance corner case.** If both Developer ID and App Store builds
  have the setting enabled, both agents fire on every mount. Destination
  lock prevents concurrent writes, but the user sees two main apps
  launch. Document, do not engineer around.

## Open Risks To Resolve Before Implementation

- **Agent's ability to read its App Group container under both Developer
  ID and App Store sandbox.** Treat as a 1-day spike at the start of
  Sub-phase A.
- **`StartOnMount` firing behavior at login when the volume is already
  attached.** Verify whether the agent gets a `mount` event for
  already-mounted volumes when launchd loads it at login, or only a
  `RunAtLoad` event. Adjust the agent's matching logic accordingly (the
  `last-known-volume-uuids.json` design assumes both paths fall through
  the same code).

## Complexity Estimate

| Sub-phase | Size | Time |
|---|---|---|
| A. App Group migration | M | ~1 week |
| B. Helper agent bundle | M | ~1 week |
| C. Main-app integration | S | ~3 days |
| D. Settings UI | S | ~2 days |
| E. Verification & docs | M | ~4 days |
| **Total** | **L** | **~3 weeks** |

App Group migration is the load-bearing prerequisite. Treat A as a gated
step: if signed-build verification surfaces a blocker (App Store
entitlement rejection, sandbox permission denial), stop and redesign
before starting B.

## References

- Apple Developer: `SMAppService.agent(plistName:)`.
- `man launchd.plist`: `StartOnMount`, `RunAtLoad`, `BundleProgram`,
  `ProcessType`.
- Apple Developer: App Groups for macOS sandboxed apps.
- [`docs/project/archive/auto-sync-background-sync-plan.md`](../archive/auto-sync-background-sync-plan.md)
  — the MVP that this plan extends. The destination lock, safety
  invariants, single-active-run gate, and dirty-state machinery from that
  plan are prerequisites here.
