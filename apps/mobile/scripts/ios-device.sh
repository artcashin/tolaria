#!/usr/bin/env bash
#
# iPadOS / iOS physical-device path for the Expo app.
#
#   apps/mobile/scripts/ios-device.sh check    # prerequisites only, changes nothing
#   apps/mobile/scripts/ios-device.sh team     # report signing team ids
#   apps/mobile/scripts/ios-device.sh run      # build, install and launch on an attached iPad
#
# The simulator path is `expo run:ios --device <sim udid>` and needs none of
# this; everything here exists because a PHYSICAL device requires signing.
#
# Deliberately mirrors scripts/ios.sh in the openbb-desk repo: the same
# APPLE_DEVELOPMENT_TEAM convention, read from .env.local rather than committed,
# and the same trust-gate remedy. Both apps signed by the same team means the
# certificate is trusted once per iPad, not once per app.
set -euo pipefail

CMD="${1:-check}"
shift || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root
APP="$ROOT/apps/mobile"
IOS="$APP/ios"
SCHEME=Tolaria
BUNDLE_ID=com.tolaria.mobile.dev

fail() { echo "[ios] $1" >&2; exit 1; }

# The team id identifies a developer account, so it is installation data and
# belongs in .env.local — the same rule the analytics keys follow.
if [ -z "${APPLE_DEVELOPMENT_TEAM:-}" ] && [ -f "$ROOT/.env.local" ]; then
  APPLE_DEVELOPMENT_TEAM="$(sed -n 's/^APPLE_DEVELOPMENT_TEAM=//p' "$ROOT/.env.local" | tail -1 | tr -d '"'"'"' ')"
  [ -n "$APPLE_DEVELOPMENT_TEAM" ] && export APPLE_DEVELOPMENT_TEAM
fi

# Team ids, read from the OU field of each installed signing certificate.
#
# Not the parenthesised id in the common name: that is the certificate's own
# id and differs from the team. "Apple Development: you@example.com (AF2P7DB694)"
# with OU=7UKUHTS23T signs for team 7UKUHTS23T, and using AF2P7DB694 fails to
# resolve a profile.
discovered_teams() {
  security find-identity -v -p codesigning 2>/dev/null |
    sed -n 's/.*"\(Apple Develop[^"]*\)".*/\1/p' |
    while IFS= read -r cn; do
      security find-certificate -c "$cn" -p 2>/dev/null |
        openssl x509 -noout -subject 2>/dev/null |
        sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p'
    done | sort -u
}

# Full Xcode, not Command Line Tools. Preferring DEVELOPER_DIR over
# `sudo xcode-select -s` keeps this runnable without a password.
resolve_xcode() {
  local dev_dir
  dev_dir="$(xcode-select -p 2>/dev/null || true)"
  if [ -z "$dev_dir" ] || [[ "$dev_dir" == *CommandLineTools* ]]; then
    [ -d /Applications/Xcode.app ] || return 1
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  return 0
}

# Attached physical devices, as "<udid>\t<name> (<os>)". xctrace is the only
# local source of the hardware udid that `xcodebuild -destination id=` wants;
# devicectl reports a different (CoreDevice) identifier.
attached_devices() {
  xcrun xctrace list devices 2>/dev/null |
    sed -n '/^== Devices ==/,/^== Simulators ==/p' |
    sed -nE 's/^(.+) \(([0-9][0-9.]*)\) \(([A-Za-z0-9-]+)\)$/\3\t\1 (\2)/p'
}

check() {
  local ok=1

  [ "$(uname -s)" = "Darwin" ] || fail "iOS builds require macOS."

  if resolve_xcode; then
    echo "[ios] ok       Xcode at ${DEVELOPER_DIR:-$(xcode-select -p)}"
  else
    echo "[ios] MISSING  Xcode (Command Line Tools are not enough)"
    echo "               xcodes install --latest        # or the App Store"
    ok=0
  fi

  if command -v pod >/dev/null 2>&1; then
    echo "[ios] ok       CocoaPods $(pod --version 2>/dev/null)"
  else
    echo "[ios] MISSING  CocoaPods  ->  brew install cocoapods"
    ok=0
  fi

  if [ -d "$IOS" ]; then
    echo "[ios] ok       native project at apps/mobile/ios"
  else
    echo "[ios] MISSING  apps/mobile/ios  ->  pnpm --filter @tolaria/mobile exec expo prebuild -p ios"
    ok=0
  fi

  # Signing is only needed for a physical device, so these are notes rather
  # than failures — the simulator runs unsigned.
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Develop"; then
    echo "[ios] ok       signing identity present"
    local teams; teams="$(discovered_teams | tr '\n' ' ')"
    if [ -n "${APPLE_DEVELOPMENT_TEAM:-}" ]; then
      echo "[ios] ok       APPLE_DEVELOPMENT_TEAM=$APPLE_DEVELOPMENT_TEAM"
    elif [ -n "$teams" ]; then
      echo "[ios] note     team not set. Found: $teams"
      echo "               add to .env.local:  APPLE_DEVELOPMENT_TEAM=<id>"
    else
      echo "[ios] note     a certificate exists but no team id could be read from it"
    fi
  else
    echo "[ios] note     no signing identity — the simulator runs, a physical iPad does not"
    echo "               Xcode > Settings > Accounts > + > Apple ID  (your password;"
    echo "               a free Apple ID gives a Personal Team, good for your own"
    echo "               devices with 7-day profiles). Then: pnpm mobile:ios:team"
  fi

  local found; found="$(attached_devices)"
  if [ -n "$found" ]; then
    echo "$found" | while IFS=$'\t' read -r udid name; do
      echo "[ios] ok       device attached: $name  $udid"
    done
  else
    echo "[ios] note     no physical device attached (plug in the iPad and unlock it)"
  fi

  [ "$ok" -eq 1 ] || fail "prerequisites missing; see above"
  echo "[ios] ready"
}

