#!/usr/bin/env node
import http from "node:http";
import { randomUUID } from "node:crypto";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import type { IncomingMessage, ServerResponse } from "node:http";
import { zodToJsonSchema } from "zod-to-json-schema";
import type { DatabaseSync } from "node:sqlite";
import { openDatabase, resolveDatabasePath, resolveSupportDir } from "./db.js";
import { tools, toolByName } from "./tools/index.js";
import type { ToolContext } from "./types.js";

// ---------------------------------------------------------------------------
// Bootstrap: open the DB once, fail loud if it is missing.
// ---------------------------------------------------------------------------

const dbPath = resolveDatabasePath();
let db: DatabaseSync;
try {
  db = openDatabase(dbPath);
} catch (err) {
  console.error(
    `clippy-mcp: could not open database at ${dbPath}. ` +
      `Set CLIPPY_DB_PATH or launch Clippy once to create it. ` +
      `(${err instanceof Error ? err.message : String(err)})`,
  );
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Shared tool registration: attaches ListTools + CallTool to any Server instance.
// Called once in stdio mode and once per session in HTTP mode.
// ---------------------------------------------------------------------------

const context: ToolContext = { db, dbPath, supportDir: resolveSupportDir(dbPath) };

/**
 * One line per call on stderr, which Clippy captures and shows in its MCP
 * diagnostics. A clipboard history at a regulated firm is client data, so "what
 * did the assistant read and change" has to be answerable after the fact.
 * Arguments are summarized, never dumped: the point is the audit trail, not a
 * second copy of the content in a log file.
 */
function audit(name: string, args: unknown, outcome: "ok" | "error"): void {
  const shape =
    args && typeof args === "object" ? Object.keys(args as object).sort().join(",") : "";
  console.error(
    `${new Date().toISOString()} clippy-mcp ${outcome} ${name}${shape ? ` args=[${shape}]` : ""}`,
  );
}

function registerTools(server: Server): void {
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: tools.map((t) => ({
      name: t.name,
      description: t.description,
      // jsonSchema7, not openApi3: OpenAPI 3.0 emits the draft-04 boolean form
      // `exclusiveMinimum: true`, which MCP clients reject outright (the tool is
      // dropped from the client's tool list with no error). Draft-07 emits the
      // numeric form every client accepts.
      inputSchema: zodToJsonSchema(t.schema, { target: "jsonSchema7" }) as any,
      annotations: {
        readOnlyHint: t.mutates !== true,
        destructiveHint: t.mutates === true,
        idempotentHint: t.mutates !== true,
      },
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const tool = toolByName.get(request.params.name);
    if (!tool) {
      audit(request.params.name, request.params.arguments, "error");
      return {
        isError: true,
        content: [{ type: "text", text: `Unknown tool: ${request.params.name}` }],
      };
    }
    try {
      const args = tool.schema.parse(request.params.arguments ?? {});
      const result = tool.handler(context, args);
      audit(tool.name, args, "ok");
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      };
    } catch (err) {
      audit(tool.name, request.params.arguments, "error");
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: `Error in ${tool.name}: ${
              err instanceof Error ? err.message : String(err)
            }`,
          },
        ],
      };
    }
  });
}

// ---------------------------------------------------------------------------
// Mode selection: HTTP when CLIPPY_MCP_PORT is set to a valid port number;
// stdio otherwise (unchanged default).
// ---------------------------------------------------------------------------

const portEnv = process.env.CLIPPY_MCP_PORT;
const parsedPort = portEnv !== undefined ? parseInt(portEnv, 10) : NaN;
const useHttp =
  portEnv !== undefined &&
  portEnv.trim().length > 0 &&
  Number.isInteger(parsedPort) &&
  parsedPort > 0 &&
  parsedPort <= 65535;

