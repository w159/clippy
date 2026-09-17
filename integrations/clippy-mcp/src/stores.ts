import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

/**
 * Scripts and AI actions live in JSON files next to the database, not in it:
 * `scripts.json` and `ai-actions.json` in Application Support/Clippy, written by
 * the app's `JSONFileStore`. Reading and writing them here is what makes
 * "add a script that does X" possible from an MCP client at all.
 *
 * The app holds these lists in memory, so it polls both files for an external
 * modification (ClipDatabase's ExternalChangeWatcher) and reloads rather than
 * clobbering our write on its next save. Writes here are atomic - a temp file
 * plus rename - so the app never observes a half-written file.
 */

export interface Script {
  id: string;
  name: string;
  interpreter: string;
  body: string;
  feedsClipboard: boolean;
  outputToClipboard: boolean;
  createdAt: string;
  updatedAt: string;
  sortOrder: number;
  /**
   * Clippy executes scripts. A script created from here lands disabled and the
   * app's ScriptRunner refuses to run it until a human enables it in Settings,
   * so an MCP client cannot turn a clipboard manager into a shell.
   */
  isEnabled: boolean;
}

export interface AIAction {
  id: string;
  name: string;
  promptTemplate: string;
  outputDisposition: string;
  temperature: number;
  maxTokens: number;
  symbolName: string;
  iconKind: string;
  isBuiltIn: boolean;
  sortOrder: number;
}

/** Mirrors Swift's `ScriptInterpreter` cases; an unknown value fails to decode. */
export const SCRIPT_INTERPRETERS = [
  "zsh",
  "bash",
  "sh",
  "python3",
  "node",
  "ruby",
  "applescript",
  "swift",
] as const;
export const OUTPUT_DISPOSITIONS = ["proposeEdit", "copyToClipboard", "newClip"] as const;

/** Swift's `.iso8601` date strategy: whole seconds, Z suffix, no fraction. */
export function swiftISODate(date: Date = new Date()): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function newID(): string {
  return randomUUID().toUpperCase();
}

function readArray<T>(filePath: string): T[] {
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as T[]) : [];
  } catch {
    // Absent or unreadable is an empty list, the same conclusion the app's
    // JSONFileStore reaches. A malformed file must not take the server down.
    return [];
  }
}

function writeArray<T>(filePath: string, items: T[]): void {
  // Match the app's encoder: pretty-printed with sorted keys, so a file written
  // here and a file written by Clippy diff cleanly against each other.
  const body = JSON.stringify(items.map(sortKeys), null, 2);
  const temp = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(temp, body, "utf8");
  fs.renameSync(temp, filePath);
}

function sortKeys<T>(value: T): T {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return value;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(value as Record<string, unknown>).sort()) {
    out[key] = (value as Record<string, unknown>)[key];
  }
  return out as T;
}

export class JsonListStore<T extends { id: string; sortOrder: number }> {
  constructor(private readonly filePath: string) {}

  all(): T[] {
    return readArray<T>(this.filePath).sort((a, b) => a.sortOrder - b.sortOrder);
  }

  find(id: string): T | undefined {
    return this.all().find((item) => item.id === id);
  }

  /** Next free sortOrder, so a new entry lands after everything that exists. */
  nextSortOrder(): number {
    const orders = this.all().map((item) => item.sortOrder);
    return orders.length === 0 ? 0 : Math.max(...orders) + 1;
  }

  add(item: T): T {
    writeArray(this.filePath, [...readArray<T>(this.filePath), item]);
    return item;
  }

  /** Shallow-merges `changes` into the stored entry. Returns the new value. */
  update(id: string, changes: Partial<T>): T | undefined {
    const items = readArray<T>(this.filePath);
    const index = items.findIndex((item) => item.id === id);
    if (index === -1) return undefined;
    const merged = { ...items[index], ...changes, id } as T;
    items[index] = merged;
    writeArray(this.filePath, items);
    return merged;
  }

  remove(id: string): boolean {
    const items = readArray<T>(this.filePath);
    const remaining = items.filter((item) => item.id !== id);
    if (remaining.length === items.length) return false;
    writeArray(this.filePath, remaining);
    return true;
  }
}

export function scriptStore(supportDir: string): JsonListStore<Script> {
  return new JsonListStore<Script>(path.join(supportDir, "scripts.json"));
}

export function aiActionStore(supportDir: string): JsonListStore<AIAction> {
  return new JsonListStore<AIAction>(path.join(supportDir, "ai-actions.json"));
}
