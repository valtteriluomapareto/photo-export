# Historical persistence fixtures

`test-fixtures/persistence/` contains synthetic bytes produced by released persistence
writers. These supplement handwritten legacy/recovery tests and the [real-Photos release
smoke](release-validation.md). No personal library or Application Support data is used.

## Provenance and immutability

| Fixture | Published source | Format |
| --- | --- | --- |
| `v1.0.3` | [Release](https://github.com/valtteriluomapareto/photo-export/releases/tag/v1.0.3), commit `a85100a7b0c734a0f492f5d76f5317c6c599d38f` | Flat timeline snapshot and JSONL mutations |
| `v1.6.5` | [Release](https://github.com/valtteriluomapareto/photo-export/releases/tag/v1.6.5), commit `0b0eb9b786311a961f9051d14e2e93cb0ecca135` | Per-variant timeline and placement-scoped collection snapshots/logs |

The [generator](../../scripts/fixtures/generate-persistence-fixtures.py) extracts an exact
allowlist from those Git objects, compiles unchanged models/stores/helpers with the
recorded current toolchain, and runs a small synthetic harness. There are no supporting
stubs, source patches, or threshold changes. Released mutation methods trigger the
1,000-mutation compaction threshold; later mutations remain in JSONL. IO is flushed
before capturing files. Both harnesses use the injected base-directory initializer.

`manifest.json` records source commit/paths/SHA-256 hashes, harness hashes, toolchain,
target, host macOS version/build, release links, and every persistence file checksum. This establishes historical
source executed on the recorded runtime, not the original release binary or historical
macOS. PhotoKit is not queried by the harness.

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
prove a canonical migration rewrite was durably persisted. Bookmark identity migration
and AutoSync metadata remain covered by existing suites, outside this initial fixture set.

## Running and extending

```bash
xcodebuild -project photo-export.xcodeproj -scheme photo-export \
  -destination 'platform=macOS' \
  -only-testing:photo-exportTests/HistoricalPersistenceFixtureTests \
  CODE_SIGNING_ALLOWED=NO test
```

Tests locate fixtures relative to `#filePath`; the source checkout must remain available.
A detached test bundle alone is insufficient; missing fixtures fail explicitly.

To inspect offline regeneration with the pinned Git objects available locally:

```bash
python3 scripts/fixtures/generate-persistence-fixtures.py \
  --output /private/tmp/photo-export-fixture-candidate
```

Output must not exist. Generation uses scratch space and copies results only after both
writers succeed. Never use the committed fixture directory as output.

For a distinct future format, verify its published release/commit, add a small source
allowlist and synthetic harness, and document independent expected state before
generating. Review new bytes/provenance as a new fixture set; existing sets stay unchanged.
Record any compiler compatibility adjustments precisely; persistence encoders/writers
must retain released behavior. Demonstrate that a representative deliberate decoder/replay
break causes semantic test failures, then restore exact production source and passing
results. A checksum failure alone is not that demonstration.
