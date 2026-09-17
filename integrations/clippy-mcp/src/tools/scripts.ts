import { z } from "zod";
import {
  SCRIPT_INTERPRETERS,
  newID,
  scriptStore,
  swiftISODate,
  type Script,
} from "../stores.js";
import { uuidSchema, type ToolDef } from "../types.js";

/**
 * Clippy runs these scripts as the signed-in user. A tool that writes
 * `scripts.json` is therefore a path from "anything connected over MCP" to
 * "arbitrary shell on this Mac", so everything created or edited here lands
 * `isEnabled: false` and the app's ScriptRunner refuses to execute it until a
 * human reviews the body and flips the switch in Settings > Scripts.
 *
 * That rule is not negotiable from the client side: there is deliberately no
 * parameter to enable a script, and an edit re-disables one that was enabled.
 */
const DISABLED_NOTICE =
  "Created disabled. Clippy will not run it until the user reviews the body and " +
  "enables it in Settings > Scripts. Tell them that, and point them at the script " +
  "by name.";

function summarize(script: Script) {
  return {
    id: script.id,
    name: script.name,
    interpreter: script.interpreter,
    isEnabled: script.isEnabled !== false,
    feedsClipboard: script.feedsClipboard,
    outputToClipboard: script.outputToClipboard,
    bodyLines: script.body.split("\n").length,
    updatedAt: script.updatedAt,
  };
}

export const scriptTools: ToolDef[] = [
  {
    name: "clippy_list_scripts",
    description:
      "List the user's saved Clippy scripts - the small shell/python/node " +
      "snippets they run from the panel, optionally piping the current clip " +
      "through. Returns names, interpreters, and whether each is enabled, but not " +
      "the bodies; use clippy_get_script for one script's code. Check here before " +
      "creating a script so you extend what exists instead of duplicating it.",
    schema: z.object({}),
    handler: ({ supportDir }) => {
      const scripts = scriptStore(supportDir).all();
      return {
        scripts: scripts.map(summarize),
        disabledCount: scripts.filter((s) => s.isEnabled === false).length,
      };
    },
  },
  {
    name: "clippy_get_script",
    description:
      "Read one script in full, including its body. Use it before " +
      "clippy_update_script so you edit the real code rather than guessing at it, " +
      "or when the user asks what a script actually does.",
    schema: z.object({
      id: uuidSchema.describe("Script id, from clippy_list_scripts."),
    }),
    handler: ({ supportDir }, args) => {
      const { id } = args as { id: string };
      const script = scriptStore(supportDir).find(id);
      if (!script) return { error: "not_found", id };
      return { ...summarize(script), body: script.body, createdAt: script.createdAt };
    },
  },
  {
    name: "clippy_create_script",
    description:
      "Add a new script to Clippy. Use it when the user asks for a snippet they " +
      "can run on their clipboard - reformat JSON, strip tracking parameters off a " +
      "URL, convert a timestamp. Set feedsClipboard when the script should receive " +
      "the current clip on stdin (also in $CLIPPY_CLIP), and outputToClipboard " +
      "when its stdout should be offered back as a new clip. " +
      "IMPORTANT: the script is saved DISABLED and Clippy will not run it until " +
      "the user enables it in Settings > Scripts - always say so when you report " +
      "back. There is no way to enable it from here, by design.",
    mutates: true,
    schema: z.object({
      name: z.string().min(1).describe("Short name shown in the scripts panel."),
      body: z.string().min(1).describe("The script source, as the interpreter will run it."),
      interpreter: z
        .enum(SCRIPT_INTERPRETERS)
        .default("zsh")
        .describe("Which interpreter runs the body."),
      feedsClipboard: z
        .boolean()
        .default(false)
        .describe("Pass the current clip to the script on stdin and in $CLIPPY_CLIP."),
      outputToClipboard: z
        .boolean()
        .default(false)
        .describe("Offer the script's stdout as a new clip when it finishes."),
    }),
    handler: ({ supportDir }, args) => {
      const { name, body, interpreter, feedsClipboard, outputToClipboard } = args as {
        name: string;
        body: string;
        interpreter: string;
        feedsClipboard: boolean;
        outputToClipboard: boolean;
      };
      const store = scriptStore(supportDir);
      const now = swiftISODate();
      const script: Script = {
        id: newID(),
        name,
        interpreter,
        body,
        feedsClipboard,
        outputToClipboard,
        createdAt: now,
        updatedAt: now,
        sortOrder: store.nextSortOrder(),
        isEnabled: false,
      };
      store.add(script);
      return { ...summarize(script), notice: DISABLED_NOTICE };
    },
  },
  {
    name: "clippy_update_script",
    description:
      "Change an existing script: fix a bug in its body, rename it, switch " +
      "interpreter, or change how it handles the clipboard. Read it with " +
      "clippy_get_script first so you are editing the current code. Only the " +
      "fields you pass change. " +
      "IMPORTANT: any edit re-disables the script, so the user has to re-approve " +
      "the new body in Settings > Scripts before it will run. Say so when you " +
      "report back.",
    mutates: true,
    schema: z.object({
      id: uuidSchema.describe("Script id to edit."),
      name: z.string().min(1).optional().describe("New name."),
      body: z.string().min(1).optional().describe("Replacement source."),
      interpreter: z.enum(SCRIPT_INTERPRETERS).optional().describe("New interpreter."),
      feedsClipboard: z.boolean().optional().describe("Whether it receives the current clip."),
      outputToClipboard: z.boolean().optional().describe("Whether its stdout becomes a clip."),
    }),
    handler: ({ supportDir }, args) => {
      const { id, ...changes } = args as { id: string } & Partial<Script>;
      const store = scriptStore(supportDir);
      if (!store.find(id)) return { error: "not_found", id };
      const defined = Object.fromEntries(
        Object.entries(changes).filter(([, value]) => value !== undefined),
      );
      if (Object.keys(defined).length === 0) {
        return { error: "nothing_to_update", id, hint: "Pass at least one field to change." };
      }
      const updated = store.update(id, {
        ...defined,
        updatedAt: swiftISODate(),
        // Re-disable on every edit: approval was granted for the old body.
        isEnabled: false,
      } as Partial<Script>);
      return { updated: true, ...summarize(updated!), notice: DISABLED_NOTICE };
    },
  },
  {
    name: "clippy_delete_script",
    description:
      "Remove a script from Clippy permanently. Confirm with the user first " +
      "unless they named the script themselves - there is no undo.",
    mutates: true,
    schema: z.object({
      id: uuidSchema.describe("Script id to delete."),
    }),
    handler: ({ supportDir }, args) => {
      const { id } = args as { id: string };
      const store = scriptStore(supportDir);
      const script = store.find(id);
      if (!script) return { error: "not_found", id };
      store.remove(id);
      return { deleted: true, id, name: script.name };
    },
  },
];
