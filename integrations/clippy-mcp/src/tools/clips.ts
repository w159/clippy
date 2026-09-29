import path from "node:path";
import { z } from "zod";
import type { DatabaseSync } from "node:sqlite";
import { buildPrefixPattern, grdbNow, grdbToIso, resolveMediaDir } from "../db.js";
import { clipID, limitSchema, type ClipRow, type ToolDef } from "../types.js";
import { WITHHELD, isSensitive, loadSensitiveFlags, type SensitiveFlags } from "../sensitive.js";

/**
 * Runs a paged query and keeps only clips the caller may see, until `limit`
 * are collected. Sensitive clips are dropped here, so a flagged clip never
 * reaches a search or list result and the page fill is not short-changed.
 */
function collectVisible(
  db: DatabaseSync,
  flags: SensitiveFlags,
  sql: string,
  params: unknown[],
  limit: number,
): ClipRow[] {
  const pageSize = Math.max(100, limit * 2);
  const statement = db.prepare(`${sql} LIMIT ? OFFSET ?`);
  const out: ClipRow[] = [];
  for (let offset = 0; out.length < limit; offset += pageSize) {
    // SAFETY: the statement selects `clips.*` and node:sqlite returns plain row objects with those
    // columns, which is exactly ClipRow's shape; TypeScript cannot check a runtime SQLite row.
    const page = statement.all(...(params as any[]), pageSize, offset) as unknown as ClipRow[];
    for (const row of page) {
      if (!isSensitive(flags, row)) out.push(row);
      if (out.length >= limit) break;
    }
    if (page.length < pageSize) break;
  }
  return out;
}

const PREVIEW_CHARS = 300;

function preview(text: string): string {
  const trimmed = text.trim();
  return trimmed.length > PREVIEW_CHARS ? `${trimmed.slice(0, PREVIEW_CHARS)}...` : trimmed;
}

function titleFor(row: Pick<ClipRow, "userTitle" | "sourceAppName">): string {
  return row.userTitle ?? row.sourceAppName ?? "Unknown app";
}

export function categoriesForClip(db: DatabaseSync, id: number) {
  return db
    .prepare(
      `SELECT c.id AS id, c.name AS name
         FROM clip_category cc
         JOIN category c ON c.id = cc.categoryID
        WHERE cc.clipID = ?
        ORDER BY c.sortOrder, c.createdAt`,
    )
    .all(id) as { id: number; name: string }[];
}

/**
 * The list shape every search/list tool returns. Deliberately a preview and not
 * the full text: a clipboard history holds whatever has been copied, up to and
 * including credentials and client records, and a broad search should not spray
 * all of it into a transcript. Full content comes from `clippy_get_clip`, one
 * deliberate id at a time.
 */
function summarize(db: DatabaseSync, row: ClipRow) {
  return {
    id: row.id,
    title: titleFor(row),
    preview: preview(row.contentText),
    kind: row.contentKind,
    sourceApp: row.sourceAppName,
    createdAt: grdbToIso(row.createdAt),
    categories: categoriesForClip(db, row.id),
  };
}

