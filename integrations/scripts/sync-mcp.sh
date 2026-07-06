#!/usr/bin/env bash
# Rebuild the clippy-mcp server and copy the bundle into the plugin.
# Run this after any change under integrations/clippy-mcp/src/.
set -euo pipefail

INTEGRATIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_DIR="$INTEGRATIONS_DIR/clippy-mcp"
PLUGIN_MCP_DIR="$INTEGRATIONS_DIR/clippy-plugin/mcp"

# Build (esbuild bundle -> build/index.mjs)
cd "$MCP_DIR"
npm run build

# Vendor into the plugin so it is self-contained
mkdir -p "$PLUGIN_MCP_DIR"
cp "$MCP_DIR/build/index.mjs" "$PLUGIN_MCP_DIR/index.mjs"

echo "Synced: $PLUGIN_MCP_DIR/index.mjs"
