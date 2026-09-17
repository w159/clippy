import { DatabaseSync } from "node:sqlite";
import os from "node:os";
import path from "node:path";

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

/** Expand a leading `~` and resolve to an absolute path. */
function expandHome(p: string): string {
  if (p === "~") return os.homedir();
  if (p.startsWith("~/")) return path.join(os.homedir(), p.slice(2));
  return path.resolve(p);
}

/**
 * The on-disk Clippy database. Matches ClipDatabase.swift:25-29 — the app puts
 * it at Application Support/Clippy/clippy.sqlite. CLIPPY_DB_PATH overrides it
 * (used by tests and by anyone with a non-default install).
 */
export function resolveDatabasePath(): string {
  const override = process.env.CLIPPY_DB_PATH;
  if (override && override.trim().length > 0) return expandHome(override.trim());
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Clippy",
    "clippy.sqlite",
  );
}

/** Sibling media directory holding image-clip payloads (MediaStore.swift). */
export function resolveMediaDir(dbPath: string): string {
  return path.join(path.dirname(dbPath), "media");
}

/**
 * Application Support/Clippy: the database's own directory, which also holds
 * `media/`, `scripts.json`, and `ai-actions.json`.
 */
export function resolveSupportDir(dbPath: string): string {
  return path.dirname(dbPath);
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

export function openDatabase(dbPath: string): DatabaseSync {
  // node:sqlite enables foreign-key constraints by default; we still set the
  // pragma explicitly so the intent survives any future default change.
  const db = new DatabaseSync(dbPath);
  // The app uses WAL; match it so our connection cooperates with the app's.
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec("PRAGMA foreign_keys = ON;");
  // Two writers share this file: Clippy and this process. Without a busy timeout
  // a write that lands while the app holds the lock fails immediately with
  // SQLITE_BUSY, which surfaces to the user as a tool that randomly errors. 5s is
  // far longer than any write Clippy makes (a capture is a single small insert).
  db.exec("PRAGMA busy_timeout = 5000;");
  return db;
}

// ---------------------------------------------------------------------------
// Date encoding
// ---------------------------------------------------------------------------

/**
 * GRDB stores Date as `YYYY-MM-DD HH:MM:SS.SSS` in UTC. We must write that exact
 * shape so the Swift app can decode our rows. See SCHEMA.md "Date handling".
 */
export function grdbNow(date: Date = new Date()): string {
  const iso = date.toISOString(); // 2026-06-11T21:30:00.000Z
  return iso.replace("T", " ").replace("Z", "");
}

/** Convert a stored GRDB datetime back to ISO-8601 for callers. */
export function grdbToIso(value: string | null | undefined): string | null {
  if (!value) return null;
  // Stored value is UTC without a zone marker; re-attach Z.
  const normalized = value.includes("T") ? value : value.replace(" ", "T");
  return normalized.endsWith("Z") ? normalized : `${normalized}Z`;
}

// ---------------------------------------------------------------------------
// FTS5 prefix pattern
// ---------------------------------------------------------------------------

/**
 * Build an FTS5 MATCH pattern equivalent to GRDB's
 * FTS5Pattern(matchingAllPrefixesIn:) — every token becomes a quoted prefix
 * term, AND-ed together. Quoting neutralizes FTS operators in user input.
 * Returns null when the query has no usable tokens (caller returns []).
 */
export function buildPrefixPattern(query: string): string | null {
  const tokens = query
    .split(/[^\p{L}\p{N}]+/u)
    .map((t) => t.trim())
    .filter((t) => t.length > 0);
  if (tokens.length === 0) return null;
  return tokens.map((t) => `"${t.replace(/"/g, '""')}"*`).join(" ");
}