# Xcode script phases source .xcode.env.local for NODE_BINARY. A versioned
# Homebrew Cellar path there dies at the next `brew upgrade node`, and the
# failure surfaces only in Release builds, where bundling runs during the build
# rather than in Metro. Rewrite it each run to the stable symlink.
sync_node_binary() {
  local node_bin; node_bin="$(command -v node)" || fail "node not found on PATH"
  echo "export NODE_BINARY=$node_bin" > "$IOS/.xcode.env.local"
}

# apps/mobile/ios is generated by `expo prebuild` and gitignored, so the team
# cannot simply live in the checked-in project — a --clean prebuild drops it.
# Patch it in on every run instead. Idempotent.
sync_team() {
  local team="$1"
  local pbx="$IOS/$SCHEME.xcodeproj/project.pbxproj"
  [ -f "$pbx" ] || fail "no Xcode project at $pbx — run a prebuild first"

  if grep -q "DEVELOPMENT_TEAM = " "$pbx"; then
    sed -i '' "s/DEVELOPMENT_TEAM = [A-Z0-9]*;/DEVELOPMENT_TEAM = $team;/g" "$pbx"
  else
    # Anchored on the entitlements line, which appears once per build
    # configuration of the app target and nowhere else.
    sed -i '' "s|\(CODE_SIGN_ENTITLEMENTS = $SCHEME/$SCHEME.entitlements;\)|\1\\
				CODE_SIGN_STYLE = Automatic;\\
				DEVELOPMENT_TEAM = $team;|g" "$pbx"
  fi
  grep -q "DEVELOPMENT_TEAM = $team;" "$pbx" || fail "could not set DEVELOPMENT_TEAM in $pbx"
}

# Value of a key in apps/mobile/.env.local, the file Expo itself reads.
app_env() {
  [ -f "$APP/.env.local" ] || return 0
  sed -n "s/^$1=//p" "$APP/.env.local" | tail -1 | tr -d '"'"'"' '
}

# App Transport Security refuses cleartext HTTP, and a Tailscale MagicDNS name
# is not "local networking" as ATS defines it — that covers .local and
# link-local only. So an http://…ts.net bridge fails before a socket is even
# opened, which looks identical to the server being down: no connection, no
# error on the wire. Narrow the exception to the one host the bridge runs on
# rather than reopening cleartext everywhere.
#
# Info.plist is regenerated by prebuild, so this is re-applied every run.
# PlistBuddy rather than plutil because its ':' key paths tolerate the dots in
# a hostname, which plutil's '.' paths do not.
sync_ats() {
  local url="${1:-}"
  case "$url" in http://*) ;; *) return 0 ;; esac

  local host="${url#http://}"; host="${host%%/*}"; host="${host%%:*}"
  [ -n "$host" ] || return 0

  local plist="$IOS/$SCHEME/Info.plist"
  [ -f "$plist" ] || fail "no Info.plist at $plist"
  local pb=/usr/libexec/PlistBuddy
  local key=":NSAppTransportSecurity:NSExceptionDomains:$host"

  "$pb" -c "Delete $key" "$plist" >/dev/null 2>&1 || true
  "$pb" -c "Add $key dict" "$plist" >/dev/null ||
    fail "could not add an ATS exception for $host"
  "$pb" -c "Add $key:NSExceptionAllowsInsecureHTTPLoads bool true" "$plist" >/dev/null ||
    fail "could not allow cleartext to $host"
  echo "[ios] note     ATS exception added for cleartext HTTP to $host"
}

