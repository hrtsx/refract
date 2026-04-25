#!/usr/bin/env python3
"""Compare two bench-results directories produced by realistic_run.sh.

Emits a delta table to stdout and one `REGRESSION p95 X.Y%` line per metric
that regressed. Caller (CI) parses the REGRESSION lines and fails the PR
when any session-mode op p95 regresses > 15%.

Usage: compare.py <head_dir> <base_dir>
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


REGRESSION_THRESHOLD_PCT = 15.0


def load_run(path: Path) -> dict:
    """Load the most-recent JSON snapshot under `path`."""
    if path.is_file():
        return json.loads(path.read_text())
    json_files = sorted(path.glob("*.json"))
    if not json_files:
        raise FileNotFoundError(f"no JSON snapshots under {path}")
    return json.loads(json_files[-1].read_text())


def metrics(run: dict) -> dict[tuple[str, str, str], float]:
    """Flatten {server, workload, op} -> p95_ms."""
    out: dict[tuple[str, str, str], float] = {}
    for server, workloads in run.get("servers", {}).items():
        for workload, ops in workloads.items():
            for op, vals in ops.items():
                p95 = vals.get("p95_ms")
                if p95 is None:
                    continue
                out[(server, workload, op)] = float(p95)
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    head_dir = Path(sys.argv[1])
    base_dir = Path(sys.argv[2])

    head = load_run(head_dir)
    base = load_run(base_dir)

    head_m = metrics(head)
    base_m = metrics(base)

    keys = sorted(set(head_m) & set(base_m))
    if not keys:
        print("no shared metrics", file=sys.stderr)
        return 0

    width = max(len(f"{s} {w} {op}") for s, w, op in keys) + 2

    print(f"{'metric':<{width}}{'base p95':>12}{'head p95':>12}{'delta':>10}")
    print("-" * (width + 34))

    regressions: list[str] = []
    for key in keys:
        server, workload, op = key
        b = base_m[key]
        h = head_m[key]
        if b <= 0:
            delta_pct = 0.0
        else:
            delta_pct = ((h - b) / b) * 100.0
        label = f"{server} {workload} {op}"
        sign = "+" if delta_pct >= 0 else ""
        print(f"{label:<{width}}{b:>11.2f}ms{h:>11.2f}ms{sign}{delta_pct:>8.1f}%")

        # Only fail on session-mode regressions (typing + micro have higher
        # variance and aren't merge-gates per Lane S5).
        if workload == "session" and delta_pct > REGRESSION_THRESHOLD_PCT:
            regressions.append(f"REGRESSION p95 {delta_pct:.1f}% — {label}")

    if regressions:
        print()
        for r in regressions:
            print(r)

    return 0


if __name__ == "__main__":
    sys.exit(main())
