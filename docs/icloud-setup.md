# iCloud sync

Clippy syncs through **iCloud Drive**, not CloudKit. This is deliberate: CloudKit
needs App Store or development provisioning that a directly-distributed
(Developer ID + Sparkle) app cannot have, and calling CloudKit without that
entitlement crashes the app. The iCloud Drive approach needs no entitlement and
works in the normal release build.

## How it works

When "Sync clips and categories through iCloud Drive" is on, Clippy writes its
archive to:

```
~/Library/Mobile Documents/com~apple~CloudDocs/Clippy/clippy-sync.clippyarchive/clippy.toml
```

That folder is the local mirror of your iCloud Drive, so the file uploads
automatically and appears on your other Macs under **iCloud Drive > Clippy**.
On each sync (at launch, when you toggle it on, or via "Sync now") Clippy:

1. Reads the file another Mac may have written and merges it in
   (`ClippyArchive.importTOML`, which only adds and updates, never clears), then
2. Writes the merged local state back.

Because the merge is non-destructive, two Macs converge instead of overwriting
each other.

## Requirements

- iCloud Drive enabled in System Settings > [your name] > iCloud.
- Nothing else. No CloudKit container, no entitlement, no provisioning profile.

## Scope and limits

- Categories and the clips pinned into them sync (the same data the
  `clippy.toml` export covers). Loose, unpinned history is intentionally local.
- The archive is a package folder (`clippy-sync.clippyarchive`) holding
  `clippy.toml` plus a `media/` folder, so image and file clip **bytes** travel
  with it and import on another Mac through package-relative paths (DAT-07).
- The merge is content-based and runs on demand; it is not real-time. For a
  personal setup this is plenty; a future version could watch the file for
  changes and sync continuously.
