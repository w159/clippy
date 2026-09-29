import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";

/**
 * Append-only, hash-chained audit stream for MCP tool calls (SEC-08).
 *
 * Writes `<supportDir>/audit/mcp-audit-yyyy-MM.jsonl`, the same directory the
 * Clippy app's `AuditLog` uses (`Application Support/Clippy/audit`). The app's
 * `verify()` reads both streams. One JSON object per line:
 *
 *   { ts, actor, action, detail, clipIDs, prev }
 *
 * `prev` is the lowercase-hex SHA-256 of the previous line's exact bytes (no
 * trailing newline), or 64 zeros for the first line of a file. Lines never
 * carry clip content: only the tool name, an outcome, argument NAMES and ids.
 * Files are created 0600, the directory 0700.
 */

export const GENESIS = "0".repeat(64);

export interface AuditEntry {
  ts: string;
  actor: string;
  action: string;
  detail: string;
  clipIDs: number[];
  prev: string;
}

function sha256Hex(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

/** `mcp-audit-2026-09.jsonl` for a UTC date. */
export function auditFileName(date: Date = new Date()): string {
  return `mcp-audit-${date.toISOString().slice(0, 7)}.jsonl`;
}

function lastLine(file: string): Buffer | null {
  let data: Buffer;
  try {
    data = fs.readFileSync(file);
  } catch {
    return null;
  }
  let end = data.length;
  while (end > 0 && data[end - 1] === 0x0a) end--;
  if (end === 0) return null;
  const start = data.lastIndexOf(0x0a, end - 1) + 1;
  return data.subarray(start, end);
}

/** Cross-process lock: the stdio server and the app-hosted HTTP server may append at once. */
function withLock<T>(lockPath: string, body: () => T): T {
  const deadline = Date.now() + 2000;
  for (;;) {
    try {
      const fd = fs.openSync(lockPath, "wx", 0o600);
      fs.closeSync(fd);
      break;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
      try {
        // A crashed writer leaves a stale lock; break locks older than 5s.
        if (Date.now() - fs.statSync(lockPath).mtimeMs > 5000) fs.rmSync(lockPath, { force: true });
      } catch {
        /* raced with the holder releasing it */
      }
      if (Date.now() > deadline) throw new Error("audit lock timeout");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
  }
  try {
    return body();
  } finally {
    fs.rmSync(lockPath, { force: true });
  }
}

/**
 * Appends one entry. Never throws: an audit failure is reported on stderr and
 * must not break the tool call it describes.
 */
export function appendAudit(
  supportDir: string,
  entry: { actor?: string; action: string; detail: string; clipIDs?: number[] },
  now: Date = new Date(),
): void {
  try {
    const dir = path.join(supportDir, "audit");
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const file = path.join(dir, auditFileName(now));
    withLock(`${file}.lock`, () => {
      const previous = lastLine(file);
      const line: AuditEntry = {
        ts: now.toISOString(),
        actor: entry.actor ?? "mcp",
        action: entry.action,
        detail: entry.detail,
        clipIDs: entry.clipIDs ?? [],
        prev: previous ? sha256Hex(previous) : GENESIS,
      };
      const fd = fs.openSync(file, "a", 0o600);
      try {
        fs.writeSync(fd, JSON.stringify(line) + "\n");
      } finally {
        fs.closeSync(fd);
      }
    });
  } catch (err) {
    console.error(`clippy-mcp: audit write failed (${err instanceof Error ? err.message : String(err)})`);
  }
}

/** Clip ids a tool call touched, from its arguments and (for clip tools) its result. Never content. */
export function clipIDsFor(tool: string, args: unknown, result: unknown): number[] {
  const ids = new Set<number>();
  const a = (args && typeof args === "object" ? args : {}) as Record<string, unknown>;
  const r = (result && typeof result === "object" ? result : {}) as Record<string, unknown>;
  const add = (v: unknown) => {
    if (typeof v === "number" && Number.isInteger(v)) ids.add(v);
  };
  switch (tool) {
    case "clippy_get_clip":
    case "clippy_update_clip":
      add(a.id);
      break;
    case "clippy_delete_clips":
      (Array.isArray(a.ids) ? a.ids : []).forEach(add);
      break;
    case "clippy_assign_clips":
      (Array.isArray(a.clipIDs) ? a.clipIDs : []).forEach(add);
      break;
    case "clippy_create_clip":
      add(r.id);
      break;
    case "clippy_search_clips":
    case "clippy_list_recent":
      (Array.isArray(r.results) ? r.results : []).forEach((row) => add((row as { id?: unknown }).id));
      break;
  }
  return [...ids];
}
