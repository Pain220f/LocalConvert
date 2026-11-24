#!/bin/zsh
# Builds LocalConvert (Release) and verifies its privacy guarantees on the *signed binary*:
#   1. App Sandbox on, no network entitlements, only user-selected file access.
#   2. No networking frameworks linked, no URLSession / socket-connect symbols imported.
#   3. No third-party frameworks or helper executables bundled.
# Usage: Scripts/verify-privacy.sh [path/to/LocalConvert.app]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ge 1 ]]; then
  APP="$1"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  DERIVED="$WORK/dd"
  echo "▸ Building Release into $DERIVED"
  xcodebuild -project LocalConvert.xcodeproj -scheme LocalConvert -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" build -quiet
  APP="$DERIVED/Build/Products/Release/LocalConvert.app"
fi
BIN="$APP/Contents/MacOS/LocalConvert"
echo "▸ Architectures: $(lipo -archs "$BIN")"
fail=0
pass() { print -P "%F{green}✔%f $1"; }
bad()  { print -P "%F{red}✘%f $1"; fail=1; }

if codesign --verify --deep --strict "$APP" 2>/dev/null; then pass "code signature valid (deep, strict)"; else bad "code signature invalid"; fi
# Capture first, then parse: `grep -m1` closing the pipe early would SIGPIPE codesign under pipefail.
SIGNING="$(codesign -dvvv "$APP" 2>&1 || true)"
FLAGS="$(sed -nE 's/^CodeDirectory.*flags=([^ ]+).*/\1/p' <<<"$SIGNING" | head -n1)"
[[ "$FLAGS" == *runtime* ]] && pass "Hardened Runtime enforced ($FLAGS)" || bad "Hardened Runtime flag missing ($FLAGS)"
HEADER="$(otool -hv "$BIN")"
if grep -q PIE <<<"$HEADER"; then pass "position-independent executable (PIE)"; else bad "binary is not PIE"; fi

ENT="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
value() { /usr/libexec/PlistBuddy -c "Print :$1" /dev/stdin <<<"$ENT" 2>/dev/null || echo "absent"; }

[[ "$(value com.apple.security.app-sandbox)" == "true" ]] && pass "App Sandbox enabled" || bad "App Sandbox NOT enabled"
for key in com.apple.security.network.client com.apple.security.network.server; do
  v="$(value $key)"; [[ "$v" != "true" ]] && pass "$key = $v" || bad "$key is TRUE"
done
[[ "$(value com.apple.security.files.user-selected.read-write)" == "true" ]] && pass "user-selected read-write only" || bad "user-selected file access missing"
if grep -q "temporary-exception\|files.all\|downloads" <<<"$ENT"; then bad "unexpected file/mach exceptions present"; else pass "no temporary exceptions"; fi

if otool -L "$BIN" | grep -Eq "/Network.framework|/CFNetwork.framework|Sparkle|Firebase|Sentry"; then
  bad "networking / telemetry framework linked directly:"; otool -L "$BIN" | grep -E "Network|Sparkle|Firebase|Sentry"
else
  pass "no Network/CFNetwork/Sparkle/Firebase/Sentry linked"
fi

SYMBOLS="$(nm -u "$BIN" 2>/dev/null | grep -Ei "URLSession|NSURLConnection|nw_connection|_connect\$|_getaddrinfo|CFSocket|CFStreamCreatePairWithSocket" || true)"
[[ -z "$SYMBOLS" ]] && pass "no URLSession / socket / DNS symbols imported" || { bad "network symbols imported:"; echo "$SYMBOLS"; }

EXTRA="$(find "$APP/Contents" \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" \) | head || true)"
EXES="$(ls "$APP/Contents/MacOS" | grep -v '^LocalConvert$' || true)"
[[ -z "$EXTRA$EXES" ]] && pass "no bundled frameworks, dylibs, XPC services or helper tools" || { bad "bundled code found:"; echo "$EXTRA$EXES"; }

echo
(( fail == 0 )) && print -P "%F{green}All privacy checks passed.%f" || { print -P "%F{red}Privacy checks FAILED.%f"; exit 1; }
