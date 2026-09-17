import { z } from "zod";
import { clipID, categoryID, limitSchema, type ToolDef } from "../types.js";
import { clipTools } from "./clips.js";
import { categoryTools } from "./categories.js";
import { scriptTools } from "./scripts.js";
import { aiActionTools } from "./ai-actions.js";

/**
 * Tools removed in the 2026-09 rename, kept as thin shims on their original
 * schemas so anything already wired to the old names keeps working: a user's
 * saved MCP config, a slash command, a habit. Each one forwards to the tool that
 * replaced it and says so, so a model reading the list picks the new name.
 *
 * Remove these once the plugin surface and any pinned client configs have moved.
 */
function deprecatedAliases(byName: Map<string, ToolDef>): ToolDef[] {
  const call = (name: string) => byName.get(name)!;

  return [
    {
      name: "clippy_search",
      description: "DEPRECATED - use clippy_search_clips, which adds kind, category, and source-app filters.",
      schema: z.object({
        query: z.string().min(1).describe("Search text."),
        limit: limitSchema.describe("Maximum results."),
      }),
      handler: (context, args) => call("clippy_search_clips").handler(context, args),
    },
    {
      name: "clippy_get",
      description: "DEPRECATED - use clippy_get_clip.",
      schema: z.object({ id: clipID.describe("Clip id.") }),
      handler: (context, args) => call("clippy_get_clip").handler(context, args),
    },
    {
      name: "clippy_add",
      description: "DEPRECATED - use clippy_create_clip, which can also file the new clip.",
      schema: z.object({
        text: z.string().min(1).describe("The clip's text content."),
        title: z.string().optional().describe("Optional display title."),
      }),
      handler: (context, args) => call("clippy_create_clip").handler(context, args),
      mutates: true,
    },
    {
      name: "clippy_delete",
      description: "DEPRECATED - use clippy_delete_clips, which deletes many ids in one call.",
      schema: z.object({ id: clipID.describe("Clip id to delete.") }),
      handler: (context, args) => {
        const { id } = args as { id: number };
        return call("clippy_delete_clips").handler(context, { ids: [id] });
      },
      mutates: true,
    },
    {
      name: "clippy_set_category",
      description:
        "DEPRECATED - use clippy_assign_clips, which files many clips in one call.",
      schema: z.object({
        clipID: clipID.describe("Clip id."),
        categoryID: categoryID.describe("Category id."),
        member: z.boolean().describe("true to add to the category, false to remove."),
      }),
      handler: (context, args) => {
        const { clipID: one, categoryID: target, member } = args as {
          clipID: number;
          categoryID: number;
          member: boolean;
        };
        return call("clippy_assign_clips").handler(context, {
          clipIDs: [one],
          categoryID: target,
          member,
        });
      },
      mutates: true,
    },
  ];
}

const current: ToolDef[] = [...clipTools, ...categoryTools, ...scriptTools, ...aiActionTools];
const currentByName = new Map(current.map((tool) => [tool.name, tool]));

export const tools: ToolDef[] = [...current, ...deprecatedAliases(currentByName)];
export const toolByName = new Map(tools.map((tool) => [tool.name, tool]));
