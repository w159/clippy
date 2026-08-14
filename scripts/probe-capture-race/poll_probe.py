#!/usr/bin/env python3
"""Measure Clippy's copy->capture latency and count dropped copies.

Writes one marker string to the pasteboard repeatedly. Clippy dedupes on
content text, so this bumps createdAt on a single row instead of littering
history. A round is a MISS if createdAt never moves within the deadline,
which means that copy was dropped entirely (no clip, no bounce, no sound).
"""

import os
import sqlite3
import subprocess
import sys
import time

DB = os.path.expanduser("~/Library/Application Support/Clippy/clippy.sqlite")
MARK = "CLIPPY-POLL-PROBE-8f3a"
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 15
DEADLINE_S = 10.0
GAP_S = 1.2


def marker_created_at():
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    try:
        row = con.execute(
            "SELECT createdAt FROM clips WHERE contentText = ?", (MARK,)
        ).fetchone()
        return row[0] if row else None
    finally:
        con.close()


results = []
prev = marker_created_at()
for i in range(ROUNDS):
    t0 = time.time()
    subprocess.run(["pbcopy"], input=MARK.encode(), check=True)
    seen = None
    while time.time() - t0 < DEADLINE_S:
        cur = marker_created_at()
        if cur != prev:
            seen = time.time() - t0
            prev = cur
            break
        time.sleep(0.05)
    results.append(seen)
    print(
        f"round {i + 1:>2}: {'MISS' if seen is None else f'{seen * 1000:6.0f} ms'}",
        flush=True,
    )
    time.sleep(GAP_S)

hits = [r for r in results if r is not None]
print(f"\nhits {len(hits)}/{ROUNDS}   misses {ROUNDS - len(hits)}")
if hits:
    s = sorted(hits)
    print(
        f"min {s[0] * 1000:.0f} ms   median {s[len(s) // 2] * 1000:.0f} ms   max {s[-1] * 1000:.0f} ms"
    )
