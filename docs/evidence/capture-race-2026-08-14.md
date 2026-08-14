# Dropped copies: slow multi-flavor pasteboard writers

Date: 2026-08-14
Machine: macOS (Darwin 25.6.0), `pollingIntervalMs` = 600, `captureSoundID` = system:Blow

## Symptom as reported

"When I copy something the sound doesn't play. Often I need to copy several times
before the sound plays." Started roughly two weeks earlier with no code or app change
(installed binary dated Jul 6).

## Discriminating observations

The user confirmed that when the sound is missing, the menu bar mascot does **not**
bounce and the clip does **not** appear in history. `playCaptureSound()` posts
`.clippyDidCapture` before the sound-enabled check, so no bounce means the capture path
never ran at all. That ruled out the audio layer (NSSound cache, Bluetooth output idle)
and pointed at the pasteboard poll.

Two paths were ruled out with data, not reasoning:

- No capture errors logged since 2026-07-23 in
  `~/Library/Application Support/Clippy/Logs/clippy.log` (level is warning, so errors
  would be recorded). The DB-write failure path is not what regressed.
- Poll health is fine: 15 of 15 `pbcopy` writes captured, median latency 576ms against
  the 600ms interval.

## Root cause

`ClipboardMonitor.tick()` advanced `lastChangeCount` before knowing whether anything had
been captured. An app that writes several pasteboard flavors bumps `changeCount` on
`clearContents()` and fills the data in some time later. A poll landing in that gap saw a
new `changeCount` over an empty pasteboard, retired it, and the copy was gone: the
`changeCount` never comes around again, so there was no clip, no bounce and no sound.

## Repro

`pbwrite.swift` writes the pasteboard two ways: `fast` (clearContents + setString back to
back, what `pbcopy` does) and `slow` (a 300ms gap before the data lands). `race_probe.py`
runs six of each against the live app and reports whether the clip row's `createdAt`
moved.

### Before the fix (installed build, 2026-07-06)

```
fast round 1-6: HIT
--> fast: 0/6 copies dropped

slow round 1: MISS
slow round 2: MISS
slow round 3: MISS
slow round 4: HIT
slow round 5: MISS
slow round 6: MISS
--> slow: 5/6 copies dropped
```

### After the fix

```
fast round 1-6: HIT
--> fast: 0/6 copies dropped

slow round 1-6: HIT
--> slow: 0/6 copies dropped
```

### Grace period and privacy checks

```
1.2s-gap write captured: True   (inside the 2s grace, as intended)
concealed write captured: False (org.nspasteboard.ConcealedType still never recorded)
```

## Ceiling

A writer that takes longer than the 2s grace still loses its copy. `setString` does not
bump `changeCount` - only `clearContents` does - so once a change is retired, data landing
later is invisible to the poll. Raising the grace trades that against how long an
unsupported flavor keeps the poll re-reading the pasteboard.

## Not fixed here

- `captureFileIfPresent` retires the change even when every file save throws, so a failed
  file copy is silent. The user's log shows this happened repeatedly through 2026-07-23.
- `skipNextChange` is consumed by whichever change the next tick observes, so a user copy
  landing in the same poll window as Clippy's own paste-write is swallowed.
