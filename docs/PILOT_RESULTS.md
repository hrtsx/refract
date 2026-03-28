# Pilot Results

Indexing benchmarks against well-known Rails apps.

## Setup

- Hardware: 8-core x86_64 Linux (Fedora 43)
- Build: Debug (Fedora glibc `_FORTIFY_SOURCE` blocks `--release=safe` locally; CI uses musl release builds which are faster)
- Workers: `--max-workers 8`
- Mode: `refract --index-only --disable-rubocop`
- Date: 2026-04-27

## Results

| Corpus            | Files indexed | Symbols | Wall time | Peak RSS |
|-------------------|--------------:|--------:|----------:|---------:|
| mastodon          |         4,063 |  36,052 |   1:52    |    63 MB |
| discourse/app     |         1,232 |  12,555 |   0:15    |    48 MB |
| discourse/lib     |           723 |   8,375 |   0:12    |    41 MB |
| discourse/spec    |         1,880 |  47,699 |   0:47    |    66 MB |
| discourse/plugins |         7,765 |  38,885 |   4:37    |    67 MB |
| discourse (full)  |             — |       — |  >20:00   |     —    |

## Findings

**Mastodon-scale repos (≤5k files) index in ~2 minutes** with peak RSS under 70 MB.
The pilot validates the harness end-to-end: `pilot.sh mastodon` produces a clean Markdown row.

**Per-subdirectory indexing scales linearly** on Discourse — sum of subdirs is ~6 minutes for the same files.

**Full-repo single-transaction indexing on Discourse-scale (10k+ files) is pathologically slow.**
The `discourse` root run hung at 20+ minutes across two attempts and was killed; subdirs of the same files sum to ~6 minutes when run separately. Likely root cause is SQLite WAL growth under one giant transaction holding all writes until a final commit. Memory stays modest (~70 MB), so it's not OOM — it's transaction throughput.

## Implications for v0.1.0

| Audience                              | Status                |
|---------------------------------------|-----------------------|
| Solo dev / small team Rails apps      | Works well            |
| Mid-size apps (~5k Ruby files)        | Works (≤2 min cold)   |
| Large monorepos (10k+ files)          | First-index is slow; warm queries are fast once indexed |

For v0.1.0, the recommendation is:
- Document mastodon timings as the headline number
- Note that initial indexing of very large repos is a known limitation
- Subsequent file edits (incremental reindex) are unaffected — only the cold-bootstrap is slow

## Next-step ideas (out of v0.1.0 scope)

- **Chunk the initial reindex** into transactions of N=500 files, committing per chunk. Reduces WAL pressure.
- **Profile a single problematic subdir** (e.g., `discourse/plugins/discourse-narrative-bot`) to identify per-file slowness.
- **Defer cross-file resolution** (callers/refs) to a second pass after the symbol-only first pass.
- **Skip `*.yml`/`*.yaml`/`*.builder`** at index time unless explicitly opted in — the scanner picks them up but the indexer parses them as Ruby.

## How to reproduce

```sh
zig build "-Dgit_sha=$(git rev-parse --short HEAD)"
REFRACT_PILOT_DIR=/tmp/refract-pilot ./scripts/pilot.sh mastodon
```

Pass any of `discourse`, `mastodon`, `gitlabhq` as args. Without args, runs all three.
