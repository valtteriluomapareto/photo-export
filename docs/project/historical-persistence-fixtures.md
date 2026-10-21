# Historical persistence fixtures

`test-fixtures/persistence/` contains synthetic bytes produced by released persistence
writers. These supplement handwritten legacy/recovery tests and the [real-Photos release
smoke](release-validation.md). No personal library or Application Support data is used.

## Provenance and immutability

| Fixture | Published source | Format |
| --- | --- | --- |
| `v1.0.3` | [Release](https://github.com/valtteriluomapareto/photo-export/releases/tag/v1.0.3), commit `a85100a7b0c734a0f492f5d76f5317c6c599d38f` | Flat timeline snapshot and JSONL mutations |
| `v1.6.5` | [Release](https://github.com/valtteriluomapareto/photo-export/releases/tag/v1.6.5), commit `0b0eb9b786311a961f9051d14e2e93cb0ecca135` | Per-variant timeline and placement-scoped collection snapshots/logs |
| `v1.3.0/auxiliary` | [Release](https://github.com/valtteriluomapareto/photo-export/releases/tag/v1.3.0), commit `63e3b0f7f934054781b96f68190900f00b316144` | First released dirty/retry/summary/per-destination token/safety/scope writers |
| `v1.6.1/auxiliary` | [Release](https://github.com/valtteriluomapareto/photo-export/releases/tag/v1.6.1), commit `93e0b8035f7b31c19ca89537be26ba77387068c0` | First released current-run journal writer |
| `v1.6.5/auxiliary` | Same v1.6.5 release above | All auxiliary writers above, shared-album fields, and first released stable destination id |

The [generator](../../scripts/fixtures/generate-persistence-fixtures.py) extracts an exact
allowlist from those Git objects, compiles unchanged models/stores/helpers with the
recorded current toolchain, and runs a small synthetic harness. There are no supporting
stubs, source patches, or threshold changes. Released mutation methods trigger the
1,000-mutation compaction threshold; later mutations remain in JSONL. IO is flushed
before capturing files. Both record harnesses use the injected base-directory initializer.

`manifest.json` records source commit/paths/SHA-256 hashes, harness hashes, toolchain,
target, host macOS version/build, release links, and every persistence file checksum. This establishes historical
source executed on the recorded runtime, not the original release binary or historical
macOS. PhotoKit is not queried by the harness.

The [auxiliary generator](../../scripts/fixtures/generate-auxiliary-persistence-fixtures.py)
uses a detached temporary worktree for each pinned release, compiles its unchanged
store/model/protocol dependency closure, and removes the checkout after execution.
Its two synthetic harnesses use injected directories and absolute-path UserDefaults
suites beneath scratch. The real historical destination manager creates a bookmark
for an empty scratch folder and seeds its stable id through the production selection
and validation path. No old app entry point, Photos observer, or default preferences
suite is run. Bookmark creation can require running outside a restricted shell sandbox.

The additional batches live in `manifest.json` under `auxiliaryGenerations`, with their
own source/harness/file hashes and toolchain/target/runtime. The original `releases`
entries, original harnesses and all original record fixture bytes are unchanged.
The additive field leaves manifest schema version 1 intact; each batch's `files` keys
are relative to its release directory. The full directory inventory is checked against
the union of original and additional files.

Timeline records first shipped in v1.0.0; that release's `Models/ExportRecord.swift` is
byte-identical to the existing v1.0.3 representative. Collections first shipped in
v1.2.0 with the same version-1 `version`/`placements`/`records` snapshot envelope,
`variants` record bodies and four log-operation discriminators used in v1.6.5.
Later shared-album/variant cases and the optional `subfolder` extend that shape;
the existing modern fixtures cover both present and absent optional values. These
record representatives remain in place while the auxiliary batches cover each
previously missing store's first release and v1.6.5.

Committed bytes are immutable: tests verify checksums, open temporary copies, and verify
originals afterward. Never regenerate fixtures to make a loader test pass. Historical
dictionaries do not sort JSON keys; equivalent regeneration need not be byte-identical.
Preserve original writer output without normalization. Normal CI never builds old releases.

## Independent expected state

Harness inputs, not today's decoder, define these observations. Explicit dates are
`2023-11-14T22:13:20Z`; A's timeline metadata is `2024/04/`, while B uses `2030/01/`.

| Timeline input | Expected after loading |
| --- | --- |
| A snapshot `shared`: failed `OLD.JPG`; later JSONL export | Original done at `REPLAY.JPG`, fixed export date |
| A snapshot `deleted`; later JSONL delete | Absent |
| A `snapshot-only` / log-only addition | Done at `SNAP.JPG` / `LOG.JPG` |
| A `interrupted` left in progress | Retryable original failure at `PARTIAL.JPG`, error `Interrupted before completion`, no export date |
| B `shared` | Failed at `OTHER.JPG`, error `Other destination`; A remains complete |
| Legacy A `raw-failure` | Failed at `FAIL.JPG`, error `Legacy disk error` |
| Modern A `fallback` | Original `F_orig.HEIC` done, edited failed with `Edited resource unavailable; original backed up as _orig`; covers edited-only selection, not Include originals |
| Modern A `live` | Still `LIVE.HEIC` done; motion carries `Photos has no exportable paired video resource for this Live Photo`, retaining accepted-unavailable completion |
| Modern A `video` | `VIDEO.MOV` persists `videos` subfolder; other still records have no subfolder |

Modern collections contain Favorites, `fixture-album` at
`Collections/Albums/Nested/Album/`, and `fixture-shared` at
`Collections/Shared Albums/Shared/`, all with fixed creation dates. The same `shared`
asset is done in Favorites (`REPLAY-FAV.JPG` after replay), failed in the album
(`Album disk error`), and done in the Shared Album (`SHARED.JPG`). Tests separately check
deletion, log-only addition, interruption, fallback, paired-unavailable, and video path.
Destination B has only its own failed Favorites `shared` record.

Fresh current stores open each temporary copy twice, flushing only pending production IO.
Tests never save or force compaction. Legacy decoding and interrupted recovery can be in
memory; reopening can reconstruct the same state from historical bytes. This does not
prove a canonical migration rewrite was durably persisted. Auxiliary tests likewise
open each copied file twice without saving through today's writer.

## Auxiliary expected state and preference transport

Auxiliary files use `AutoSync/destinations/A` and `B` beneath each release's `auxiliary`
directory. Fixed dates are seconds since Apple's reference date, starting at
`700000000`; identifiers, descriptions, UUIDs and token payloads are synthetic.

| Writer | Independent expected state after current loading |
| --- | --- |
| Dirty | A has timeline ids `asset-a`/`asset-b`, Favorites full reconciliation, album placement reconciliation and the fixed update date; B has only `asset-other`, updated 100 seconds later |
| Retry | A has a three-attempt transient original timeline failure, two-attempt hard edited Favorites failure, edited album failure, exact signatures/timestamps and both present/nil deadlines; modern A also has a shared-album paired-video failure; B has only its own hard original failure |
| Summary | A is background Auto Export for two timeline assets: 8 enqueued, 4 completed, 1 failed, 3 skipped, one structured failure; B is a user-cancelled manual Favorites run with a different UUID, dates and counts |
| Current run | A is processing Favorites after Timeline in a three-scope run; B has not started its sole album scope, so both current-scope fields are nil |
| Per-destination token | A is bytes `00 01 7f 80 fe ff`; B is UTF-8 `synthetic-token-B`, preserved exactly |
| Safety | A is confirmed, B has no marker; the real writer's wall-clock confirmation date is preserved without normalization. The reader's contract is file presence, not timestamp decoding |
| Scope preferences | Timeline and Albums on, Favorites off; modern Shared Albums on, while the absent early field defaults off |
| Stable destination id | The real v1.6.5 manager seeds `80762ef2ffdb41934b5c56ed352709048977a0ff129a3efaabc07b88d73f0234` from a fixed low-confidence fingerprint; current managers preserve it over two different remount fingerprints |

`preferences.plist` is a **transport envelope**, not an original CFPreferences file.
After the historical scope store and destination manager write an isolated suite, the
harness reads that suite's persistent domain and serializes only the unchanged
`AutoSync.scopeSelection` Data and, where available, `ExportDestinationStableId` String.
The machine-specific security-scoped bookmark and all scratch paths are excluded.
Tests copy the envelope under `TestScratch`, install its values into a fresh TestScratch
suite under the historical literal keys, and open the real current stores/managers
twice. This proves those writer payloads and keys remain readable; it does not claim
portable bookmark restoration or original preference-file byte compatibility.

### Global PhotoKit token limitation

`GlobalPhotoChangeTokenStore` first shipped in v1.3.0, but has no authentic valid-token
release fixture here. Its writer accepts `PHPersistentChangeToken`, whose public
initializer is unavailable; obtaining one requires a real Photos library's
`currentChangeToken`. No legitimate isolated synthetic library was available for this
bounded generation, and neither the user's library nor a forged archive is used.
Existing missing/corrupt-file tests remain. The per-destination token fixtures prove
only that store's opaque Data contract, **not** global secure-unarchive compatibility.
Valid global-token coverage needs a separately established isolated library and an
explicit runtime-compatibility scope; this fixture set does not cover every Apple-owned
token format.

## Running and extending

```bash
xcodebuild -project photo-export.xcodeproj -scheme photo-export \
  -destination 'platform=macOS' \
  -only-testing:photo-exportTests/HistoricalPersistenceFixtureTests \
  -only-testing:photo-exportTests/HistoricalAuxiliaryStoreFixtureTests \
  CODE_SIGNING_ALLOWED=NO test
```

Tests locate fixtures relative to `#filePath`; the source checkout must remain available.
A detached test bundle alone is insufficient; missing fixtures fail explicitly.

To inspect offline regeneration with the pinned Git objects available locally:

```bash
python3 scripts/fixtures/generate-persistence-fixtures.py \
  --output /private/tmp/photo-export-fixture-candidate
```

For the additional auxiliary batches:

```bash
python3 scripts/fixtures/generate-auxiliary-persistence-fixtures.py \
  --output /private/tmp/photo-export-auxiliary-candidate
```

Output must not exist. Both generators use scratch space and copy results only after all
writers succeed. The auxiliary generator emits an `auxiliary-generations.json` fragment;
add it under the manifest's `auxiliaryGenerations` without replacing earlier provenance.
Never use the committed fixture directory as output or regenerate an existing batch to
make a test pass. Old writers may emit nondeterministic dictionary order and wall-clock
safety timestamps; preserve the generated bytes rather than normalizing them.

For a distinct future format, verify its published release/commit, add a small source
allowlist and synthetic harness, and document independent expected state before
generating. Review new bytes/provenance as a new fixture set; existing sets stay unchanged.
Record any compiler compatibility adjustments precisely; persistence encoders/writers
must retain released behavior. Demonstrate that a representative deliberate decoder/replay
break causes semantic test failures, then restore exact production source and passing
results. A checksum failure alone is not that demonstration.
