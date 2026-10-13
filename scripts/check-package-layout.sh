#!/usr/bin/env bash
# Assert that a kith package ships its CLI as a native Mach-O that works when
# invoked through a symlink, with no shell-wrapper launcher.
#
# This is the shape the supaku/tools cask installs:
#
#   binary "libexec/kith", target: "kith"
#   /opt/homebrew/bin/kith -> /opt/homebrew/Caskroom/kith/<v>/libexec/kith
#
# Usage:
#   bash scripts/check-package-layout.sh <package-root>
#
# <package-root> is a staging dir (`scripts/package.sh stage <dir>`) or a
# directory the release tarball was extracted into. The script never writes
# into <package-root>; symlinks and fixtures live in a temp dir.
#
# Checks:
#   0. Every file the cask installs is present (libexec/ + Kith.app/).
#   1. There is no top-level `kith` launcher in the package.
#   2. libexec/kith is a Mach-O executable according to `file`, not a script.
#   3. Through an absolute symlink from another prefix, a symlink chain, and a
#      bare PATH lookup, `kith version` runs and
#      `kith chats --participant '(415) 555-1111'` over a fixture chat.db
#      (KITH_DB_PATH local mode) returns the +14155551111 chat. That match only
#      happens if PhoneNumberKit parsed the number, which needs
#      libexec/PhoneNumberKit_PhoneNumberKit.bundle, and SQLite.swift opened
#      the database. No Contacts or Messages data is touched.
#   4. Negative control: the same binary copied without its resource bundles
#      must fail the phone probe. This proves the probe depends on the bundle
#      next to the real executable and not on some fallback.
#
# Why the probe hides build-dir bundles first: binaries built by SwiftPM's
# native build system embed an absolute fallback path such as
# /Users/runner/work/kith/kith/.build/arm64-apple-macosx/release/
# PhoneNumberKit_PhoneNumberKit.bundle in the generated `Bundle.module`
# accessor. On the machine that built the binary that path exists, so a
# broken package would still pass. Every absolute .build/…/*.bundle path
# embedded in the binary that exists on disk is renamed for the duration of
# the probe and restored on exit.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: scripts/check-package-layout.sh <package-root>" >&2
  exit 2
fi

PKG="$(cd -- "$1" && pwd -P)"
CLI="$PKG/libexec/kith"
HIDE_SUFFIX=".kith-layout-check-hidden"

WORK="$(mktemp -d)"
HIDDEN=()

restore() {
  local p
  for p in ${HIDDEN[@]+"${HIDDEN[@]}"}; do
    if [[ -e "$p$HIDE_SUFFIX" && ! -e "$p" ]]; then
      mv "$p$HIDE_SUFFIX" "$p"
    fi
  done
  rm -rf "$WORK"
}
trap restore EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- 0. required entries ----------------------------------------------------
echo "==> layout: $PKG"
for needed in libexec/kith \
              libexec/PhoneNumberKit_PhoneNumberKit.bundle \
              libexec/SQLite.swift_SQLite.bundle \
              Kith.app/Contents/Info.plist \
              Kith.app/Contents/MacOS/KithApp \
              Kith.app/Contents/MacOS/KithAgent \
              Kith.app/Contents/Library/LaunchAgents/com.supaku.kith.agent.plist \
              Kith.app/Contents/Resources/PhoneNumberKit_PhoneNumberKit.bundle \
              Kith.app/Contents/Resources/SQLite.swift_SQLite.bundle; do
  [[ -e "$PKG/$needed" ]] || fail "package missing $needed"
done

# --- 1. no wrapper ----------------------------------------------------------
if [[ -e "$PKG/kith" || -L "$PKG/kith" ]]; then
  fail "package has a top-level 'kith' ($(file -b "$PKG/kith")). The cask must link libexec/kith directly; do not ship a launcher."
fi

# --- 2. native Mach-O -------------------------------------------------------
[[ -f "$CLI" && -x "$CLI" ]] || fail "$CLI is not an executable file"
cli_type="$(file -b "$CLI")"
echo "    libexec/kith: $cli_type"
case "$cli_type" in
  *Mach-O*executable*) ;;
  *) fail "libexec/kith is not a Mach-O executable: $cli_type" ;;
