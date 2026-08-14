#!/usr/bin/env python3
"""Safety check on the retry fix.

The retry loop re-reads a pasteboard that was not filled in yet. It must never
turn a password-manager copy (marked org.nspasteboard.ConcealedType) into a
clip, and it must still capture a writer slower than 300ms but inside the
2s grace.
"""

import os
import sqlite3
import subprocess
import time

DB = os.path.expanduser("~/Library/Application Support/Clippy/clippy.sqlite")
BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pbwrite")


def exists(mark):
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    try:
        return (
            con.execute("SELECT 1 FROM clips WHERE contentText = ?", (mark,)).fetchone()
            is not None
        )
    finally:
        con.close()


# 1.2s fill gap: inside the grace, must be captured.
mark = "CLIPPY-RACE-SLOWER"
before = exists(mark)
subprocess.run([BIN, "slower", mark], check=True, capture_output=True)
time.sleep(4)
print(f"1.2s-gap write captured: {exists(mark)}  (was present before: {before})")

# Concealed write: must never be captured, not even by the retry.
secret = "CLIPPY-RACE-CONCEALED-secret"
subprocess.run([BIN, "concealed", secret], check=True, capture_output=True)
time.sleep(5)
print(f"concealed write captured: {exists(secret)}  (must be False)")
