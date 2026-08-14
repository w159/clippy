# Capture-race probes

End-to-end repro for the dropped-copy defect in `ClipboardMonitor.tick()`
(docs/evidence/capture-race-2026-08-14.md). These drive the **running** app and read
`~/Library/Application Support/Clippy/clippy.sqlite` read-only, so they cover the poll
timing that a headless unit test cannot.

```sh
swiftc -O pbwrite.swift -o pbwrite
python3 poll_probe.py 15      # copy -> capture latency, counts dropped copies
python3 race_probe.py         # fast vs slow (300ms fill gap) writers
python3 concealed_probe.py    # 1.2s gap is captured; concealed type never is
```

Each probe reuses fixed marker strings so Clippy's dedupe bumps a handful of existing
rows instead of littering history. Expect the mascot to bounce and the capture sound to
fire once per round while they run. Search history for `CLIPPY-` to delete the markers
afterwards.
