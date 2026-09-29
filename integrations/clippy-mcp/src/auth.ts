import { timingSafeEqual } from "node:crypto";

/** Minimum length of the bearer token Clippy generates (32 random bytes, base64url = 43 chars). */
export const MIN_TOKEN_LENGTH = 32;

/**
 * True when `header` is exactly `Bearer <expected>`. Compared in constant time
 * so a co-resident process cannot recover the token byte by byte from response
 * timing. A missing header, a wrong scheme, or a length mismatch is a plain
 * `false`.
 */
export function isAuthorized(header: string | string[] | undefined, expected: string): boolean {
  if (typeof header !== "string") return false;
  const prefix = "Bearer ";
  if (!header.startsWith(prefix)) return false;
  const presented = Buffer.from(header.slice(prefix.length), "utf8");
  const wanted = Buffer.from(expected, "utf8");
  if (presented.length !== wanted.length) return false;
  return timingSafeEqual(presented, wanted);
}

/**
 * Read and validate CLIPPY_MCP_TOKEN. Returns the token, or an error string
 * describing why the HTTP transport must refuse to start.
 */
export function resolveToken(
  env: NodeJS.ProcessEnv,
): { token: string } | { error: string } {
  const token = env.CLIPPY_MCP_TOKEN?.trim();
  if (!token) {
    return { error: "CLIPPY_MCP_TOKEN is not set; the HTTP transport requires a bearer token." };
  }
  if (token.length < MIN_TOKEN_LENGTH) {
    return { error: `CLIPPY_MCP_TOKEN is too short (minimum ${MIN_TOKEN_LENGTH} characters).` };
  }
  return { token };
}
