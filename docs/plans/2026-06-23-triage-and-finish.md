# Plan: triage WIP diff + finish pending verifications + junk cleanup

Date: 2026-06-23
Status: in progress

## Goal
1. Triage the uncommitted 6-file working-tree diff (coherent? complete? builds?).
2. Finish pending verifications from the 2026-06-17 run (heavy-stream runtime proof for the AI freeze fix; GUI runtime for file-clips / column-grid / date-buckets).
3. Remove iCloud-collision ` 2` junk files (untracked duplicates).

## Stage map

### Stage 1 - Discover (parallel, no deps)
- 1A [explorer] Map the uncommitted diff across the 6 files: what each change does, whether it is coherent and complete, whether it looks mid-refactor, any obvious build/test risk. Failable check: report names each changed behavior with file:line evidence and a coherent/incoherent verdict.
- 1B [cheap inline] Confirm the ` 2` files are byte-identical duplicates of tracked originals and are untracked. Failable check: `diff -q` returns identical for each pair; `git ls-files` shows originals tracked, ` 2` not.

### Stage 2 - Decide on the WIP diff (depends on 1A)
- If coherent + builds: keep, then verify.
- If mid-refactor / broken: finish it via `atlas:implementer` (one bounded change) or revert.
- Gate before commit/revert (writes).

### Stage 3 - Finish pending verifications (depends on 2; needs a building app)
- 3A [verifier/xcode] Heavy-stream runtime proof: stream a >=40 KB Ollama response, watch CPU/RSS, confirm flat (no cpu_resource.diag). Failable check: heavy stream completes with CPU low and RSS flat; red->green vs the old 88-96% CPU / 1.6-2.1 GB pinning.
- 3B [verifier/xcode] GUI runtime for file-clips capture/paste/move/extract, column grid, date buckets. Failable check: each behavior observed in the running app with a screenshot/log.

### Stage 4 - Junk cleanup (can run after 1B confirms; gate before delete)
- Delete the confirmed-duplicate ` 2` files. Failable check: `git status` clean of ` 2` entries.

### Stage 5 - Synthesize + docs
- Update docs/.run/STATE.md + findings.json; dispatch atlas:docs-curator to reconcile CHANGELOG/ROADMAP and affected subfolders for whatever shipped.

## Notes
- I am orchestrator only; no direct code edits. All edits via atlas:implementer; all discovery via atlas:explorer; all verification via a separate atlas:verifier.
- Build/test commands: `swift build`, `swift build -c release`, `swift test`. Runtime via xcode MCP or ad-hoc signed build.