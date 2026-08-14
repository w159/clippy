# Atlas run state - clippy

Last updated: 2026-08-14

## Current run: 2026-08-14 dropped-copy / missing capture sound

### Verified this session (uncommitted)
- ROOT CAUSE, reproduced deterministically: `ClipboardMonitor.tick()` retired
  `lastChangeCount` before knowing whether anything was captured, so a copy from an app
  that fills the pasteboard in stages (changeCount bumps on `clearContents()`, data lands
  up to a few hundred ms later) was dropped for good. No clip, no mascot bounce, no sound.
  Repro: 5 of 6 copies dropped against a 300ms fill gap; 0 of 6 for an instant write.
- FIX VERIFIED end to end against a rebuilt `build/Clippy.app`: 0 of 6 dropped for both
  writer shapes. A 1.2s gap (inside the 2s grace) is captured. A
  `org.nspasteboard.ConcealedType` write is still never captured, so the retry does not
  leak password-manager copies. GREEN.
  Evidence: docs/evidence/capture-race-2026-08-14.md. Probes: scripts/probe-capture-race/.
- Ruled out with data, not reasoning: audio layer (user confirmed no mascot bounce and no
  clip on failure), DB-write failures (no errors logged since 2026-07-23), poll starvation
  (15/15 pbcopy captures, median 576ms against the 600ms interval).

### Not verified
- Tests/ClippyTests/ClipboardMonitorRaceTests.swift has never compiled: this machine has
  CommandLineTools only, no Xcode, so XCTest is unavailable and `swift test` cannot run.
  To test: `swift test --filter ClipboardMonitorRaceTests`. Expected: 2 tests pass.

### Open / next
- Decide which build runs (dev build from build/ vs /Applications v1.8 vs cut a release).
- Run `swift test` on a machine with Xcode before committing.
- Two pre-existing silent-drop paths recorded, not fixed: `captureFileIfPresent` retires
  the change even when every file save throws; `skipNextChange` can swallow a user copy
  that lands in the same poll window as Clippy's own paste-write.

## Previous run: 2026-06-23 triage + finish pending verifications

## Current run: 2026-06-23 triage + finish pending verifications

### Completed this session (verified, committed in 726f5d4)
- Triaged the uncommitted 6-file WIP diff: coherent-and-complete, builds (3.87s).
- Independent verifier: off-main-thread capture/search refactor is thread-safe (serial
  GRDB DatabaseQueue at ClipDatabase.swift:122; @Published/refilterToken hopped to main).
  No data race. GREEN.
- Test gate: swift test -> 301 tests, 0 failures (after deleting the ` 2` files and
  `xattr -cr .build` to clear iCloud resource-fork detritus). GREEN.
- Deleted three untracked iCloud-collision ` 2` paths that broke swift test via duplicate
  XCTestCase redeclarations.
- Committed locally (726f5d4): off-main-thread capture/search, status-bar icon fix,
  .aiActions panel nav wiring, ` 2` cleanup, CHANGELOG entry. NOT pushed.

### Not yet verified with runtime evidence (blocked on manual UI interaction)
- Verification A: heavy-stream (>=40 KB) AI freeze proof. Runbook:
  docs/plans/2026-06-23-runtime-verification-runbook.md.
- Verification B: GUI runtime for file-clips / column grid / date buckets. Same runbook.
These need a human driving the running menu-bar app; cannot be automated from the
orchestration context. Status: not-done-with-evidence (do not mark verified).

### Open / next
- Execute the runtime runbook (user, via `!` commands); capture evidence under docs/evidence/.
- Push 726f5d4 to origin/main when ready (outward write - gate separately).
- After runtime evidence lands, dispatch atlas:docs-curator to move the prior
  verified-partial / build-verified items to verified in CHANGELOG and findings.json.

## Prior run (2026-06-17) - see docs/.run/findings.json
AI assistant freeze diagnosis + feature batch (search grammar verified; file-clip storage
verified; column grid / date buckets / streaming selection build-verified; freeze fix
verified-partial pending the heavy-stream proof above).