import { existsSync } from "node:fs";
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
  // Clippy owns creation, WAL setup, and every migration. Refuse to create an
  // empty database when the app has not been launched or the path is wrong.
  if (!existsSync(dbPath)) {
    throw new Error("database file does not exist; launch Clippy once so it can create it");
  }
  const db = new DatabaseSync(dbPath);
  try {
    // Wait for the app's short writes rather than failing immediately with SQLITE_BUSY.
    db.exec("PRAGMA busy_timeout = 5000;");
    db.exec("PRAGMA foreign_keys = ON;");
    requireAppSchema(db);
  } catch (err) {
    db.close();
    throw err;
  }
  return db;
}

/** Refuse to run against a database that lacks the schema MCP handlers require. */
export function requireAppSchema(db: DatabaseSync): void {
  const requiredColumns: Record<string, string[]> = {
    clips: ["contentText", "typeIdentifier", "sourceAppName", "createdAt", "contentKind", "userTitle", "ocrText"],
    category: ["name", "colorHex", "iconKind", "iconValue", "sortOrder", "isStarter", "createdAt"],
    clip_category: ["clipID", "categoryID", "addedAt"],
  };
  const requiredTables = [...Object.keys(requiredColumns), "clips_fts", "smart_collections"];
  const presentTables = new Set(
    (db.prepare(`SELECT name FROM sqlite_master WHERE type = 'table'`).all() as { name: string }[]).map(
      (row) => row.name,
    ),
  );
  const missingTables = requiredTables.filter((name) => !presentTables.has(name));
  const missingColumns: string[] = [];
  for (const [table, columns] of Object.entries(requiredColumns)) {
    if (!presentTables.has(table)) continue;
    const presentColumns = new Set(
      (db.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]).map((row) => row.name),
    );
    for (const column of columns) {
      if (!presentColumns.has(column)) missingColumns.push(`${table}.${column}`);
    }
  }
  if (missingTables.length > 0 || missingColumns.length > 0) {
    const details = [
      missingTables.length > 0 ? `missing tables: ${missingTables.join(", ")}` : "",
      missingColumns.length > 0 ? `missing columns: ${missingColumns.join(", ")}` : "",
    ].filter(Boolean).join("; ");
    throw new Error(`database schema is not ready for MCP (${details}); launch/update Clippy first`);
  }
}

/** Run a mutating tool atomically, taking the SQLite write lock before any reads. */
export function inWriteTransaction<T>(db: DatabaseSync, body: () => T): T {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = body();
    db.exec("COMMIT");
    return result;
  } catch (err) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // Preserve the original failure if SQLite already ended the transaction.
    }
    throw err;
  }
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
