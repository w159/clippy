#!/bin/zsh
# Build a release binary and wrap it in Clippy.app. The bundle (with a stable
# bundle id and an ad-hoc signature) is what makes the Accessibility
# permission grant survive rebuilds.
#
# Usage: make-app.sh [version]
#   version defaults to $VERSION or 0.0.0-dev. CI passes the git tag value.
#   REQUIRE_SPARKLE=1 makes a missing Sparkle public key a hard error (CI).
#
# Signing modes:
#   CODESIGN_IDENTITY unset (default) - ad-hoc signature for local dev builds;
#     codesign --sign - produces the "-" (ad-hoc) identity.
#   CODESIGN_IDENTITY set - Developer ID signing with hardened runtime and a
#     secure timestamp; used by CI after keychain import. The value must be the
#     full identity string, e.g.:
#       "Developer ID Application: Your Name (TEAMID)"
#     or the 40-character SHA-1 hash of the certificate.
#
# When CODESIGN_IDENTITY is set the script signs components inside
# Sparkle.framework innermost-first (XPC services -> Autoupdate/Updater.app ->
# framework -> app), as required by Apple:
#   https://developer.apple.com/library/archive/documentation/Security/
#   Conceptual/CodeSigningGuide/Procedures/Procedures.html#//apple_ref/doc/
#   uid/TP40005929-CH4-TNTAG201
# Sparkle 2.x signing commands follow the official Sparkle docs:
#   https://sparkle-project.org/documentation/sandboxing/#code-signing
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VERSION:-0.0.0-dev}}"
# CI sets GITHUB_REPOSITORY; the fallback covers local builds.
REPO_SLUG="${GITHUB_REPOSITORY:-w159/clippy}"
FEED_URL="https://raw.githubusercontent.com/${REPO_SLUG}/main/appcast.xml"
PUBLIC_KEY_FILE="scripts/sparkle-public-key.txt"

swift build -c release
swift build -c release --product clippy-cli

APP="build/Clippy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/Clippy "$APP/Contents/MacOS/Clippy"

# Command line tool (FEAT-12). The build product is named clippy-cli (a product
# named "clippy" would collide with "Clippy" on case-insensitive volumes); it
# ships as Contents/Resources/bin/clippy. Copied before codesign so the app's
# signature seals it.
mkdir -p "$APP/Contents/Resources/bin"
cp .build/release/clippy-cli "$APP/Contents/Resources/bin/clippy"

# Copy the pre-built icon into the bundle's Resources directory.
# The .icns is generated once via: swift assets/generate-icon.swift
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# -----------------------------------------------------------------------
# Bundle the MCP server into Resources so an installed app has a server to
# run. It is a single esbuild .mjs that uses Node's built-in node:sqlite
# (Node >= 22.13), so there is no node_modules to ship. Without this copy
# only dev builds work (they fall back to the source tree); an installed
# app would have nothing to launch. Must run before codesign so the
# signature covers it.
#   REQUIRE_MCP=1 makes a missing/unbuildable server a hard error (CI).
MCP_DIR="integrations/clippy-mcp"
MCP_BUILT="$MCP_DIR/build/index.mjs"
if command -v npm >/dev/null 2>&1; then
    ( cd "$MCP_DIR" && npm ci --no-audit --no-fund && npm run build )
fi
if [[ -f "$MCP_BUILT" ]]; then
    mkdir -p "$APP/Contents/Resources/clippy-mcp"
    cp "$MCP_BUILT" "$APP/Contents/Resources/clippy-mcp/index.mjs"
    echo "Bundled MCP server: $APP/Contents/Resources/clippy-mcp/index.mjs"
elif [[ "${REQUIRE_MCP:-0}" == "1" ]]; then
    echo "error: $MCP_BUILT not found; install Node/npm and build the MCP server" >&2
    exit 1
else
    echo "warning: $MCP_BUILT not found; building app without the bundled MCP server" >&2
fi