run() {
  # In a subshell so `fail` ends the probe rather than the script, letting the
  # second call print the diagnosis it just swallowed.
  ( check ) >/dev/null 2>&1 || { check; exit 1; }
  resolve_xcode || fail "Xcode not found"

  local team="${APPLE_DEVELOPMENT_TEAM:-}"
  if [ -z "$team" ]; then
    team="$(discovered_teams | head -1)"
    [ -n "$team" ] || fail "no signing team. Run: pnpm mobile:ios:team"
    echo "[ios] note     APPLE_DEVELOPMENT_TEAM unset; using discovered team $team"
  fi

  # An explicit udid wins; otherwise require exactly one attached device so a
  # second iPad is never picked silently.
  local udid="${1:-}"
  if [ -z "$udid" ]; then
    local found; found="$(attached_devices)"
    local count; count="$(printf '%s' "$found" | grep -c . || true)"
    [ "$count" -eq 0 ] && fail "no device attached. Plug in the iPad, unlock it, and trust this Mac."
    [ "$count" -gt 1 ] && { echo "$found" >&2; fail "more than one device attached; pass a udid"; }
    udid="$(printf '%s' "$found" | cut -f1)"
  fi

  sync_node_binary
  sync_team "$team"
  sync_ats "$(app_env EXPO_PUBLIC_TOLARIA_DEV_VAULT_URL)"

  local dd="$IOS/build/device"
  local app="$dd/Build/Products/Release-iphoneos/$SCHEME.app"

  # Upstream's Release build uploads source maps to Sentry and fails the build
  # without SENTRY_ORG, SENTRY_PROJECT and a token. A personal device build has
  # no Sentry project, so skip the upload unless the caller asks for it.
  export SENTRY_DISABLE_AUTO_UPLOAD="${SENTRY_DISABLE_AUTO_UPLOAD:-true}"

  echo "[ios] building $SCHEME (Release) for $udid, team $team"
  # Release rather than Debug: the JS bundle is embedded, so the app runs on
  # the iPad with no Metro server on this machine.
  ( cd "$IOS" && LANG=en_US.UTF-8 xcodebuild \
      -workspace "$SCHEME.xcworkspace" -scheme "$SCHEME" \
      -configuration Release -destination "id=$udid" \
      -derivedDataPath "$dd" -allowProvisioningUpdates build ) \
    || fail "build failed"

  echo "[ios] installing"
  xcrun devicectl device install app --device "$udid" "$app" >/dev/null || fail "install failed"

  echo "[ios] launching"
  local out; out="$(mktemp -t tolaria-ios)"
  set +e
  xcrun devicectl device process launch --device "$udid" "$BUNDLE_ID" >"$out" 2>&1
  local status=$?
  set -e

  # A locked device refuses the launch before it ever checks the signature, so
  # this must be tested first — otherwise a locked iPad reads as a trust problem
  # and sends you to Settings for nothing.
  if grep -q "could not be, unlocked" "$out"; then
    echo
    echo "[ios] The app INSTALLED but iOS refused to launch it: the iPad is locked."
    echo "      Unlock it and re-run this command, or just tap Tolaria."
    rm -f "$out"
    exit 1
  fi

  if grep -q "has not been explicitly trusted by the user" "$out"; then
    local cert; cert="$(security find-identity -v -p codesigning 2>/dev/null |
      sed -n "s/.*\"\(Apple Develop[^\"]*\)\".*/\1/p" | head -1)"
    echo
    echo "[ios] The app INSTALLED but iOS refused to launch it."
    echo "      A Personal Team is untrusted until you say otherwise, once per device:"
    echo "        iPad > Settings > General > VPN & Device Management"
    echo "        > ${cert:-Apple Development: <your Apple ID>} > Trust"
    echo "      The iPad needs internet access to verify the certificate."
    echo "      Then tap Tolaria on the home screen, or re-run this command."
    rm -f "$out"
    exit 1
  fi

  cat "$out"; rm -f "$out"
  [ "$status" -eq 0 ] || exit "$status"

  # Free Personal Team profiles last 7 days; say so while it is still working.
  local expiry
  expiry="$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null |
    plutil -extract ExpirationDate raw - 2>/dev/null || true)"
  [ -n "$expiry" ] && echo "[ios] note     provisioning profile expires $expiry — rebuild after that"
  echo "[ios] running on device"
}

case "$CMD" in
  check) check ;;
  team)
    teams="$(discovered_teams)"
    if [ -z "$teams" ]; then
      echo "[ios] no signing certificate yet." >&2
      echo "      Xcode > Settings > Accounts > + > Apple ID, then open" >&2
      echo "      apps/mobile/ios/$SCHEME.xcworkspace once so Xcode issues one." >&2
      exit 1
    fi
    echo "[ios] team id(s) found:"
    echo "$teams" | sed 's/^/        /'
    echo "[ios] add the one you want to .env.local:"
    echo "        APPLE_DEVELOPMENT_TEAM=$(echo "$teams" | head -1)"
    ;;
  run) run "$@" ;;
  *) fail "unknown command '$CMD' (check|team|run)" ;;
esac
