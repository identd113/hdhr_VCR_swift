#!/bin/bash
# Generates the EdDSA key pair used to sign Sparkle update packages.
# Run ONCE before your first notarized release. Never run again — regenerating
# breaks signature verification for any user who has already installed the app.
#
# What it does:
#   1. Finds the generate_keys tool bundled with Sparkle via SPM
#   2. Runs it to generate a key pair — private key goes to ~/.sparkle_private_key,
#      public key is printed to stdout
#   3. Patches the public key into Info.plist (SUPublicEDKey)
#   4. Reminds you to back up the private key
#
# Usage:
#   ./tools/generate_sparkle_keys.sh
#   ./tools/generate_sparkle_keys.sh --help

set -e

if [[ "${1:-}" == "--help" ]]; then
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$REPO_ROOT/hdhrVCRplus.app/Contents/Info.plist"
PLACEHOLDER="SPARKLE_PUBLIC_KEY_PLACEHOLDER"

echo
echo "── Sparkle EdDSA Key Generation ──"
echo

# ── Resolve Sparkle first if needed ──────────────────────────────────────────

if [ ! -d "$REPO_ROOT/.build/artifacts" ]; then
    echo "Resolving Swift packages to get Sparkle tools…"
    cd "$REPO_ROOT" && swift package resolve
fi

# ── Find generate_keys ────────────────────────────────────────────────────────

GENERATE_KEYS=$(find "$REPO_ROOT/.build/artifacts" -name "generate_keys" -type f 2>/dev/null | head -1)

if [ -z "$GENERATE_KEYS" ]; then
    echo "ERROR: Could not find generate_keys in .build/artifacts."
    echo "Try running: swift package resolve"
    exit 1
fi

echo "Found: $GENERATE_KEYS"
echo

# ── Guard against accidental re-run ──────────────────────────────────────────

if [ -f "$HOME/.sparkle_private_key" ]; then
    echo "WARNING: ~/.sparkle_private_key already exists."
    echo "Re-generating will break update verification for existing installs."
    read -r -p "Are you sure you want to continue? (yes/N): " _CONFIRM
    [[ "$_CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

# ── Generate ──────────────────────────────────────────────────────────────────

echo "Generating key pair…"
OUTPUT=$("$GENERATE_KEYS" 2>&1)
# generate_keys writes the private key to ~/.sparkle_private_key automatically.
# Parse the public key from output — handles both first-run and pre-existing-key formats.
PUBLIC_KEY=$(echo "$OUTPUT" | grep -E "<string>[A-Za-z0-9+/=]{40,}</string>" | sed 's/.*<string>\([^<]*\)<\/string>.*/\1/' | head -1)

if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY=$(echo "$OUTPUT" | grep -A1 "Public key" | tail -1 | tr -d ' ')
fi

if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY=$(echo "$OUTPUT" | grep -E "^[A-Za-z0-9+/=]{40,}$" | head -1)
fi

if [ -z "$PUBLIC_KEY" ]; then
    echo "ERROR: Could not extract public key from generate_keys output."
    echo "Output was:"
    echo "$OUTPUT"
    exit 1
fi

echo
echo "Public key: $PUBLIC_KEY"
echo

# ── Patch Info.plist ──────────────────────────────────────────────────────────

if grep -q "$PLACEHOLDER" "$INFO_PLIST"; then
    sed -i '' "s|$PLACEHOLDER|$PUBLIC_KEY|" "$INFO_PLIST"
    echo "✓ Patched SUPublicEDKey in Info.plist"
else
    CURRENT=$(grep -A1 "SUPublicEDKey" "$INFO_PLIST" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
    if [ "$CURRENT" == "$PUBLIC_KEY" ]; then
        echo "✓ Info.plist already has the correct public key."
    else
        echo "INFO: Info.plist SUPublicEDKey is already set to a different value:"
        echo "  Current: $CURRENT"
        echo "  New:     $PUBLIC_KEY"
        echo "Update it manually if you intended to rotate keys."
    fi
fi

# ── Reminder ──────────────────────────────────────────────────────────────────

echo
echo "── IMPORTANT ──────────────────────────────────────────────────────────"
echo
echo "  Private key saved to: ~/.sparkle_private_key"
echo
echo "  Back this up somewhere safe (password manager, encrypted drive)."
echo "  If you lose it, you cannot sign future updates and users will need"
echo "  to manually download and reinstall the app."
echo
echo "  Public key is now in Info.plist — commit that change."
echo "───────────────────────────────────────────────────────────────────────"
echo
echo "Done. Run ./deploy_release.sh to build a signed, notarized release."
