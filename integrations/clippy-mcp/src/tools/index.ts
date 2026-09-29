import type { ToolDef } from "../types.js";
import { clipTools } from "./clips.js";
import { categoryTools } from "./categories.js";
import { scriptTools } from "./scripts.js";
import { aiActionTools } from "./ai-actions.js";

export const tools: ToolDef[] = [...clipTools, ...categoryTools, ...scriptTools, ...aiActionTools];
export const toolByName = new Map(tools.map((tool) => [tool.name, tool]));
