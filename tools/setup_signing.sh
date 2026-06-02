#!/bin/bash
# Walks through Developer ID certificate setup for notarization — no Xcode required.
# Run this once before using deploy_release.sh.
#
# What it does, in order:
#   1. Checks prerequisites (openssl, security, xcrun notarytool)
#   2. Generates a private key + CSR for the Apple portal
#   3. Waits for you to download the signed certificate from developer.apple.com
#   4. Imports the cert + key into your login keychain
#   5. Stores your app-specific notarization password in the keychain
#   6. Patches SIGN_IDENTITY and NOTARY_PROFILE into deploy_release.sh
#   7. Verifies everything with a dry-run codesign
#
# Usage:
#   ./tools/setup_signing.sh          # interactive walkthrough
#   ./tools/setup_signing.sh --help   # show this message

set -e

# ── Helpers ──────────────────────────────────────────────────────────────────

_bold()  { printf '\033[1m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }
_red()   { printf '\033[31m%s\033[0m' "$*"; }
_cyan()  { printf '\033[36m%s\033[0m' "$*"; }
_dim()   { printf '\033[2m%s\033[0m' "$*"; }

step() { echo; echo "$(_bold "── Step $1:") $2"; }
ok()   { echo "  $(_green "✓") $*"; }
info() { echo "  $(_dim   "·") $*"; }
fail() { echo "  $(_red   "✗") $*"; }
ask()  {
    # ask <varname> <prompt> [default]
    local _var="$1" _prompt="$2" _default="$3"
    local _val
    if [ -n "$_default" ]; then
        read -r -p "  → $_prompt [$_default]: " _val
        _val="${_val:-$_default}"
    else
        read -r -p "  → $_prompt: " _val
    fi
    printf -v "$_var" '%s' "$_val"
}
ask_secret() {
    local _var="$1" _prompt="$2"
    local _val
    read -r -s -p "  → $_prompt: " _val
    echo
    printf -v "$_var" '%s' "$_val"
}
open_url() {
    info "Opening $1 …"
    open "$1" 2>/dev/null || true
}
pause() {
    read -r -p "  → Press Enter when ready…" _
}

# ── --help ───────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--help" ]]; then
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

# ── Locate repo root ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_RELEASE="$REPO_ROOT/deploy_release.sh"
APP="$REPO_ROOT/hdhrVCRplus.app"
ENTITLEMENTS="$REPO_ROOT/hdhrVCRplus.entitlements"
WORK_DIR="$REPO_ROOT/.signing_work"   # temp dir; cleaned up at the end

if [ ! -f "$DEPLOY_RELEASE" ]; then
    fail "deploy_release.sh not found at $DEPLOY_RELEASE"
    exit 1
fi

# ── Banner ───────────────────────────────────────────────────────────────────

echo
echo "$(_bold "hdhrVCR+ Developer ID / Notarization Setup")"
echo "$(_dim  "────────────────────────────────────────────")"
echo
echo "This script walks you through getting a Developer ID certificate"
echo "and configuring deploy_release.sh for notarized builds."
echo
echo "You will need:"
echo "  • An Apple Developer Program account ($99/year)"
echo "    $(_cyan "https://developer.apple.com/programs")"
echo "  • An app-specific password from appleid.apple.com"
echo
echo "Estimated time: 10–15 minutes (most of that is waiting on the portal)."
echo

ask _CONTINUE "Continue? (y/n)" "y"
[[ "$_CONTINUE" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────

step 1 "Checking prerequisites"

_missing=0
for _cmd in openssl security xcrun; do
    if command -v "$_cmd" &>/dev/null; then
        ok "$_cmd found"
    else
        fail "$_cmd not found"
        _missing=1
    fi
done

if ! xcrun --find notarytool &>/dev/null; then
    fail "notarytool not found — install Xcode Command Line Tools:"
    info "  xcode-select --install"
    exit 1
else
    ok "notarytool found"
fi

[ "$_missing" -eq 0 ] || { fail "Install missing tools and re-run."; exit 1; }

# ── Step 2: Gather identity details ──────────────────────────────────────────

step 2 "Your Apple Developer details"
echo
info "These go into the certificate's subject and deploy_release.sh."
echo

ask FULL_NAME  "Your full name (as it appears on your Apple Developer account)"
ask APPLE_ID   "Apple ID email"
ask TEAM_ID    "Team ID (10-char string from developer.apple.com/account → Membership)"
ask COUNTRY    "Two-letter country code" "US"

echo
info "Name:    $FULL_NAME"
info "Apple ID: $APPLE_ID"
info "Team ID:  $TEAM_ID"
info "Country:  $COUNTRY"
echo
ask _OK "Look right? (y/n)" "y"
[[ "$_OK" =~ ^[Yy] ]] || { echo "Re-run and enter correct details."; exit 1; }

CERT_NAME="Developer ID Application: $FULL_NAME ($TEAM_ID)"

# ── Step 3: Generate private key + CSR ───────────────────────────────────────

step 3 "Generating private key and Certificate Signing Request"

mkdir -p "$WORK_DIR"
KEY_FILE="$WORK_DIR/developerID.key"
CSR_FILE="$WORK_DIR/developerID.csr"

if [ -f "$KEY_FILE" ]; then
    info "Private key already exists — reusing it."
else
    openssl genrsa -out "$KEY_FILE" 2048 2>/dev/null
    ok "Private key generated: $KEY_FILE"
fi

openssl req -new -key "$KEY_FILE" \
    -out "$CSR_FILE" \
    -subj "/emailAddress=${APPLE_ID}/CN=${FULL_NAME}/C=${COUNTRY}" \
    2>/dev/null
ok "CSR generated: $CSR_FILE"
echo
info "Keep the private key file safe — you need it to import the cert in Step 5."

# ── Step 4: Submit CSR on developer portal ───────────────────────────────────

step 4 "Submit the CSR to the Apple Developer portal"
echo
echo "  1. Opening the certificate creation page…"
open_url "https://developer.apple.com/account/resources/certificates/add"
echo
echo "  2. Choose $(_bold "Developer ID Application") and click Continue."
echo "  3. Under 'Certificate Signing Request', upload:"
echo "     $(_cyan "$CSR_FILE")"
echo "  4. Click Continue, then Download. Save the file as:"
echo "     $(_cyan "$WORK_DIR/developerID_application.cer")"
echo
pause

CER_FILE="$WORK_DIR/developerID_application.cer"
_attempts=0
while [ ! -f "$CER_FILE" ]; do
    _attempts=$((_attempts + 1))
    if [ "$_attempts" -gt 1 ]; then
        fail "Still not found. Make sure you saved it to:"
        info "$CER_FILE"
    fi
    ask _RETRY "File not found yet — press Enter to check again, or 'q' to quit" ""
    [[ "$_RETRY" == "q" ]] && exit 1
done
ok "Certificate file found."

# ── Step 5: Import cert + key into keychain ───────────────────────────────────

step 5 "Importing certificate and private key into your login keychain"

PEM_FILE="$WORK_DIR/developerID.pem"
P12_FILE="$WORK_DIR/developerID.p12"

openssl x509 -in "$CER_FILE" -inform DER -out "$PEM_FILE" 2>/dev/null
ok "Certificate converted to PEM."

echo
info "You will be prompted to set an export password for the .p12 file."
info "Use something temporary — you only need it for the next import step."
echo
openssl pkcs12 -export \
    -inkey "$KEY_FILE" \
    -in "$PEM_FILE" \
    -out "$P12_FILE" \
    -name "$CERT_NAME" \
    -legacy 2>/dev/null || \
openssl pkcs12 -export \
    -inkey "$KEY_FILE" \
    -in "$PEM_FILE" \
    -out "$P12_FILE" \
    -name "$CERT_NAME"

ok ".p12 package created."
echo
info "Now importing into your login keychain."
info "macOS may show a keychain unlock prompt."
security import "$P12_FILE" \
    -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign \
    -T /usr/bin/security

ok "Imported into keychain."

# Verify the identity is visible
echo
info "Verifying codesign can see the identity…"
if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
    ok "Identity visible to codesign: $CERT_NAME"
else
    fail "Identity not found in codesigning identities."
    info "This can happen if the keychain needs to be unlocked or trusted."
    info "Try: security find-identity -v -p codesigning"
    info "If it shows up there, you may need to manually set trust in Keychain Access."
    exit 1
fi

# ── Step 6: App-specific password + notarytool credentials ───────────────────

step 6 "Storing notarization credentials"
echo
echo "  You need an app-specific password from:"
echo "  $(_cyan "https://appleid.apple.com") → Sign-In and Security → App-Specific Passwords"
echo
open_url "https://appleid.apple.com/account/manage"
echo
echo "  Generate one labelled 'hdhrVCR notarize' (or anything you'll recognise)."
echo "  It looks like: $(_dim "xxxx-xxxx-xxxx-xxxx")"
echo
pause

ask_secret APP_PASSWORD "Paste your app-specific password (input hidden)"

echo
info "Storing credentials in keychain profile 'hdhrVCR-notary'…"
xcrun notarytool store-credentials "hdhrVCR-notary" \
    --apple-id "$APPLE_ID" \
    --team-id  "$TEAM_ID" \
    --password "$APP_PASSWORD"

ok "Notarization credentials stored."

# ── Step 7: Patch deploy_release.sh ──────────────────────────────────────────

step 7 "Patching deploy_release.sh"

# Replace the placeholder SIGN_IDENTITY line
sed -i '' \
    "s|SIGN_IDENTITY=\"Developer ID Application: YOUR NAME (XXXXXXXXXX)\"|SIGN_IDENTITY=\"${CERT_NAME}\"|" \
    "$DEPLOY_RELEASE"

ok "SIGN_IDENTITY set to: $CERT_NAME"
ok "NOTARY_PROFILE is already set to: hdhrVCR-notary"

# ── Step 8: Register bundle ID (optional but good practice) ──────────────────

step 8 "Register bundle ID on the developer portal (recommended)"
echo
info "Bundle ID: com.hdhr.vcrplus"
info "This is optional for notarization but good practice."
echo
ask _OPEN_PORTAL "Open the identifier registration page? (y/n)" "y"
if [[ "$_OPEN_PORTAL" =~ ^[Yy] ]]; then
    open_url "https://developer.apple.com/account/resources/identifiers/add/bundleId"
    echo
    info "Choose App IDs → App, enter 'com.hdhr.vcrplus', click Continue → Register."
    pause
fi

# ── Step 9: Dry-run codesign verification ────────────────────────────────────

step 9 "Dry-run signing verification"
echo
info "Signing the current app bundle with your Developer ID to verify everything works…"
info "(This does NOT notarize — it just confirms the cert + entitlements are correct.)"
echo

if [ ! -d "$APP" ]; then
    info "App bundle not built yet — run ./deploy.sh first, then re-run this step."
    info "Skipping verification."
else
    find "$APP" -name "._*" -delete 2>/dev/null || true
    find "$APP" -name ".DS_Store" -delete 2>/dev/null || true
    xattr -cr "$APP" 2>/dev/null || true

    codesign --force --options runtime \
             --entitlements "$ENTITLEMENTS" \
             --sign "$CERT_NAME" \
             "$APP"

    echo
    codesign --verify --deep --strict --verbose=1 "$APP" && ok "Signature valid." || fail "Signature verification failed."
    echo
    info "Gatekeeper assessment (will say 'rejected' until notarized — that is expected):"
    spctl --assess --type execute --verbose "$APP" 2>&1 || true
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

step 10 "Cleaning up temporary key files"
echo
info "The private key, CSR, PEM, and .p12 are in: $WORK_DIR"
info "They are no longer needed — your keychain holds the private key."
echo
ask _CLEAN "Delete them now? (y/n)" "y"
if [[ "$_CLEAN" =~ ^[Yy] ]]; then
    rm -rf "$WORK_DIR"
    ok "Removed $WORK_DIR"
else
    info "Left in place. Delete manually when ready:"
    info "  rm -rf $WORK_DIR"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo
echo "$(_bold "────────────────────────────────────────────")"
echo "$(_green "✓ Setup complete.")"
echo
echo "To build, sign, notarize, and staple:"
echo "  $(_cyan "./deploy_release.sh")"
echo
echo "To sign without notarizing (faster iteration):"
echo "  $(_cyan "./deploy_release.sh --skip-notarize")"
echo
