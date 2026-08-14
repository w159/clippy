#!/usr/bin/env python3
"""Does Clippy drop a copy when the writing app is slow to fill the pasteboard?

`fast` is the control: clearContents + setString back to back (what pbcopy does).
`slow` mimics a real multi-flavor writer: changeCount bumps on clearContents,
the data lands 300ms later. Clippy polls every 600ms, so a poll landing in that
gap sees a new changeCount over an empty pasteboard.

Two fixed marker strings are reused so Clippy's dedupe bumps two existing rows
instead of littering history.
"""

import os
import sqlite3
import subprocess
import time

DB = os.path.expanduser("~/Library/Application Support/Clippy/clippy.sqlite")
BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pbwrite")
ROUNDS = 6
DEADLINE_S = 4.0


def created_at(mark):
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    try:
        row = con.execute(
            "SELECT createdAt FROM clips WHERE contentText = ?", (mark,)
        ).fetchone()
        return row[0] if row else None
    finally:
        con.close()


for mode in ("fast", "slow"):
    mark = f"CLIPPY-RACE-{mode.upper()}"
    prev = created_at(mark)
    misses = 0
    for i in range(ROUNDS):
        subprocess.run([BIN, mode, mark], check=True, capture_output=True)
        t0 = time.time()
        hit = False
        while time.time() - t0 < DEADLINE_S:
            cur = created_at(mark)
            if cur != prev:
                prev, hit = cur, True
                break
            time.sleep(0.05)
        if not hit:
            misses += 1
        print(f"{mode:>4} round {i + 1}: {'HIT' if hit else 'MISS'}", flush=True)
        time.sleep(1.0)
    print(f"--> {mode}: {misses}/{ROUNDS} copies dropped\n", flush=True)
