# Pilot Results

Indexing benchmarks against well-known Rails apps.

## Setup

- Hardware: 8-core x86_64 Linux (Fedora 43)
- Build: Debug (Fedora glibc `_FORTIFY_SOURCE` blocks `--release=safe` locally; CI uses musl release builds which are faster)
- Workers: `--max-workers 8`
- Mode: `refract --index-only --disable-rubocop`
- Date: 2026-04-27

## Results

| Corpus            | Files indexed | Symbols | Wall time | Peak RSS | Notes |
|-------------------|--------------:|--------:|----------:|---------:|-------|
| mastodon          |         4,063 |  36,052 |   1:46    |    91 MB | clean run, chunked commits |
| discourse/app     |         1,232 |  12,555 |   0:15    |    48 MB | |
| discourse/lib     |           723 |   8,375 |   0:12    |    41 MB | |
| discourse/spec    |         1,880 |  47,699 |   0:47    |    66 MB | |
| discourse/plugins |         7,765 |  38,885 |   4:37    |    67 MB | |
| discourse (full)  |       ~13,000 |       — | ~30-45m   |   ~310 MB | completes; slow; see below |

## Findings

**Mastodon-scale repos (≤5k files) index in ~2 minutes** with peak RSS under ~100 MB.

**Per-subdirectory indexing scales linearly** on Discourse — sum of subdirs is ~6 minutes for the same files.

**Full-repo Discourse-scale (10k+ files) initially hung indefinitely** because the entire reindex was wrapped in a single SQL transaction. WAL grew to hundreds of MB and the final COMMIT became pathological. **Fixed in `a5035e5` (`perf(indexer): chunk reindex into 500-file transactions`)** — runs now complete, WAL stays bounded around 67 MB.

**Residual slowness on huge repos**: even with chunked commits, full-Discourse cold-bootstrap takes ~30-45 minutes on debug builds (release builds should be 2-4× faster). Per-subdir runs are 5-6× faster than the full-repo run, suggesting super-linear cost in cross-file resolution as the symbols table grows. This is a separate optimization opportunity for v0.2 — likely requires deferring speculative method-chain inference (the `SELECT return_type FROM symbols WHERE name=? AND kind='def' AND file_id IN (subquery)` pattern) to query time on large workspaces.

## Implications for v0.1.0

| Audience                              | Status                |
|---------------------------------------|-----------------------|
| Solo dev / small team Rails apps      | Works well            |
| Mid-size apps (~5k Ruby files)        | Works (≤2 min cold)   |
| Large monorepos (10k+ files)          | Cold-bootstrap is slow (~30-45 min debug, ~10-15 min release); incremental edits afterward are fast |

For v0.1.0, the recommendation is:
- Document mastodon timings as the headline number
- Note that initial indexing of very large repos is a known limitation
- Subsequent file edits (incremental reindex) are unaffected — only the cold-bootstrap is slow

## Next-step ideas (v0.2)

- ✅ **Chunk the initial reindex** into transactions of N=500 files — done in `a5035e5`. Reduces WAL pressure; turns "hangs" into "completes".
- **Defer speculative cross-file resolution** during cold-bootstrap. The `SELECT return_type FROM symbols WHERE name=? AND kind='def' AND file_id IN (...)` pattern fires per-method-call and gets slower as the symbols table grows. On large workspaces, defer to query time (hover/completion) instead of indexing time.
- **Profile a single problematic subdir** (e.g., `discourse/plugins/discourse-narrative-bot`) to identify per-file slowness if any pathological files exist.
- **Two-pass indexing**: pass 1 inserts symbols only (fast); pass 2 resolves cross-file refs (slow but optional).

## How to reproduce

```sh
zig build "-Dgit_sha=$(git rev-parse --short HEAD)"
REFRACT_PILOT_DIR=/tmp/refract-pilot ./scripts/pilot.sh mastodon
```

Pass any of `discourse`, `mastodon`, `gitlabhq` as args. Without args, runs all three.