esac
if [[ "$(head -c 2 "$CLI")" == "#!" ]]; then
  fail "libexec/kith starts with a shebang; it is a script"
fi

# --- hide build-dir fallbacks embedded in the binary ------------------------
while IFS= read -r embedded; do
  if [[ -e "$embedded" ]]; then
    mv "$embedded" "$embedded$HIDE_SUFFIX"
    HIDDEN+=("$embedded")
    echo "    hid build-dir fallback for the probe: $embedded"
  fi
done < <(strings -a "$CLI" | grep -E '^/.+/\.build/.+\.bundle$' | sort -u || true)

# --- fixture chat.db --------------------------------------------------------
FIXTURE="$WORK/fixture.db"
/usr/bin/sqlite3 "$FIXTURE" <<'SQL'
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, chat_identifier TEXT, guid TEXT, display_name TEXT, service_name TEXT);
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT);
CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, handle_id INTEGER, text TEXT, date INTEGER, is_from_me INTEGER, service TEXT, guid TEXT, associated_message_guid TEXT, associated_message_type INTEGER, attributedBody BLOB, thread_originator_guid TEXT, destination_caller_id TEXT, is_audio_message INTEGER, balloon_bundle_id TEXT);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER, user_info BLOB);
CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
INSERT INTO chat (chat_identifier, guid, display_name, service_name) VALUES ('+14155551111', 'iMessage;-;+14155551111', NULL, 'iMessage');
INSERT INTO handle (id) VALUES ('+14155551111');
INSERT INTO chat_handle_join VALUES (1, 1);
INSERT INTO message (handle_id, text, date, is_from_me, service, guid) VALUES (1, 'hi', 700000000000000000, 0, 'iMessage', 'GUID-A');
INSERT INTO chat_message_join VALUES (1, 1);
SQL

# phone_probe <kith-path> -> prints output, returns kith's exit status, and
# returns 1 when kith exits 0 without the expected chat.
phone_probe() {
  local out status=0
  out="$(KITH_DB_PATH="$FIXTURE" NO_COLOR=1 "$1" chats --participant '(415) 555-1111' --jsonl 2>&1)" || status=$?
  echo "$out"
  if [[ $status -ne 0 ]]; then
    return "$status"
  fi
  [[ "$out" == *'"identifier":"+14155551111"'* ]]
}

# --- 3. symlinked invocation ------------------------------------------------
mkdir -p "$WORK/prefix/bin" "$WORK/chain"
ln -s "$CLI" "$WORK/prefix/bin/kith"                 # brew-style absolute link
ln -s "$WORK/prefix/bin/kith" "$WORK/chain/kith"      # link to a link

linked_type="$(file -bL "$WORK/prefix/bin/kith")"
case "$linked_type" in
  *Mach-O*executable*) ;;
  *) fail "the bin entry does not resolve to a Mach-O executable: $linked_type" ;;
esac

for entry in "$WORK/prefix/bin/kith" "$WORK/chain/kith"; do
  echo "==> $entry -> $(readlink "$entry")"
  "$entry" version >/dev/null || fail "'kith version' failed through $entry"
  phone_probe "$entry" || fail "phone/SQLite probe failed through $entry"
done

echo "==> bare 'kith' on PATH"
PATH="$WORK/prefix/bin:/usr/bin:/bin" phone_probe kith \
  || fail "phone/SQLite probe failed for a PATH lookup of the symlink"

# --- 4. negative control ----------------------------------------------------
echo "==> negative control: binary without its resource bundles must fail"
mkdir -p "$WORK/nobundles/libexec" "$WORK/nobundles/bin"
cp "$CLI" "$WORK/nobundles/libexec/kith"
ln -s "$WORK/nobundles/libexec/kith" "$WORK/nobundles/bin/kith"
if phone_probe "$WORK/nobundles/bin/kith" >/dev/null 2>&1; then
  fail "the probe passed without PhoneNumberKit's bundle; it is not exercising the resource load"
fi
echo "    failed as expected"

echo "==> OK: package complete; native Mach-O CLI, no wrapper; resource bundles resolve through symlinks"
