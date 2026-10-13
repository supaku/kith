#!/usr/bin/env bash
# Local end-to-end release rehearsal — run before pushing a tag.
#
# Three modes, picked by env var (cheapest first):
#
#   default                       fast: build, package, smoke. No signing,
#                                 no notarize. Catches packaging bugs but
#                                 NOT TCC / first-run / Gatekeeper bugs.
#
#   KITH_REHEARSE_DEV_SIGN=1      adds Developer ID signing in place. Lets
#                                 us register the LaunchAgent (SecureXPC's
#                                 MachService rejects ad-hoc-signed) but
#                                 the .app is still spctl-rejected, so TCC
#                                 prompts auto-deny.
#
#   KITH_REHEARSE_NOTARIZE=1      runs the FULL release pipeline: dev
#                                 sign + scripts/sign-and-notarize.sh
#                                 (which submits to Apple's notary +
#                                 staples the .app). 5–15 min round trip.
#                                 Sources .env.local for the secrets.
#                                 After staple, asserts spctl reports
#                                 "Notarized Developer ID". This is the
#                                 only mode that reproduces production-
#                                 install behavior — use it when you've
#                                 touched TCC, the bundle layout, signing
#                                 identifiers, or anything around the
#                                 first-run UX. Implies KITH_REHEARSE_AGENT
#                                 unless the caller turns it off
#                                 explicitly.
#
#   KITH_REHEARSE_SIGN=1          legacy alias for "run sign-and-notarize
#                                 with KITH_SKIP_NOTARIZE=1" — exercises
#                                 the inside-out codesign flow without the
#                                 network round-trip. Kept because the CI
#                                 dry-run uses it.
#
#   KITH_REHEARSE_AGENT=1         install the staged Kith.app to
#                                 ~/Applications, register its LaunchAgent,
#                                 verify XPC round-trip via `kith doctor`.
#                                 Independent of the signing modes.
#
# scripts/check-package-layout.sh (phone-parse probe through a symlink) catches
# missing SwiftPM resource bundles — the failure mode that made it past
# v0.1.0 — and a shell wrapper creeping back into the package. Keep it.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Cleanup hook — runs on success AND failure (via EXIT trap).
#
# The rehearsal's _AGENT step installs a dev/notarized Kith.app to
# ~/Applications and registers its LaunchAgent. If we leave it sitting
# there, the next `brew install --cask kith` lays down a NEW
# /Applications/Kith.app but the old LaunchAgent registration keeps
# routing XPC to the rehearsal install — except that bundle's been wiped
# from disk on subsequent reruns, so launchd is sometimes serving a
# zombie KithAgent process whose signing identity no longer matches the
# brew-installed CLI. Symptom: `kith find` after a `brew install` fails
# with "agent rejected client (code-signature mismatch)" until the user
# manually boots it out.
#
# Set KITH_REHEARSE_KEEP_INSTALL=1 to skip cleanup (e.g., when you want
# to poke at the staged install in System Settings).
cleanup_rehearsal_install() {
  # Always clean up the temp extract dir if we made one.
  if [[ -n "${EXTRACT_DIR:-}" ]]; then
    rm -rf "$EXTRACT_DIR" 2>/dev/null || true
  fi

  if [[ "${KITH_REHEARSE_KEEP_INSTALL:-0}" == "1" ]]; then
    echo "skip cleanup: KITH_REHEARSE_KEEP_INSTALL=1 set; rehearsal install left at ~/Applications/Kith.app"
    return 0
  fi
  # Only do agent cleanup if the rehearsal actually touched the
  # LaunchAgent / ~/Applications. Otherwise we'd churn other people's
  # state for nothing.
  if [[ "${KITH_REHEARSE_AGENT:-0}" != "1" && "${KITH_REHEARSE_NOTARIZE:-0}" != "1" ]]; then
    return 0
  fi
  echo
  echo "==> cleanup: bootout LaunchAgent + remove ~/Applications/Kith.app"
  /bin/launchctl bootout "gui/$UID/com.supaku.kith.agent" 2>/dev/null || true
  rm -rf "$HOME/Applications/Kith.app" 2>/dev/null || true
  # Pull any zombie KithAgent processes the bootout missed (file handles
  # held even after the bundle was rm'd).
  for pid in $(pgrep -f "Contents/MacOS/KithAgent" 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  echo "    cleanup done. (Set KITH_REHEARSE_KEEP_INSTALL=1 to keep the install next time.)"
}
trap cleanup_rehearsal_install EXIT

# shellcheck source=/dev/null
source version.env

STAGE="$REPO_ROOT/dist/staging"
ARCHIVE="dist/kith-${KITH_VERSION}-macos-arm64.tar.gz"

DEV_ID="${KITH_DEV_IDENTITY:-Developer ID Application: Mark Kropf (BDJC7XF394)}"

echo "==> swift build -c release --arch arm64"
swift build -c release --arch arm64

echo "==> stage Kith.app + CLI to $STAGE"
bash scripts/package.sh stage "$STAGE"

if [[ "${KITH_REHEARSE_DEV_SIGN:-0}" == "1" ]]; then
  echo "==> KITH_REHEARSE_DEV_SIGN=1 — sign Kith.app + CLI with local Developer ID"
  echo "    identity: $DEV_ID"
  # Unified identifier + entitlements: see scripts/sign-and-notarize.sh
  # for the rationale (TCC needs the addressbook entitlement to even
  # display its prompt under hardened runtime).
  ENTITLEMENTS="$REPO_ROOT/Sources/KithApp/Resources/Entitlements.plist"
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" \
    "$STAGE/Kith.app/Contents/MacOS/KithAgent"
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" \
    "$STAGE/Kith.app/Contents/MacOS/KithApp"
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" \
    "$STAGE/Kith.app"
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" \
    "$STAGE/libexec/kith"
  codesign --verify --deep --strict "$STAGE/Kith.app"
  codesign --verify "$STAGE/libexec/kith"
fi

if [[ "${KITH_REHEARSE_SIGN:-0}" == "1" ]]; then
  echo "==> rehearse full sign (KITH_SKIP_NOTARIZE=1, no network round-trip)"
  KITH_SKIP_NOTARIZE=1 bash scripts/sign-and-notarize.sh "$STAGE"
fi

if [[ "${KITH_REHEARSE_NOTARIZE:-0}" == "1" ]]; then
  echo "==> KITH_REHEARSE_NOTARIZE=1 — full sign + notarize + staple"
  if [[ ! -f "$REPO_ROOT/.env.local" ]]; then
    echo "FAIL: $REPO_ROOT/.env.local missing — that's where the Apple notary" >&2
    echo "      secrets live (APPLE_DEVELOPER_ID, APPLE_PASSWORD, APPLE_TEAM_ID," >&2
    echo "      APPLE_DEVELOPER_ID_CERT_BASE64, APPLE_DEVELOPER_ID_CERT_PASSWORD)." >&2
    exit 1
  fi
  # Source .env.local with auto-export so scripts/sign-and-notarize.sh's
  # subprocess inherits the secrets. Keep the variables out of the parent
  # shell's history by running this in a subshell-style block.
  set -a
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.env.local"
  set +a
  for var in APPLE_DEVELOPER_ID_CERT_BASE64 APPLE_DEVELOPER_ID_CERT_PASSWORD \
             APPLE_DEVELOPER_ID APPLE_PASSWORD APPLE_TEAM_ID; do
    if [[ -z "${!var:-}" ]]; then
      echo "FAIL: $var not set after sourcing .env.local — check the file" >&2
      exit 1
    fi
  done

  echo "==> running sign-and-notarize.sh end-to-end (5–15 min for notarytool)"
  bash scripts/sign-and-notarize.sh "$STAGE"

  echo "==> assert spctl recognizes Kith.app as notarized"
  spctl_out="$(spctl --assess --type execute --verbose "$STAGE/Kith.app" 2>&1)"
  echo "$spctl_out"
  if ! echo "$spctl_out" | grep -q "Notarized Developer ID"; then
    echo "FAIL: post-staple Kith.app not seen as notarized by spctl. Above is the assess output." >&2
    exit 1
  fi
  echo "    spctl: $(echo "$spctl_out" | head -1)"

  # KITH_REHEARSE_NOTARIZE implies the agent path — the whole point of
  # notarizing is to verify TCC prompts fire from a real notarized .app.
  # Caller can set KITH_REHEARSE_AGENT=0 explicitly if they want to skip.
  if [[ -z "${KITH_REHEARSE_AGENT+x}" ]]; then
    KITH_REHEARSE_AGENT=1
  fi
fi

echo "==> tarball"
bash scripts/package.sh tarball "$STAGE" "$ARCHIVE"

EXTRACT="$(mktemp -d)"
# DON'T overwrite the EXIT trap — that would clobber cleanup_rehearsal_install.
# Compose: the cleanup function handles BOTH the temp extract dir and the
# ~/Applications install state. Single trap, single cleanup point.
EXTRACT_DIR="$EXTRACT"
tar -C "$EXTRACT" -xzf "$ARCHIVE"

# Verify the layout the cask installs. The cask links libexec/kith straight
# onto PATH (/opt/homebrew/bin/kith -> Caskroom/kith/<v>/libexec/kith).
# check-package-layout.sh asserts every installed entry is present, there is
# no wrapper, libexec/kith is a Mach-O, and the phone-parse + SQLite probe
# passes through symlinks. It also runs a negative control without the
# resource bundles, so a missing REQUIRED_BUNDLES entry fails here.
echo "==> check-package-layout.sh against the extracted tarball"
bash scripts/check-package-layout.sh "$EXTRACT"

# Brew-style link for the agent steps below.
ln -s "$EXTRACT/libexec/kith" "$EXTRACT/kith-link"

# ---- Optional: bootstrap Kith.app + verify against the live agent -----------
if [[ "${KITH_REHEARSE_AGENT:-0}" == "1" ]]; then
  echo "==> KITH_REHEARSE_AGENT=1 — installing Kith.app to ~/Applications"
  USER_APPS="$HOME/Applications"
  mkdir -p "$USER_APPS"
  # Boot out any prior registration so we exercise the full register path.
  /bin/launchctl bootout "gui/$UID/com.supaku.kith.agent" 2>/dev/null || true
  rm -rf "$USER_APPS/Kith.app"
  cp -R "$STAGE/Kith.app" "$USER_APPS/Kith.app"

  echo "==> launching Kith.app (register LaunchAgent)"
  # KithApp.register fires a Contacts TCC prompt as part of its register
  # flow on macOS 14+. The local-dev-signed (unnotarized) build is
  # spctl-rejected, so the prompt is auto-denied and the .app exits
  # quickly — that's expected here. In production (notarized) the prompt
  # actually shows. We only care about whether the agent registered.
  /usr/bin/open -a "$USER_APPS/Kith.app" --args register

  # Poll launchctl print up to ~10s — SMAppService.register() can take a
  # second on busy systems, and we don't want a flaky 3s sleep.
  registered=0
  for _ in $(seq 1 20); do
    if /bin/launchctl print "gui/$UID/com.supaku.kith.agent" >/dev/null 2>&1; then
      registered=1
      break
    fi
    sleep 0.5
  done
  if [[ "$registered" != "1" ]]; then
    echo "FAIL: com.supaku.kith.agent not registered with launchd within 10s." >&2
    echo "      Common cause: Kith.app isn't signed with a Developer ID. Re-run with" >&2
    echo "      KITH_REHEARSE_DEV_SIGN=1 to sign locally." >&2
    exit 1
  fi
  echo "    com.supaku.kith.agent registered."

  # The CLI's auto-bootstrap targets /Applications/Kith.app by default;
  # KITH_BOOTSTRAP_APP_PATH overrides that for the rehearsal.
  echo "==> kith doctor --json (verifies XPC reachability, ignores perm grants)"
  doctor_json="$(KITH_BOOTSTRAP_APP_PATH="$USER_APPS/Kith.app" "$EXTRACT/kith-link" doctor --json 2>/dev/null || true)"
  if ! echo "$doctor_json" | grep -q '"reachable"[[:space:]]*:[[:space:]]*true'; then
    echo "FAIL: agent not reachable per kith doctor --json" >&2
    echo "$doctor_json" | head -40 >&2
    exit 1
  fi
  if ! echo "$doctor_json" | grep -q "\"version\"[[:space:]]*:[[:space:]]*\"${KITH_VERSION}\""; then
    echo "WARN: agent's reported version doesn't match KITH_VERSION=${KITH_VERSION} (stale install?)" >&2
  fi
  echo "    agent reachable; XPC round-trip OK."

  # Notarized .app should be able to display TCC prompts. The strongest
  # automated check we can do without interactive user input: scrape
  # tccd's log AFTER the request to look for the smoking-gun "Policy
  # disallows prompt" entry that fires when an entitlement is missing
  # (the v0.2.2 bug). Either of two outcomes is acceptable: prompt
  # actually shown (user can click Allow / Don't Allow), OR pre-existing
  # grant state (granted/denied) returned without prompting. What we
  # reject: silent auto-deny because the entitlement is missing.
  if [[ "${KITH_REHEARSE_NOTARIZE:-0}" == "1" ]]; then
    echo "==> verify TCC prompt path is reachable on notarized .app"
    echo "    A 'Kith would like to access your Contacts' prompt MAY appear."
    echo "    (Click Allow / Don't Allow as you wish; the rehearsal only"
    echo "    asserts the prompt path is unblocked, not the user's choice.)"
    rehearsal_marker_start="$(date '+%Y-%m-%d %H:%M:%S')"
    KITH_BOOTSTRAP_APP_PATH="$USER_APPS/Kith.app" "$EXTRACT/kith-link" \
      find --name "kith-rehearsal-impossible-name-$$" --jsonl --limit 1 \
      >/dev/null 2>&1 || true
    sleep 2  # let tccd flush its log
    tcc_log="$(/usr/bin/log show --start "$rehearsal_marker_start" --predicate 'process == "tccd"' --info 2>/dev/null || true)"
    if echo "$tcc_log" | grep -q "Policy disallows prompt.*com.supaku.kith"; then
      echo "FAIL: tccd refused to display Contacts prompt — entitlement likely missing." >&2
      echo "      Look for 'requires entitlement com.apple.security.personal-information.addressbook'" >&2
      echo "      in the tccd log. The fix is to sign Kith.app + KithAgent + KithApp with that" >&2
      echo "      entitlement; see Sources/KithApp/Resources/Entitlements.plist." >&2
      echo "$tcc_log" | grep -iE "kith|entitlement|disallow" | head -20 >&2
      exit 1
    fi
    echo "    TCC prompt path OK (tccd accepted the request; no entitlement violation)."
  fi
else
  echo
  echo "skip: agent round-trip rehearsal (set KITH_REHEARSE_AGENT=1 to run; mutates your LaunchAgent registry)"
  echo "      For the agent path to actually work you'll need KITH_REHEARSE_DEV_SIGN=1"
  echo "      so Kith.app + CLI are signed with a Developer ID identity."
  echo "      To verify TCC prompts (first-run UX), use KITH_REHEARSE_NOTARIZE=1 —"
  echo "      slow (5–15 min), but the only mode that exercises Gatekeeper / TCC."
fi

echo
echo "==> rehearsal passed for kith ${KITH_VERSION}"
echo "    OK to: git tag -a v${KITH_VERSION} -m 'kith ${KITH_VERSION}' && git push origin v${KITH_VERSION}"
