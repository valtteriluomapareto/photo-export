# Development control plane

A Debug Photo Export build can open a window backed by a deterministic Photos fixture. The
app uses its normal destination validation, export queue and record stores. Each run has
a private temporary root with its own `Destination`, `AppState` and preferences plist.
The fixture supplies the library, thumbnail reader, resource bytes, video renderer, Photos
change source, Auto Export clock and login-item service. Signed builds use the app
container's temporary directory. Unsigned builds use the process temporary directory.

The file mailbox and offscreen capture follow Silta's Mac control plane at
[`446bc7bb`](https://github.com/valtteriluomapareto/silta/blob/446bc7bb/docs/mac-app-control.md).
Photo Export's issue [#340](https://github.com/valtteriluomapareto/photo-export/issues/340)
tracks the development workflow.

## Export and repeat a month

Build the Debug app using the [local build command](../../CONTRIBUTING.md#local-setup),
then pass its bundle path to the driver.

```sh
app="/path/to/Build/Products/Debug/Photo Export.app"
driver=scripts/dev/pe_control.py
run=$("$driver" launch --app "$app")
action='{"action":"export.month","year":2025,"month":6}'
"$driver" action "$run" "$action"
"$driver" wait "$run" 'idle=true' 'records.exportedByMonth.2025-06=2'
ls "$run/Destination/2025/06"
"$driver" action "$run" "$action"
"$driver" wait "$run" 'idle=true' 'export.enqueued=0'
"$driver" stop "$run"
```

The first export writes `Harbor.png` and `Pines.png`. The second reads the same history
and queues zero jobs. Stop terminates the matching fixture process and leaves its run
directory available for inspection. `state RUN [PATH]` also reads a stopped run or
offscreen snapshot. `wait RUN PATH=JSON ...` watches the directory and process until all
predicates match. Quote strings as JSON, for example `'destination.status="ready"'`.
Timeouts report the observed values of unmet predicates.

CI runs the same journey as an advisory smoke test. To reproduce it locally, use
a fresh directory for the transcript and capture files.

```sh
python3 -B scripts/dev/control_smoke.py --app "$app" --evidence "$(mktemp -d)"
```

The smoke verifies the two PNGs and compares their contents and file metadata across
the repeat. A failed CI run retains the driver transcript, app stderr and any
published state and responses.

## Mailbox version 1

The driver publishes an atomic `req-N.json`. Requests carry `version: 1`, `run`, `seq`,
an `action` and that action's typed fields. The app validates the run ID, exact fields,
unique decoded keys and a 16 KiB request limit. It responds in sequence through an
exclusive `res-N.json` file, including when a request is refused.

| Action | Extra fields |
| --- | --- |
| `export.month` | Integer `year`, integer `month`, optional boolean `confirm` |
| `export.year` | Integer `year`, optional boolean `confirm` |
| `export.album` | String `id` (`summer` in v1), optional boolean `confirm` |
| `export.favorites` | Optional boolean `confirm` |
| `export.pause`, `export.resume`, `export.cancel` | |
| `import.start`, `import.cancel` | |
| `autoSync.setEnabled` | Boolean `enabled` |
| `clock.advance` | Integer `seconds` from 0 to 86,400 |

Responses report `accepted`, `noop` or `refused` with a stable reason. For an active
Auto Export run, a manual export can return `needsConfirmation`. Submit a new action with
`"confirm":true` after deciding to supersede it. For an interrupted action, reuse its
original JSON with `--seq N` to recover its response without replaying it.

The atomically replaced `state.json` carries the run ID, revision, process/window ID,
issued and settled sequence, and redacted destination, export, import, Auto Export,
record and prompt state. `settledSeq` means the action has returned. Wait on `idle` and
the operation's result fields for asynchronous completion. A scheduled Auto Export can
remain idle until `clock.advance` runs the due timer.

## Offscreen captures

```sh
shot=$(scripts/dev/pe_control.py snapshot --app "$app" --surface advanced --dark)
open "$shot/snapshot.png"
scripts/dev/pe_control.py state "$shot" surface
```

The available surfaces are `library`, `favorites`, `autoExport`, `exportIssues` and
`advanced`. Offscreen capture uses the real views and stores the matching `state.json`.
It works without Screen Recording. Native list selections and tab labels can lose
contrast in the offscreen bitmap. For window chrome and material effects, use
`shot RUN OUTPUT.png` from a terminal with Screen Recording permission. The driver
checks the window owner and writes an accompanying `OUTPUT.png.json` when the state
before and after capture agrees.

Direct Debug launch supports `-PEFixture v1`, `-PESnapshot <filename.png>`, `-PESurface`,
`-PEDark`, and `-PESize WxH` from 1000×700 to 4096×4096 logical points. Snapshot
output is inside the run directory. `-PERunDirectory` accepts an absolute path to a
fresh, user-owned `photo-export-control-*` directory with mode 0700 directly inside
the app's temporary directory. Release builds refuse `-PE*` flags at entry. CI checks
the control markers against Debug and checks their exclusion from both distribution
builds.