export const clipTools: ToolDef[] = [
  {
    name: "clippy_search_clips",
    description:
      "Find clips in the user's clipboard history by what they contain. This is " +
      "the entry point for almost every task: search first, then act on the ids " +
      "you get back with clippy_get_clip, clippy_update_clip, clippy_assign_clips, " +
      "or clippy_delete_clips. Terms are prefix-matched and ANDed, so 'data conn' " +
      "matches a clip containing 'database connection'. Results are 300-character " +
      "previews; use clippy_get_clip for a clip's full text. Filter by kind, " +
      "category, or source app to narrow a broad match. Use clippy_list_recent " +
      "instead when the user means 'what did I just copy'.",
    schema: z.object({
      query: z
        .string()
        .min(1)
        .describe("What to look for. Each word is prefix-matched; all must match."),
      kind: z
        .enum(["text", "image", "file"])
        .optional()
        .describe("Only clips of this kind."),
      categoryID: z
        .number()
        .int()
        .min(1)
        .optional()
        .describe("Only clips filed in this category. Ids come from clippy_list_categories."),
      sourceApp: z
        .string()
        .optional()
        .describe("Only clips copied from this app, matched exactly (e.g. 'Microsoft Word')."),
      limit: limitSchema.describe("Maximum results. Defaults to 25."),
    }),
    handler: ({ db, supportDir }, args) => {
      const { query, kind, categoryID, sourceApp, limit } = args as {
        query: string;
        kind?: string;
        categoryID?: number;
        sourceApp?: string;
        limit?: number;
      };
      const pattern = buildPrefixPattern(query);
      if (!pattern) return { results: [], note: "Query had no searchable terms." };

      const where: string[] = ["clips_fts MATCH ?"];
      const params: unknown[] = [pattern];
      if (kind) {
        where.push("clips.contentKind = ?");
        params.push(kind);
      }
      if (sourceApp) {
        where.push("clips.sourceAppName = ?");
        params.push(sourceApp);
      }
      if (categoryID !== undefined) {
        where.push("clips.id IN (SELECT clipID FROM clip_category WHERE categoryID = ?)");
        params.push(categoryID);
      }
      const rows = collectVisible(
        db,
        loadSensitiveFlags(supportDir),
        `SELECT clips.* FROM clips
           JOIN clips_fts ON clips_fts.rowid = clips.id
          WHERE ${where.join(" AND ")}
          ORDER BY rank`,
        params,
        limit ?? 25,
      );
      return { results: rows.map((row) => summarize(db, row)) };
    },
  },
  {
    name: "clippy_list_recent",
    description:
      "List the most recently copied clips, newest first. Use this for 'what did " +
      "I just copy', for showing the user their recent history, or as a starting " +
      "point when there is no search term to work from. Returns the same " +
      "300-character previews as clippy_search_clips.",
    schema: z.object({
      kind: z.enum(["text", "image", "file"]).optional().describe("Only clips of this kind."),
      limit: limitSchema.describe("Maximum results. Defaults to 25."),
    }),
    handler: ({ db, supportDir }, args) => {
      const { kind, limit } = args as { kind?: string; limit?: number };
      const rows = collectVisible(
        db,
        loadSensitiveFlags(supportDir),
        `SELECT * FROM clips
          ${kind ? "WHERE contentKind = ?" : ""}
          ORDER BY createdAt DESC, id DESC`,
        kind ? [kind] : [],
        limit ?? 25,
      );
      return { results: rows.map((row) => summarize(db, row)) };
    },
  },
  {
    name: "clippy_get_clip",
    description:
      "Read one clip in full: its complete text (not the truncated preview), " +
      "title, kind, source app, timestamps, categories, and for image or file " +
      "clips the absolute path of the stored copy on disk. Use it once you have " +
      "an id from clippy_search_clips or clippy_list_recent and need the actual " +
      "content, for example to rewrite it with clippy_update_clip.",
    schema: z.object({
      id: clipID.describe("Clip id, from a search or list result."),
    }),
    handler: ({ db, dbPath, supportDir }, args) => {
      const { id } = args as { id: number };
      const row = db.prepare(`SELECT * FROM clips WHERE id = ?`).get(id) as ClipRow | undefined;
      if (!row) return { error: "not_found", id };
      // Flagged clips (card numbers, SSNs, keys) are never handed to an MCP client.
      if (isSensitive(loadSensitiveFlags(supportDir), row)) {
        return {
          error: WITHHELD,
          id,
          hint: "This clip is flagged sensitive in Clippy and is not available over MCP.",
        };
      }
      const mediaDir = resolveMediaDir(dbPath);
      return {
        id: row.id,
        title: titleFor(row),
        contentText: row.contentText,
        typeIdentifier: row.typeIdentifier,
        kind: row.contentKind,
        sourceAppName: row.sourceAppName,
        sourceAppBundleID: row.sourceAppBundleID,
        userTitle: row.userTitle,
        createdAt: grdbToIso(row.createdAt),
        categories: categoriesForClip(db, row.id),
        media: row.mediaFilename
          ? {
              mediaPath: path.join(mediaDir, row.mediaFilename),
              thumbPath: row.thumbFilename ? path.join(mediaDir, row.thumbFilename) : null,
              pixelWidth: row.pixelWidth,
              pixelHeight: row.pixelHeight,
              byteSize: row.byteSize,
            }
          : null,
      };
    },
  },
  {
    name: "clippy_create_clip",
    description:
      "Save a new text clip into the user's history, as if they had copied it. " +
      "Use it to hand the user something to paste later: a generated snippet, a " +
      "reformatted version of an existing clip, a command they asked you to " +
      "prepare. Give it a title so the card is readable at a glance; without one " +
      "the card shows the source app instead. Returns the new id, which you can " +
      "pass straight to clippy_assign_clips to file it.",
    mutates: true,
    writesDatabase: true,
    schema: z.object({
      text: z.string().min(1).describe("The clip's content."),
      title: z
        .string()
        .optional()
        .describe("Short label shown on the clip card. Strongly recommended."),
      categoryID: z
        .number()
        .int()
        .min(1)
        .optional()
        .describe("File the new clip into this category immediately."),
    }),
    handler: ({ db }, args) => {
      const { text, title, categoryID } = args as {
        text: string;
        title?: string;
        categoryID?: number;
      };
      const now = grdbNow();
      const info = db
        .prepare(
          `INSERT INTO clips
             (contentText, typeIdentifier, sourceAppName, createdAt, contentKind, userTitle)
           VALUES (?, 'public.utf8-plain-text', 'clippy-mcp', ?, 'text', ?)`,
        )
        .run(text, now, title ?? null);
      const id = Number(info.lastInsertRowid);
      if (categoryID !== undefined) {
        db.prepare(
          `INSERT OR IGNORE INTO clip_category (clipID, categoryID, addedAt) VALUES (?, ?, ?)`,
        ).run(id, categoryID, now);
      }
      return { id, createdAt: grdbToIso(now), categories: categoriesForClip(db, id) };
    },
  },
  {
    name: "clippy_update_clip",
    description:
      "Edit a clip the user already has: rewrite its text, retitle it, or both. " +
      "Use it when they ask to fix, reformat, clean up, or rename something in " +
      "their history rather than add a new copy of it. Read the current value " +
      "with clippy_get_clip first when you are transforming existing content. " +
      "Only the fields you pass change; pass title as an empty string to clear it " +
      "and fall back to the source app name.",
    mutates: true,
    writesDatabase: true,
    schema: z.object({
      id: clipID.describe("Clip id to edit."),
      text: z.string().min(1).optional().describe("Replacement content."),
      title: z
        .string()
        .optional()
        .describe("Replacement title. Empty string clears it."),
    }),
    handler: ({ db, supportDir }, args) => {
      const { id, text, title } = args as { id: number; text?: string; title?: string };
      if (text === undefined && title === undefined) {
        return { error: "nothing_to_update", id, hint: "Pass text, title, or both." };
      }
      const existing = db.prepare(`SELECT * FROM clips WHERE id = ?`).get(id) as ClipRow | undefined;
      if (!existing) return { error: "not_found", id };
      // Editing would echo the clip back as a preview, so flagged clips are off limits.
      if (isSensitive(loadSensitiveFlags(supportDir), existing)) {
        return { error: WITHHELD, id };
      }

      const sets: string[] = [];
      const params: unknown[] = [];
      if (text !== undefined) {
        sets.push("contentText = ?");
        params.push(text);
      }
      if (title !== undefined) {
        sets.push("userTitle = ?");
        params.push(title === "" ? null : title);
      }
      params.push(id);
      // SAFETY (SQL): `sets` only ever receives the two fixed literals "contentText = ?" and
      // "userTitle = ?" pushed above; every caller-supplied value travels in `params` as a bound
      // parameter, so nothing user-controlled is interpolated into the statement text.
      db.prepare(`UPDATE clips SET ${sets.join(", ")} WHERE id = ?`).run(...(params as any[]));

      // SAFETY: primary-key lookup of the row just updated; it exists (checked above), and its
      // columns are those of `clips`, i.e. ClipRow.
      const row = db.prepare(`SELECT * FROM clips WHERE id = ?`).get(id) as unknown as ClipRow;
      return { updated: true, ...summarize(db, row) };
    },
  },
  {
    name: "clippy_delete_clips",
    description:
      "Permanently delete clips by id, one or many in a single call. Use it to " +
      "clear out junk the user points at - duplicates, test noise, anything they " +
      "ask you to remove. This cannot be undone, so confirm with the user before " +
      "deleting anything they did not name explicitly. Category memberships and " +
      "the search index are cleaned up automatically; stored image and file " +
      "payloads are swept by the app later.",
    mutates: true,
    writesDatabase: true,
    schema: z.object({
      ids: z
        .array(clipID)
        .min(1)
        .max(500)
        .describe("Clip ids to delete. Batch them rather than calling once per clip."),
    }),
    handler: ({ db }, args) => {
      const { ids } = args as { ids: number[] };
      const statement = db.prepare(`DELETE FROM clips WHERE id = ?`);
      const deleted: number[] = [];
      const missing: number[] = [];
      for (const id of ids) {
        if (statement.run(id).changes > 0) deleted.push(id);
        else missing.push(id);
      }
      return { deleted, missing, deletedCount: deleted.length };
    },
  },
];