# -----------------------------------------------------------------------
# App Intents metadata (FEAT-11). Xcode normally runs appintentsmetadataprocessor;
# SwiftPM does not, so run it here over the release build's Swift const-value
# files and ship Metadata.appintents in Resources. Best-effort: on failure the app
# still works but Shortcuts will not list Clippy's actions. Whether the system
# registers them can only be confirmed by running the built bundle.
CONST_DIR="$(find .build -type d -path '*Clippy-p.build/Objects-normal/arm64' -path '*Release*' 2>/dev/null | head -n 1)"
if [[ -n "$CONST_DIR" && -f "$CONST_DIR/Clippy.SwiftFileList" ]] && xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
    AI_TMP="$(mktemp -d)"
    ls "$CONST_DIR"/*.swiftconstvalues > "$AI_TMP/constvals.txt"
    : > "$AI_TMP/meta.txt"
    if xcrun appintentsmetadataprocessor \
        --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
        --module-name Clippy --sdk-root "$(xcrun --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build/{print $3}')" \
        --platform-family macOS --deployment-target 26.0 --bundle-identifier com.jerry.clippy \
        --output "$AI_TMP/out" --target-triple arm64-apple-macos26.0 \
        --binary-file "$PWD/.build/release/Clippy" --dependency-file "$AI_TMP/dep.d" \
        --stringsdata-file "$AI_TMP/x.stringsdata" --swift-const-vals-list "$AI_TMP/constvals.txt" \
        --source-files "$CONST_DIR/Clippy.SwiftFileList" --metadata-file-list "$AI_TMP/meta.txt" \
        --force --compile-time-extraction >/dev/null 2>&1 && [[ -d "$AI_TMP/out/Metadata.appintents" ]]; then
        cp -R "$AI_TMP/out/Metadata.appintents" "$APP/Contents/Resources/Metadata.appintents"
        echo "Bundled App Intents metadata (registration with Shortcuts unverified)"
    else
        echo "warning: appintentsmetadataprocessor failed; Shortcuts actions will not register" >&2
    fi
    rm -rf "$AI_TMP"
else
    echo "warning: App Intents const-value files or processor not found; skipping metadata" >&2
fi

# Sparkle ships as a binary xcframework inside the SwiftPM artifacts dir; the
# app bundle needs its own embedded copy plus an rpath that points at it.
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d -name 'Sparkle.framework' -path '*macos*' | head -n 1)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "error: Sparkle.framework not found under .build/artifacts" >&2
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Clippy"

# The Sparkle plist keys only go in when a real public key is committed;
# without them the in-app updater stays inert (local dev builds).
SPARKLE_KEYS=""
PUBLIC_KEY="$( [[ -f "$PUBLIC_KEY_FILE" ]] && tr -d '[:space:]' < "$PUBLIC_KEY_FILE" || true )"
if [[ -n "$PUBLIC_KEY" && "$PUBLIC_KEY" != REPLACE_* ]]; then
    SPARKLE_KEYS=$(cat <<KEYS
    <key>SUFeedURL</key>
    <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
KEYS
    )
elif [[ "${REQUIRE_SPARKLE:-0}" == "1" ]]; then
    echo "error: $PUBLIC_KEY_FILE missing or placeholder; run Sparkle generate_keys and commit the public key" >&2
    exit 1
else
    echo "warning: no Sparkle public key in $PUBLIC_KEY_FILE; building without auto-update" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Clippy</string>
    <key>CFBundleIdentifier</key>
    <string>com.jerry.clippy</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Clippy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.jerry.clippy.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>clippy</string>
            </array>
        </dict>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Lets AI providers on the local network (LM Studio, llama.cpp, Ollama on a LAN
             IP or .local name) work over plain http. Narrow on purpose: internet hosts
             still require https; NSAllowsArbitraryLoads is NOT set. -->
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>Local-only clipboard manager.</string>
${SPARKLE_KEYS}
</dict>
</plist>
PLIST

# -----------------------------------------------------------------------
# Code signing
# -----------------------------------------------------------------------
# CODESIGN_IDENTITY is empty in local dev builds (ad-hoc) and set to the
# full Developer ID identity string in CI builds (Developer ID signing with
# hardened runtime + secure timestamp).
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

if [[ -n "$CODESIGN_IDENTITY" ]]; then
    # Developer ID / distribution signing.
    # Sign innermost components first so the outer bundle's resource envelope
    # covers already-signed nested items. --options runtime enables Hardened
    # Runtime (required for notarization). --timestamp embeds a secure RFC 3161
    # timestamp so the signature stays valid after certificate expiry.
    # Source: Apple Code Signing Guide (nested code section) and
    # https://sparkle-project.org/documentation/sandboxing/#code-signing
    SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"

    # 1. XPC services (innermost - Sparkle 2.x, version B)
    #    Installer: no special entitlements needed.
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"

    # 2. Downloader XPC service: preserve its existing entitlements (com.apple.
    #    security.network.client) rather than stripping them. Sparkle docs for
    #    >= 2.6 specify --preserve-metadata=entitlements here.
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        --preserve-metadata=entitlements \
        "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"

    # 3. Autoupdate helper tool
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$SPARKLE_FW/Versions/B/Autoupdate"

    # 4. Updater.app (contains its own binary)
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$SPARKLE_FW/Versions/B/Updater.app"

    # 5. The framework bundle itself (covers all remaining resources)
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$SPARKLE_FW"

    # 5b. The bundled CLI (a nested Mach-O, signed before the outer app)
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$APP/Contents/Resources/bin/clippy"

    # 6. The app bundle last (outer envelope covers everything above)
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$APP"

    echo "Built $APP (version ${VERSION}, Developer ID signed)"
else
    # Ad-hoc signature for local dev builds.
    # The "-" identity produces a local-only hash-based signature that lets
    # macOS grant the Accessibility permission persistently across rebuilds.
    codesign --force --sign - "$APP"
    echo "Built $APP (version ${VERSION}, ad-hoc signed)"
fi
