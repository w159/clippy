# Runtime verification runbook - pending items from the 2026-06-17 run

Date: 2026-06-23
Status: not yet executed (requires manual interaction with the running menu-bar app)

These two verifications were left open by the 2026-06-17 run (docs/.run/findings.json).
They need a human driving the Clippy UI; they cannot be automated from the
orchestration context (atlas:ui-runtime-tester is browser-driven, not SwiftUI, and
auto-launching a clipboard monitor would hijack the session). Run them with `!`
prefix commands so output lands in the session.

## Preconditions

- `xattr -cr .build` then `swift build -c release` (verified 2026-06-23: Build complete! 42.42s).
- Ollama running on localhost:11434 (verified up; models incl. cloud streaming models available).
- Ad-hoc signed app bundle, as the prior run did: copy the release executable into an
  ad-hoc signed `/tmp/ClippyTest.app` (see prior evidence docs/evidence/runtime-cpu-mem-verified.txt).

## Verification A - heavy-stream AI freeze proof (closes the freeze fix airtight)

Original symptom (verbatim): the AI assistant locked Clippy up at 100% CPU / ~2 GB RAM
on a ~48.9 KB streamed Ollama response (64s), force-quit required. The fix removed
.textSelection from the live streaming Text. The 2026-06-17 run reproduced only a 1.6 KB
/ 60s stream (peak 9.3% CPU, RSS flat 314 MB); the >=40 KB heavy case was NOT reproduced.

Red state to reproduce-then-green:
1. Build the FIXED binary (current main, commit 726f5d4, includes the freeze fix from the
   prior run plus today's off-main-thread refactor).
2. Launch the app, open the AI assistant panel, send a prompt that yields a LONG essay
   (>=40 KB) to a fast streaming model, e.g. a cloud model on Ollama. Prompt idea:
   "Write a 6000-word essay on the history of computing, no markdown."
3. While it streams, run a watcher in another terminal (60s window):

   `! top -l 5 -pid $(pgrep -n Clippy) | grep -E "Clippy|CPU" ; ps -o pid,rss,cpu -p $(pgrep -n Clippy)`

   Also watch for a new cpu_resource.diag via Activity Monitor / spindump absence.

Pass criteria (red->green evidence):
- Peak CPU stays low (target < 15%; old was 88-96%).
- RSS stays flat (target < ~400 MB; old grew to 1.6-2.1 GB).
- No new cpu_resource.diag / no force-quit needed; the stream completes.
- Capture the watcher output into docs/evidence/runtime-heavy-stream-2026-06-23.txt.

Failable check: a >=40 KB stream completes with CPU low and RSS flat. If CPU pins or
RSS climbs unbounded, the fix is NOT airtight - report red.

## Verification B - GUI runtime for the feature batch (file-clips, column grid, date buckets)

These were build-verified only (docs/.run/findings.json feature_batch). Observe each in
the running app:

1. File clips: copy a file in Finder (Cmd+C on a file), confirm Clippy captures it as a
   file clip; paste it somewhere; move it to a category; extract/open it. Confirm each step.
2. Column/grid layout: open the clips panel, toggle the grid/column view, confirm it renders.
3. Date buckets: confirm clips group under date bucket headers (Today / Yesterday / etc.).

Pass criteria:
- Each behavior observed in the running app; capture a screenshot per behavior into
  docs/evidence/gui-<behavior>-2026-06-23.png.
- No crash / no freeze during the flow.

Failable check: all three behaviors render and operate correctly at runtime. A behavior
that only builds but does not work in the app = red for that item.

## After capture

Hand the captured evidence files back to the orchestrator (or commit them). Once
Verification A and B are green with artifacts under docs/evidence/, dispatch
atlas:docs-curator to move those items from "verified-partial / build-verified" to
"verified" in CHANGELOG/docs/.run/findings.json. Until then they remain
not-verified-with-runtime-evidence.