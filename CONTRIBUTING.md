# Contributing to Photo Export

Photo Export is a small macOS project. Prefer focused pull requests, clear reasoning, and documentation that stays accurate after the change lands.

## Before You Start

- Search existing issues and pull requests before starting similar work.
- Open an issue or draft pull request before making a large feature or architecture change.
- Keep each pull request scoped to one concern when possible.

## Local Setup

Requirements:

- macOS 15.0+
- Xcode 16.2+

Open the project:

```bash
open photo-export.xcodeproj
```

Build from the command line:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run tests:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Optional tools:

- `brew install swiftlint`
- `brew install swift-format`

Docs website setup:

```bash
cd website
npm install
npm run dev
```

## Development Expectations

- Keep SwiftUI views thin. Move side effects and business logic into managers or view models.
- Avoid adding runtime dependencies unless there is a clear project-level reason.
- Add or update tests for bug fixes and behavior changes where practical.
- Use `os.Logger` for production logging.
- Preserve the no-overwrite export behavior and the `PHAsset.localIdentifier` tracking model.

## Developing new features

The app's export pipeline went through a multi-phase architecture refactor in May 2026 that established three cross-cutting contracts (cancellation, actor isolation, AutoSync seam) plus a Host-protocol pattern for `ExportManager`'s collaborators. Before adding a new export entry point, placement kind, variant, collaborator, or `@Published` property AutoSync should observe:

1. Read [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md) — the canonical home for the contracts, the canonical `start*` entry-point shape, and the "to add a new X, touch these files" recipes.
2. If your change touches the queue, AutoSync surface, record stores, or the screenshot photo library service, the following **regression-gate tests** must pass *without re-recording* unless you have explicitly audited the new behavior:
   - `AutoSyncSeamCharacterizationTests` — pins the AutoSync emission sequence.
   - `ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors` — pins synchronous coordinator→manager mirrors.
   - `ExportQueueStateSnapshotTests.pauseResumeCancelStateSnapshot_canonicalTransitions` — pins toolbar state transitions.
   - `ScreenshotPhotoLibraryServiceOverridesTests` — pins screenshot-mode override coverage.
   - `ImportIdempotencyTests` — pins import idempotency.
3. New collaborator extracted from `ExportManager`? Use the Host-protocol pattern documented in the conventions file (narrow protocol, IUO init, weak host, synchronous mirror sinks). Do not duplicate `@Published` state on the manager.

The deeper architecture map (what each type does) lives at [`website/src/content/docs/architecture.md`](website/src/content/docs/architecture.md). For agent-specific quick reference (build commands, design decisions, conventions), [`AGENTS.md`](AGENTS.md) is the richest single source — humans are welcome to read it too.

## Reference material

- **Architecture conventions** (cancellation, actor isolation, AutoSync seam, Host/forwarder patterns, regression gates, extension recipes): [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md)
- **Architecture map** (what each type does, friendly version): [`website/src/content/docs/architecture.md`](website/src/content/docs/architecture.md)
- **Style and Swift/SwiftUI patterns**: [`docs/reference/swift-swiftui-best-practices.md`](docs/reference/swift-swiftui-best-practices.md)
- **Persistence details**: [`docs/reference/persistence-store.md`](docs/reference/persistence-store.md)
- **Agent quick reference** (also useful for humans): [`AGENTS.md`](AGENTS.md)

## Documentation Ownership

Where each kind of doc lives, and which page to update for which kind of change, is documented in [`docs/README.md`](docs/README.md). Read that before opening a PR that changes user-visible behavior — there is a "what to update when behavior changes" table.

If a change affects setup, behavior, limitations, or project structure, update the relevant docs in the same pull request.

## Pull Requests

Include the following in your pull request description:

- what changed
- why it changed
- how you tested it
- whether documentation was updated

For UI changes, include a screenshot or short recording when practical.

## Release and Project Notes

Longer-lived project notes live under [`docs/`](docs/README.md). Keep the repo root reserved for the files people expect in an open source project.
