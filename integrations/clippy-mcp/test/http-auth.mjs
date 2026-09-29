// HTTP transport auth (SEC-03): the loopback endpoint must reject every request
// without the per-install bearer token, and refuse to start without one.
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import net from "node:net";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const here = path.dirname(new URL(import.meta.url).pathname);
const bundle = path.resolve(here, "..", "build", "index.mjs");
const dir = mkdtempSync(path.join(tmpdir(), "clippy-http-auth-"));
const dbPath = path.join(dir, "clippy.sqlite");
const seed = new DatabaseSync(dbPath);
seed.exec(readFileSync(path.join(here, "schema.sql"), "utf8"));
seed.close();

const TOKEN = "t".repeat(43);
const fail = (m) => {
  console.error("FAIL:", m);
  process.exit(1);
};
const check = (c, m) => {
  if (!c) fail(m);
};

const freePort = () =>
  new Promise((resolve, reject) => {
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
    s.on("error", reject);
  });

// 1. HTTP mode without a token (or with a short one) must exit non-zero.
for (const token of [undefined, "short"]) {
  const env = { ...process.env, CLIPPY_DB_PATH: dbPath, CLIPPY_MCP_PORT: String(await freePort()) };
  delete env.CLIPPY_MCP_TOKEN;
  if (token !== undefined) env.CLIPPY_MCP_TOKEN = token;
  const r = spawnSync("node", [bundle], { env, encoding: "utf8", timeout: 15_000 });
  check(r.status === 1, `server started without a valid token (status ${r.status})`);
  check(/CLIPPY_MCP_TOKEN/.test(r.stderr), "refusal did not mention CLIPPY_MCP_TOKEN");
}

// 2. With a token: 401 without/with a wrong one, 200 with the right one.
const port = await freePort();
const child = spawn("node", [bundle], {
  env: { ...process.env, CLIPPY_DB_PATH: dbPath, CLIPPY_MCP_PORT: String(port), CLIPPY_MCP_TOKEN: TOKEN },
  stdio: ["ignore", "ignore", "pipe"],
});
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("server did not start")), 15_000);
  child.stderr.on("data", (d) => {
    if (d.toString().includes("listening")) {
      clearTimeout(timer);
      resolve();
    }
  });
  child.on("exit", () => reject(new Error("server exited early")));
}).catch((e) => fail(e.message));

const base = `http://127.0.0.1:${port}`;
const status = async (p, headers = {}, init = {}) =>
  (await fetch(base + p, { headers, ...init })).status;
const initBody = JSON.stringify({
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "0" } },
});
try {
  check((await status("/health")) === 401, "/health served without a token");
  check((await status("/health", { Authorization: "Bearer wrong" })) === 401, "wrong token accepted");
  check((await status("/health", { Authorization: TOKEN })) === 401, "token without Bearer scheme accepted");
  check((await status("/health", { Authorization: `Bearer ${TOKEN}` })) === 200, "valid token rejected");
  check(
    (await status("/mcp", { "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
      { method: "POST", body: initBody })) === 401,
    "/mcp initialize served without a token",
  );
  const ok = await status(
    "/mcp",
    { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
    { method: "POST", body: initBody },
  );
  check(ok === 200, `/mcp initialize with token returned ${ok}`);
  console.log("HTTP AUTH: all checks passed");
} finally {
  child.kill();
}
process.exit(0);
