import { z } from "zod";
import { grdbNow, grdbToIso } from "../db.js";
import { categoryID, clipID, type CategoryRow, type ToolDef } from "../types.js";

const DEFAULT_COLOR = "#FF9500";
const DEFAULT_SYMBOL = "tag.fill";

const hexColor = z
  .string()
  .regex(/^#?[0-9A-Fa-f]{6}$/, "Six hex digits, with or without a leading #");

function normalizeColor(value: string): string {
  return value.startsWith("#") ? value.toUpperCase() : `#${value.toUpperCase()}`;
}

function shape(row: CategoryRow, clipCount: number) {
  return {
    id: row.id,
    name: row.name,
    colorHex: row.colorHex,
    icon: { kind: row.iconKind, value: row.iconValue },
    position: row.sortOrder,
    isStarter: row.isStarter === 1,
    clipCount,
    createdAt: grdbToIso(row.createdAt),
  };
}

export const categoryTools: ToolDef[] = [
  {
    name: "clippy_list_categories",
    description:
      "List the user's categories - the named, colored boards they file clips " +
      "into - with how many clips each holds. Call this before filing anything so " +
      "you reuse an existing category instead of creating a near-duplicate, and " +
      "to get the ids that clippy_assign_clips and the category filter on " +
      "clippy_search_clips need.",
    schema: z.object({}),
    handler: ({ db }) => {
      const rows = db
        .prepare(`SELECT * FROM category ORDER BY sortOrder, createdAt`)
        .all() as unknown as CategoryRow[];
      const counts = new Map<number, number>();
      for (const row of db
        .prepare(`SELECT categoryID, COUNT(*) AS n FROM clip_category GROUP BY categoryID`)
        .all() as { categoryID: number; n: number }[]) {
        counts.set(row.categoryID, row.n);
      }
      return { categories: rows.map((row) => shape(row, counts.get(row.id) ?? 0)) };
    },
  },
  {
    name: "clippy_create_category",
    description:
      "Create a new category to file clips into. Check clippy_list_categories " +
      "first - the user almost always wants an existing board rather than a new " +
      "one with a similar name. Give it a real SF Symbol name (for example " +
      "'terminal.fill', 'key.fill', 'doc.text') so it is recognizable in the " +
      "sidebar. Returns the new id, ready for clippy_assign_clips.",
    mutates: true,
    schema: z.object({
      name: z.string().min(1).describe("What the user calls this group of clips."),
      colorHex: hexColor.optional().describe(`Accent color. Defaults to ${DEFAULT_COLOR}.`),
      iconKind: z
        .enum(["symbol", "emoji", "appLogo"])
        .optional()
        .describe("symbol = SF Symbol (default), emoji = a character, appLogo = an app bundle id."),
      iconValue: z
        .string()
        .optional()
        .describe(`SF Symbol name, emoji, or bundle id. Defaults to ${DEFAULT_SYMBOL}.`),
    }),
    handler: ({ db }, args) => {
      const { name, colorHex, iconKind, iconValue } = args as {
        name: string;
        colorHex?: string;
        iconKind?: string;
        iconValue?: string;
      };
      const order =
        (db.prepare(`SELECT IFNULL(MAX(sortOrder), -1) AS m FROM category`).get() as { m: number })
          .m + 1;
      const info = db
        .prepare(
          `INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
           VALUES (?, ?, ?, ?, ?, 0, ?)`,
        )
        .run(
          name,
          colorHex ? normalizeColor(colorHex) : DEFAULT_COLOR,
          iconKind ?? "symbol",
          iconValue ?? DEFAULT_SYMBOL,
          order,
          grdbNow(),
        );
      const row = db
        .prepare(`SELECT * FROM category WHERE id = ?`)
        .get(Number(info.lastInsertRowid)) as unknown as CategoryRow;
      return shape(row, 0);
    },
  },
  {
    name: "clippy_update_category",
    description:
      "Rename a category, change its color or icon, or move it up or down the " +
      "sidebar. Use it when the user wants an existing board adjusted rather than " +
      "replaced - renaming keeps every clip filed in it. Only the fields you pass " +
      "change.",
    mutates: true,
    schema: z.object({
      id: categoryID.describe("Category id, from clippy_list_categories."),
      name: z.string().min(1).optional().describe("New name."),
      colorHex: hexColor.optional().describe("New accent color."),
      iconKind: z.enum(["symbol", "emoji", "appLogo"]).optional().describe("New icon kind."),
      iconValue: z.string().optional().describe("New SF Symbol name, emoji, or bundle id."),
      position: z
        .number()
        .int()
        .min(0)
        .optional()
        .describe("Sort position; lower sits higher in the sidebar."),
    }),
    handler: ({ db }, args) => {
      const { id, name, colorHex, iconKind, iconValue, position } = args as {
        id: number;
        name?: string;
        colorHex?: string;
        iconKind?: string;
        iconValue?: string;
        position?: number;
      };
      const existing = db.prepare(`SELECT * FROM category WHERE id = ?`).get(id) as
        | CategoryRow
        | undefined;
      if (!existing) return { error: "not_found", id };

      const sets: string[] = [];
      const params: unknown[] = [];
      const push = (column: string, value: unknown) => {
        sets.push(`${column} = ?`);
        params.push(value);
      };
      if (name !== undefined) push("name", name);
      if (colorHex !== undefined) push("colorHex", normalizeColor(colorHex));
      if (iconKind !== undefined) push("iconKind", iconKind);
      if (iconValue !== undefined) push("iconValue", iconValue);
      if (position !== undefined) push("sortOrder", position);
      if (sets.length === 0) {
        return { error: "nothing_to_update", id, hint: "Pass at least one field to change." };
      }
      params.push(id);
      db.prepare(`UPDATE category SET ${sets.join(", ")} WHERE id = ?`).run(...(params as any[]));

      const row = db.prepare(`SELECT * FROM category WHERE id = ?`).get(id) as unknown as CategoryRow;
      const count = (
        db.prepare(`SELECT COUNT(*) AS n FROM clip_category WHERE categoryID = ?`).get(id) as {
          n: number;
        }
      ).n;
      return { updated: true, ...shape(row, count) };
    },
  },
  {
    name: "clippy_delete_category",
    description:
      "Delete a category. The clips filed in it are NOT deleted - they stay in " +
      "the history and simply lose this label, so this is the safe way to tidy up " +
      "an unused board. Clippy's built-in starter category cannot be deleted. " +
      "To remove the clips as well, call clippy_delete_clips separately.",
    mutates: true,
    schema: z.object({
      id: categoryID.describe("Category id to delete."),
    }),
    handler: ({ db }, args) => {
      const { id } = args as { id: number };
      const existing = db.prepare(`SELECT * FROM category WHERE id = ?`).get(id) as
        | CategoryRow
        | undefined;
      if (!existing) return { error: "not_found", id };
      if (existing.isStarter === 1) {
        return {
          error: "starter_category_protected",
          id,
          hint: "Clippy's built-in starter category cannot be removed.",
        };
      }
      const releasedCount = (
        db.prepare(`SELECT COUNT(*) AS n FROM clip_category WHERE categoryID = ?`).get(id) as {
          n: number;
        }
      ).n;
      db.prepare(`DELETE FROM clip_category WHERE categoryID = ?`).run(id);
      db.prepare(`DELETE FROM category WHERE id = ?`).run(id);
      return { deleted: true, id, name: existing.name, clipsReleased: releasedCount };
    },
  },
  {
    name: "clippy_assign_clips",
    description:
      "File clips into a category, or take them out of one - many clips per call. " +
      "This is the tool for organizing: search or list to get ids, then assign " +
      "them all in a single call rather than one at a time. A clip can sit in " +
      "several categories at once, and adding a clip that is already there is " +
      "harmless. Set member to false to unfile without deleting anything.",
    mutates: true,
    schema: z.object({
      clipIDs: z
        .array(clipID)
        .min(1)
        .max(500)
        .describe("Clip ids to file or unfile. Batch them."),
      categoryID: categoryID.describe("Target category, from clippy_list_categories."),
      member: z
        .boolean()
        .default(true)
        .describe("true files the clips into the category, false removes them from it."),
    }),
    handler: ({ db }, args) => {
      const { clipIDs, categoryID: target, member } = args as {
        clipIDs: number[];
        categoryID: number;
        member: boolean;
      };
      const category = db.prepare(`SELECT * FROM category WHERE id = ?`).get(target) as
        | CategoryRow
        | undefined;
      if (!category) return { error: "category_not_found", categoryID: target };

      const known = new Set(
        (
          db
            .prepare(
              `SELECT id FROM clips WHERE id IN (${clipIDs.map(() => "?").join(",")})`,
            )
            .all(...(clipIDs as any[])) as { id: number }[]
        ).map((row) => row.id),
      );
      const missing = clipIDs.filter((id) => !known.has(id));

      const now = grdbNow();
      const insert = db.prepare(
        `INSERT OR IGNORE INTO clip_category (clipID, categoryID, addedAt) VALUES (?, ?, ?)`,
      );
      const remove = db.prepare(`DELETE FROM clip_category WHERE clipID = ? AND categoryID = ?`);
      for (const id of known) {
        if (member) insert.run(id, target, now);
        else remove.run(id, target);
      }
      return {
        categoryID: target,
        categoryName: category.name,
        member,
        applied: [...known],
        missing,
        appliedCount: known.size,
      };
    },
  },
  {
    name: "clippy_stats",
    description:
      "Get the shape of the user's clipboard history before doing anything else: " +
      "how many clips there are, how they break down by kind, how many are filed " +
      "versus loose, which categories exist, and which apps they copy from most. " +
      "Start here when the user asks something open-ended like 'help me clean this " +
      "up' or 'what's in my clipboard history', so your plan fits the real data.",
    schema: z.object({}),
    handler: ({ db, dbPath }) => {
      const scalar = (sql: string) => (db.prepare(sql).get() as { n: number }).n;
      const total = scalar(`SELECT COUNT(*) AS n FROM clips`);
      const filed = scalar(`SELECT COUNT(DISTINCT clipID) AS n FROM clip_category`);
      return {
        databasePath: dbPath,
        clips: {
          total,
          filed,
          unfiled: total - filed,
          titled: scalar(`SELECT COUNT(*) AS n FROM clips WHERE userTitle IS NOT NULL`),
          byKind: db
            .prepare(
              `SELECT contentKind AS kind, COUNT(*) AS count FROM clips GROUP BY contentKind ORDER BY count DESC`,
            )
            .all(),
          oldest: grdbToIso(
            (db.prepare(`SELECT MIN(createdAt) AS t FROM clips`).get() as { t: string | null }).t,
          ),
          newest: grdbToIso(
            (db.prepare(`SELECT MAX(createdAt) AS t FROM clips`).get() as { t: string | null }).t,
          ),
        },
        categories: db
          .prepare(
            `SELECT c.id, c.name, COUNT(cc.clipID) AS clipCount
               FROM category c
               LEFT JOIN clip_category cc ON cc.categoryID = c.id
              GROUP BY c.id
              ORDER BY c.sortOrder`,
          )
          .all(),
        topSourceApps: db
          .prepare(
            `SELECT sourceAppName AS app, COUNT(*) AS count
               FROM clips WHERE sourceAppName IS NOT NULL
              GROUP BY sourceAppName ORDER BY count DESC LIMIT 10`,
          )
          .all(),
      };
    },
  },
];
