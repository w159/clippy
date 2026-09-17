import { z } from "zod";
import {
  OUTPUT_DISPOSITIONS,
  aiActionStore,
  newID,
  type AIAction,
} from "../stores.js";
import { uuidSchema, type ToolDef } from "../types.js";

/**
 * AI actions are the one-click prompts on a clip's context menu ("Summarize",
 * "Extract from HTML"). The prompt body must contain the `{clip}` placeholder,
 * which the app substitutes with the clip's text before sending it to the
 * configured provider; without it the action silently ignores the clip.
 */
const CLIP_PLACEHOLDER = "{clip}";

function summarize(action: AIAction) {
  return {
    id: action.id,
    name: action.name,
    outputDisposition: action.outputDisposition,
    temperature: action.temperature,
    maxTokens: action.maxTokens,
    icon: action.symbolName,
    isBuiltIn: action.isBuiltIn,
  };
}

const dispositionDescription =
  "What happens to the model's answer: proposeEdit shows a diff the user accepts " +
  "or rejects (safest, and the right default for rewrites), copyToClipboard " +
  "replaces the clipboard contents, newClip saves the answer as a separate clip " +
  "and leaves the original alone.";

export const aiActionTools: ToolDef[] = [
  {
    name: "clippy_list_ai_actions",
    description:
      "List the user's AI actions - the one-click prompts that appear on a clip's " +
      "menu, like 'Summarize' or 'Fix grammar'. Returns each action's name, what " +
      "it does with the result, and its model settings, but not the prompt text. " +
      "Check here before creating one so you extend an existing action instead of " +
      "adding a near-duplicate.",
    schema: z.object({}),
    handler: ({ supportDir }) => ({
      actions: aiActionStore(supportDir).all().map(summarize),
    }),
  },
  {
    name: "clippy_get_ai_action",
    description:
      "Read one AI action in full, including its prompt template. Use it before " +
      "clippy_update_ai_action so you are editing the real prompt, or when the " +
      "user asks why an action behaves the way it does.",
    schema: z.object({
      id: uuidSchema.describe("Action id, from clippy_list_ai_actions."),
    }),
    handler: ({ supportDir }, args) => {
      const { id } = args as { id: string };
      const action = aiActionStore(supportDir).find(id);
      if (!action) return { error: "not_found", id };
      return { ...summarize(action), promptTemplate: action.promptTemplate };
    },
  },
  {
    name: "clippy_create_ai_action",
    description:
      "Add a new one-click AI action to the clip menu. Use it when the user " +
      "describes something they keep asking for by hand - 'turn this into a " +
      "bulleted list', 'rewrite this for a client email'. The prompt template " +
      `must contain ${CLIP_PLACEHOLDER}, which is replaced with the clip's text. ` +
      "Unlike scripts, AI actions run a prompt rather than code, so they are " +
      "active as soon as they are created.",
    mutates: true,
    schema: z.object({
      name: z.string().min(1).describe("Short label shown on the clip menu."),
      promptTemplate: z
        .string()
        .min(1)
        .describe(`The prompt. Must include ${CLIP_PLACEHOLDER} where the clip's text belongs.`),
      outputDisposition: z
        .enum(OUTPUT_DISPOSITIONS)
        .default("proposeEdit")
        .describe(dispositionDescription),
      temperature: z
        .number()
        .min(0)
        .max(2)
        .default(0.3)
        .describe("Model temperature. Low for extraction and formatting, higher for drafting."),
      maxTokens: z
        .number()
        .int()
        .min(16)
        .max(8192)
        .default(512)
        .describe("Response ceiling."),
      symbolName: z
        .string()
        .default("wand.and.sparkles")
        .describe("SF Symbol name for the menu icon, e.g. 'text.badge.checkmark'."),
    }),
    handler: ({ supportDir }, args) => {
      const { name, promptTemplate, outputDisposition, temperature, maxTokens, symbolName } =
        args as {
          name: string;
          promptTemplate: string;
          outputDisposition: string;
          temperature: number;
          maxTokens: number;
          symbolName: string;
        };
      if (!promptTemplate.includes(CLIP_PLACEHOLDER)) {
        return {
          error: "missing_clip_placeholder",
          hint: `The prompt must contain ${CLIP_PLACEHOLDER}; without it the action never sees the clip.`,
        };
      }
      const store = aiActionStore(supportDir);
      const action: AIAction = {
        id: newID(),
        name,
        promptTemplate,
        outputDisposition,
        temperature,
        maxTokens,
        symbolName,
        iconKind: "symbol",
        isBuiltIn: false,
        sortOrder: store.nextSortOrder(),
      };
      store.add(action);
      return summarize(action);
    },
  },
  {
    name: "clippy_update_ai_action",
    description:
      "Change an existing AI action: tune its prompt, rename it, change what " +
      "happens to the result, or adjust temperature and length. Read it with " +
      "clippy_get_ai_action first. Only the fields you pass change. Built-in " +
      "actions can be edited; they simply cannot be deleted.",
    mutates: true,
    schema: z.object({
      id: uuidSchema.describe("Action id to edit."),
      name: z.string().min(1).optional().describe("New label."),
      promptTemplate: z
        .string()
        .min(1)
        .optional()
        .describe(`Replacement prompt. Must still contain ${CLIP_PLACEHOLDER}.`),
      outputDisposition: z.enum(OUTPUT_DISPOSITIONS).optional().describe(dispositionDescription),
      temperature: z.number().min(0).max(2).optional().describe("New temperature."),
      maxTokens: z.number().int().min(16).max(8192).optional().describe("New response ceiling."),
      symbolName: z.string().optional().describe("New SF Symbol name."),
    }),
    handler: ({ supportDir }, args) => {
      const { id, ...changes } = args as { id: string } & Partial<AIAction>;
      const store = aiActionStore(supportDir);
      if (!store.find(id)) return { error: "not_found", id };
      if (
        changes.promptTemplate !== undefined &&
        !changes.promptTemplate.includes(CLIP_PLACEHOLDER)
      ) {
        return {
          error: "missing_clip_placeholder",
          hint: `The prompt must contain ${CLIP_PLACEHOLDER}; without it the action never sees the clip.`,
        };
      }
      const defined = Object.fromEntries(
        Object.entries(changes).filter(([, value]) => value !== undefined),
      );
      if (Object.keys(defined).length === 0) {
        return { error: "nothing_to_update", id, hint: "Pass at least one field to change." };
      }
      const updated = store.update(id, defined as Partial<AIAction>);
      return { updated: true, ...summarize(updated!) };
    },
  },
  {
    name: "clippy_delete_ai_action",
    description:
      "Remove a user-created AI action from the clip menu. Clippy's built-in " +
      "actions are protected and cannot be deleted - edit those instead.",
    mutates: true,
    schema: z.object({
      id: uuidSchema.describe("Action id to delete."),
    }),
    handler: ({ supportDir }, args) => {
      const { id } = args as { id: string };
      const store = aiActionStore(supportDir);
      const action = store.find(id);
      if (!action) return { error: "not_found", id };
      if (action.isBuiltIn) {
        return {
          error: "builtin_action_protected",
          id,
          name: action.name,
          hint: "Built-in actions cannot be deleted. Use clippy_update_ai_action to change it.",
        };
      }
      store.remove(id);
      return { deleted: true, id, name: action.name };
    },
  },
];
