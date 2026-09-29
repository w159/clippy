import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import type { ClipRow } from "./types.js";

/**
 * Sensitive-clip exclusion (SEC-02 follow-through).
 *
 * The app records which clips look sensitive (card numbers, SSNs, API keys...)
 * in a JSON sidecar: `<media>/_sidecar/sensitive-flags.json`, written by
 * Swift's `SensitiveFlagStore`. It maps `Clip.contentKey` (a hash, never the
 * content) to `{ kinds, confidence, flaggedAt, userOverride }`, where
 * `confidence` is 0 low / 1 medium / 2 high and `userOverride` is
 * true | false | null. This module reads that file and lets the tools withhold
 * flagged clips from search, list and get.
 *
 * Fail-closed: a missing file means nothing is flagged, but a file that exists
 * and cannot be parsed means we cannot tell, so every clip is withheld.
 */

/** Only `.medium` (1) and above marks a clip sensitive (SensitiveContent.sensitiveThreshold). */
const SENSITIVE_THRESHOLD = 1;

interface FlagEntry {
  confidence?: number;
  userOverride?: boolean | null;
}

export interface SensitiveFlags {
  /** True when the sidecar exists but could not be read: treat everything as sensitive. */
  unreadable: boolean;
  entries: Map<string, FlagEntry>;
}

/** `Application Support/Clippy/media/_sidecar/sensitive-flags.json`. */
export function sensitiveFlagsPath(supportDir: string): string {
  return path.join(supportDir, "media", "_sidecar", "sensitive-flags.json");
}

export function loadSensitiveFlags(supportDir: string): SensitiveFlags {
  const file = sensitiveFlagsPath(supportDir);
  let raw: string;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return { unreadable: false, entries: new Map() };
    console.error("clippy-mcp: sensitive flag store unreadable; withholding all clip content");
    return { unreadable: true, entries: new Map() };
  }
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
    return { unreadable: false, entries: new Map(Object.entries(parsed) as [string, FlagEntry][]) };
  } catch {
    console.error("clippy-mcp: sensitive flag store malformed; withholding all clip content");
    return { unreadable: true, entries: new Map() };
  }
}

function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/** Mirrors Swift's `Clip.contentKey`. */
export function contentKey(row: Pick<ClipRow, "contentKind" | "contentText" | "mediaFilename"> & { filePath?: string | null }): string {
  if (row.contentKind === "image" || row.contentKind === "file") {
    if (row.mediaFilename) return `m-${row.mediaFilename}`;
    return `p-${sha256(row.filePath ?? row.contentText)}`;
  }
  return `t-${sha256(row.contentText)}`;
}

/** True when the clip must not be shown: an explicit user override wins, then the recorded flag. */
export function isSensitive(flags: SensitiveFlags, row: ClipRow & { filePath?: string | null }): boolean {
  if (flags.unreadable) return true;
  const entry = flags.entries.get(contentKey(row));
  if (!entry) return false;
  if (typeof entry.userOverride === "boolean") return entry.userOverride;
  return (entry.confidence ?? 0) >= SENSITIVE_THRESHOLD;
}

export const WITHHELD = "sensitive_content_withheld";
