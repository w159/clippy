import type { DatabaseSync } from "node:sqlite";
import { z } from "zod";

/** Everything a tool handler needs, assembled once at startup. */
export interface ToolContext {
  db: DatabaseSync;
  /** Absolute path to clippy.sqlite. */
  dbPath: string;
  /** Application Support/Clippy - holds media/, scripts.json, ai-actions.json. */
  supportDir: string;
}

export interface ToolDef {
  name: string;
  description: string;
  schema: z.ZodTypeAny;
  /**
   * True for tools that change state. `index.ts` annotates them for clients and
   * writes an audit line for every call, because a clipboard database at a
   * regulated firm is client data and "who changed what" has to be answerable.
   */
  mutates?: boolean;
  handler: (context: ToolContext, args: any) => unknown;
}

// ---------------------------------------------------------------------------
// Database row shapes (the subset of columns the tools read)
// ---------------------------------------------------------------------------

export interface ClipRow {
  id: number;
  contentText: string;
  typeIdentifier: string;
  sourceAppName: string | null;
  sourceAppBundleID: string | null;
  userTitle: string | null;
  createdAt: string;
  contentKind: string;
  mediaFilename: string | null;
  thumbFilename: string | null;
  pixelWidth: number | null;
  pixelHeight: number | null;
  byteSize: number | null;
}

export interface CategoryRow {
  id: number;
  name: string;
  colorHex: string;
  iconKind: string;
  iconValue: string;
  sortOrder: number;
  isStarter: number;
  createdAt: string;
}

// ---------------------------------------------------------------------------
// Shared schema fragments
// ---------------------------------------------------------------------------

/**
 * Positive integers are written as `.int().min(1)` rather than `.positive()`
 * throughout. `.positive()` serializes to an `exclusiveMinimum`, and getting the
 * JSON Schema dialect wrong on that one keyword silently removes the whole tool
 * from the client's tool list. `minimum` has no such trap. See test/smoke.mjs,
 * which fails the build if a boolean `exclusiveMinimum` ever comes back.
 */
export const clipID = z.number().int().min(1);
export const categoryID = z.number().int().min(1);
export const limitSchema = z.number().int().min(1).max(500).optional();
export const uuidSchema = z.string().uuid();