if (useHttp) {
  // -------------------------------------------------------------------------
  // HTTP mode: one StreamableHTTPServerTransport per session, stored by
  // the mcp-session-id header value that the SDK assigns on initialize.
  // -------------------------------------------------------------------------

  const sessions = new Map<string, StreamableHTTPServerTransport>();

  // ---------------------------------------------------------------------------
  // Idle-session reaper: clients that crash or drop mid-request never fire
  // onclose, so the session entry would otherwise leak forever.  We track last
  // activity per session and sweep every minute, closing anything idle beyond
  // SESSION_TTL_MS.  10 minutes is chosen because it is long enough to cover
  // any legitimate inter-request pause (e.g. a user thinking, a slow network
  // reconnect) while still bounding worst-case map growth to ~10 entries per
  // minute of sustained connection churn.
  // ---------------------------------------------------------------------------

  const SESSION_TTL_MS = 10 * 60 * 1000; // 10 minutes
  const sessionActivity = new Map<string, number>(); // sessionId -> Date.now()

  // Sessions whose SSE GET stream is currently open.  The reaper must never
  // touch these regardless of lastSeen: the client is alive; it just has not
  // sent a POST for a while.  The set is populated just before handleRequest
  // for a GET and cleared by the "close" event on the ServerResponse, which
  // Node.js fires whenever the underlying socket is destroyed (client drop,
  // graceful disconnect, or server-initiated close).
  const openSseStreams = new Set<string>();

  function touchSession(sessionId: string): void {
    sessionActivity.set(sessionId, Date.now());
  }

  async function reapIdleSessions(): Promise<void> {
    const cutoff = Date.now() - SESSION_TTL_MS;
    for (const [id, lastSeen] of sessionActivity) {
      // Never reap a session whose SSE stream is currently open: the client
      // is connected and waiting for server notifications.  TTL only applies
      // once the stream has closed and the session is truly idle.
      if (openSseStreams.has(id)) {
        continue;
      }
      if (lastSeen < cutoff) {
        const transport = sessions.get(id);
        sessions.delete(id);
        sessionActivity.delete(id);
        if (transport !== undefined) {
          // close() ends all active SSE streams and frees internal state.
          transport.close().catch((err: unknown) => {
            console.error(
              `clippy-mcp: error closing idle session ${id}: ${
                err instanceof Error ? err.message : String(err)
              }`,
            );
          });
        }
      }
    }
  }

  // unref() so the timer does not keep the process alive when nothing else is
  // running (e.g. during a graceful shutdown where the HTTP server has closed).
  const reaperTimer = setInterval(() => {
    reapIdleSessions();
  }, 60_000).unref();

  // Clear the timer when the HTTP server closes so there are no dangling
  // handles on explicit shutdown.
  // (Node fires the "close" event after all connections drain.)

  /** Create a fresh Server + transport pair for a new MCP session. */
  function createSession(): StreamableHTTPServerTransport {
    const server = new Server(
      { name: "clippy-mcp", version: "0.1.0" },
      { capabilities: { tools: {} } },
    );
    registerTools(server);

    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
      onsessioninitialized: (sessionId) => {
        sessions.set(sessionId, transport);
        touchSession(sessionId); // start the idle clock
      },
      onsessionclosed: (sessionId) => {
        sessions.delete(sessionId);
        sessionActivity.delete(sessionId);
      },
    });

    // Clean up the session map when the transport itself closes (covers the
    // case where the SDK closes the transport directly, e.g. via DELETE).
    transport.onclose = () => {
      const id = transport.sessionId;
      if (id !== undefined) {
        sessions.delete(id);
        sessionActivity.delete(id);
      }
    };

    server.connect(transport).catch((err: unknown) => {
      console.error(
        `clippy-mcp: session connect error: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    });

    return transport;
  }

  /** Read the raw request body as a Buffer, then parse as JSON. */
  async function readBody(req: IncomingMessage): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = [];
      req.on("data", (chunk: Buffer) => chunks.push(chunk));
      req.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        if (!raw) {
          resolve(undefined);
          return;
        }
        try {
          resolve(JSON.parse(raw));
        } catch {
          resolve(undefined);
        }
      });
      req.on("error", reject);
    });
  }

  const httpServer = http.createServer(
    async (req: IncomingMessage, res: ServerResponse) => {
      const url = new URL(req.url ?? "/", `http://127.0.0.1:${parsedPort}`);

      // Health check endpoint — no MCP handshake needed.
      if (url.pathname === "/health" && req.method === "GET") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ status: "ok" }));
        return;
      }

      // All MCP traffic goes through /mcp.
      if (url.pathname === "/mcp") {
        const sessionId = req.headers["mcp-session-id"] as string | undefined;

        if (req.method === "POST") {
          // POST: either an initialize (new session) or a subsequent request.
          const body = await readBody(req);
          let transport: StreamableHTTPServerTransport;

          if (sessionId && sessions.has(sessionId)) {
            // Existing session — refresh its idle clock.
            transport = sessions.get(sessionId)!;
            touchSession(sessionId);
          } else if (sessionId) {
            // Unknown session ID — reject per spec.
            res.writeHead(404, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "Session not found" }));
            return;
          } else {
            // No session ID on a POST: must be an initialize request.
            transport = createSession();
          }

          await transport.handleRequest(req, res, body);
          return;
        }

        if (req.method === "GET") {
          // GET opens the SSE stream for server-to-client notifications.
          if (!sessionId || !sessions.has(sessionId)) {
            res.writeHead(400, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "Missing or invalid mcp-session-id" }));
            return;
          }
          // Mark this session as having a live SSE stream so the reaper skips
          // it for as long as the connection is open.  The "close" event on
          // ServerResponse fires when the underlying socket is destroyed
          // (client disconnect, server push of FIN, or process shutdown).
          // At that point we remove the guard and reset lastSeen so the
          // normal TTL clock restarts from now.
          openSseStreams.add(sessionId);
          res.once("close", () => {
            openSseStreams.delete(sessionId);
            // Restart the idle clock from the moment the stream closes so a
            // session that reconnects soon is not immediately reaped.
            touchSession(sessionId);
          });
          touchSession(sessionId);
          await sessions.get(sessionId)!.handleRequest(req, res);
          return;
        }

        if (req.method === "DELETE") {
          // DELETE tears down a session explicitly requested by the client.
          if (!sessionId || !sessions.has(sessionId)) {
            res.writeHead(404, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "Session not found" }));
            return;
          }
          touchSession(sessionId);
          const body = await readBody(req);
          await sessions.get(sessionId)!.handleRequest(req, res, body);
          return;
        }

        res.writeHead(405, { Allow: "GET, POST, DELETE" });
        res.end();
        return;
      }

      // Unknown path.
      res.writeHead(404);
      res.end();
    },
  );

  httpServer.listen(parsedPort, "127.0.0.1", () => {
    console.error(
      `clippy-mcp HTTP listening on http://127.0.0.1:${parsedPort}/mcp (db: ${dbPath})`,
    );
  });

  // Stop the reaper when the HTTP server shuts down so no handles linger.
  httpServer.on("close", () => {
    clearInterval(reaperTimer);
  });
} else {
  // -------------------------------------------------------------------------
  // Stdio mode (default, unchanged behaviour).
  // -------------------------------------------------------------------------

  const server = new Server(
    { name: "clippy-mcp", version: "0.1.0" },
    { capabilities: { tools: {} } },
  );
  registerTools(server);

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`clippy-mcp ready (db: ${dbPath})`);
}
