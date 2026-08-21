#!/bin/bash
# reset-ag2space-tcc.sh — inspect and reset macOS TCC (privacy) grants for AG2 Space.
#
# Why this exists: a grant that LOOKS on in System Settings can be bound to a previous
# build's identity after an in-place update. The preflight then returns false permanently
# and no amount of re-toggling fixes it. The fix is to remove the row and let the app
# re-prompt. This script does that, and — just as importantly — tells you whether that is
# even your problem before you change anything.
#
# Default mode is INSPECT (reads only, changes nothing). Resetting requires --reset.
#
# Usage:
#   ./reset-ag2space-tcc.sh                 # inspect: report what's actually granted
#   ./reset-ag2space-tcc.sh --reset         # reset the default services (asks first)
#   ./reset-ag2space-tcc.sh --reset --yes   # no prompt (for scripted/remote use)
#   ./reset-ag2space-tcc.sh --reset --dry-run
#   ./reset-ag2space-tcc.sh --reset --services "Accessibility ScreenCapture"
#   ./reset-ag2space-tcc.sh --reset --bundle other.bundle.id

set -uo pipefail

BUNDLE="space.ag2.app"
APP_NAME="AG2 Space"
DEFAULT_SERVICES="Accessibility ScreenCapture ListenEvent PostEvent Microphone Camera"
SERVICES=""
MODE="inspect"
ASSUME_YES=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --reset)    MODE="reset" ;;
    --inspect)  MODE="inspect" ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    --services) SERVICES="${2:-}"; shift ;;
    --bundle)   BUNDLE="${2:-}"; shift ;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$SERVICES" ] || SERVICES="$DEFAULT_SERVICES"

b()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
hm() { printf '  \033[33m•\033[0m %s\n' "$1"; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script only applies to macOS." >&2; exit 2
fi

# ---------------------------------------------------------------- inspect

APP_PATH=""
if [ "$BUNDLE" = "space.ag2.app" ]; then
  for p in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    [ -d "$p" ] && { APP_PATH="$p"; break; }
  done
fi
if [ -z "$APP_PATH" ]; then
  APP_PATH="$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE'" 2>/dev/null | head -1)"
fi
# Track the app that actually owns $BUNDLE. Without this, --bundle would retarget the reset
# while quit/relaunch still acted on AG2 Space — i.e. quit the wrong app.
if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
  APP_NAME="$(basename "$APP_PATH" .app)"
fi

b "App"
if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
  ok "found: $APP_PATH"
  found_id="$(defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null)"
  if [ "$found_id" = "$BUNDLE" ]; then
    ok "bundle id: $BUNDLE"
  else
    no "bundle id mismatch: app says '${found_id:-unknown}', this script targets '$BUNDLE'"
    hm "a reset aimed at the wrong id silently does nothing — re-run with --bundle '${found_id}'"
  fi
  # Signing identity is reported because it rules a whole class OUT: if the app is
  # correctly signed and notarised, no amount of re-granting fixes a permission problem.
  sig="$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F'= *' '/^Authority=/{print $2; exit}')"
  [ -n "$sig" ] && ok "signed by: $sig" || hm "no signing authority found (unsigned or unreadable)"
else
  no "$APP_NAME not found in /Applications or ~/Applications"
  hm "install it before resetting — tccutil needs a real, installed bundle id"
fi

# One detection, used by both the report and the quit-wait. AG2 Space's executable is named
# `cinny`, not the app name, so `pgrep -x "AG2 Space"` never matches — a quit-wait using only
# that form reports "quit" on its first pass while the app is still running.
app_pids() {
  local p
  p="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
  [ -z "$p" ] && p="$(pgrep -f "${APP_PATH:-/$APP_NAME.app}/Contents/MacOS/" 2>/dev/null || true)"
  printf '%s' "$p"
}

b "Is it running?"
PIDS="$(app_pids)"
if [ -n "$PIDS" ]; then
  hm "running (pid: $(echo $PIDS | tr '\n' ' '))"
  hm "a grant NEVER reaches an already-running process — macOS reads it once at launch,"
  hm "so 'flip the toggle and go back to the app' is expected to fail. It needs ⌘Q + reopen."
else
  ok "not running"
fi

b "What the app itself sees"
# Read the app's own view, not this shell's. TCC is per-process: checking from a terminal
# reports the TERMINAL's grants, which is the single most common way this gets misdiagnosed.
STATUS_FILE="$HOME/Library/Application Support/$BUNDLE/workspace/state/permission-status.json"
if [ -f "$STATUS_FILE" ]; then
  ok "status file: $STATUS_FILE"
  printf '    %s\n' "$(cat "$STATUS_FILE")"
  obs="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("observed_at",0))' "$STATUS_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  # A healthy app rewrites this file every few seconds, so age is what says whether the
  # values below are evidence at all. Unknown age counts as stale: fail closed.
  STATUS_STALE=1
  AGE_MIN="unknown"
  AGE_PHRASE="of unknown age"
  if [ "${obs:-0}" -gt 0 ]; then
    age=$(( now - obs ))
    AGE_MIN="$(( age / 60 ))"
    AGE_PHRASE="${AGE_MIN} min old"
    if [ "$age" -lt 60 ]; then
      STATUS_STALE=0
      ok "written ${age}s ago — the app is running and this is CURRENT"
    else
      hm "written ${age}s ago (${AGE_MIN} min) — the app is not updating it now, so this is a"
      hm "snapshot from its last run, not live truth. Launch the app and re-run to get a live read."
      if [ -n "$PIDS" ]; then
        no "the app is RUNNING but has not written this file for ${AGE_MIN} min"
        hm "a live app rewrites it every few seconds, so the permission writer is not running."
        hm "That is the finding — not a permissions result. ⌘Q + reopen, then re-run this script."
      fi
    fi
  else
    hm "no observed_at in the file — treating it as NOT current"
  fi
  acc="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("accessibility_granted"))' "$STATUS_FILE" 2>/dev/null || echo unknown)"
  case "$acc" in
    True|true)  ok "accessibility_granted = true (as the APP sees it)" ;;
    False|false)
      if [ "${STATUS_STALE:-1}" -eq 0 ]; then
        no "accessibility_granted = FALSE (as the APP sees it, and this reading is CURRENT)"
        hm "If System Settings shows the Accessibility toggle ON while this says false, that is a"
        hm "stale TCC row — the fix is REMOVE, not toggle. Run this script with --reset."
      else
        no "accessibility_granted = FALSE — but from a reading ${AGE_PHRASE}, NOT from now"
        hm "This is what the app believed at its last write. It is not evidence about the current"
        hm "grant, so do NOT conclude a stale TCC row and do NOT run --reset on the strength of it."
        hm "⌘Q the app, reopen, wait ~10s, re-run this script. Only act once the line above says"
        hm "the reading is CURRENT — resetting now may clear a grant that is already correct."
      fi ;;
    *) hm "accessibility_granted not present in the file" ;;
  esac
  hm "note: this file reports accessibility only — it does not carry screen-recording or mic state"
else
  no "no status file at $STATUS_FILE"
  hm "either the app has never run as this user, or it isn't writing it — that is itself a finding"
fi

b "TCC database rows"
# Reading TCC.db needs Full Disk Access for THIS process. Report which case you're in
# rather than reporting an empty list as if it meant 'no rows'.
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [ ! -f "$TCC_DB" ]; then
  hm "no user TCC.db at $TCC_DB"
elif rows="$(sqlite3 "file:$TCC_DB?mode=ro" \
      "select service, auth_value from access where client='$BUNDLE' order by service;" 2>/dev/null)"; then
  if [ -n "$rows" ]; then
    ok "rows for $BUNDLE (auth_value: 0=denied, 2=allowed, 3=limited):"
    printf '    %s\n' $(echo "$rows" | tr '\n' ' ')
  else
    ok "readable, and there are NO rows for $BUNDLE (never granted, or already reset)"
  fi
else
  hm "cannot read TCC.db — this process lacks Full Disk Access. That is NOT evidence of no rows;"
  hm "it means this check could not run. Grant Terminal Full Disk Access to enable it, or rely on"
  hm "the app's own status file above, which needs no special access."
fi

if [ "$MODE" = "inspect" ]; then
  b "Nothing was changed"
  echo "  Inspect mode only. To reset:  $0 --reset"
  exit 0
fi

# ---------------------------------------------------------------- reset

b "Reset plan"
echo "  bundle:   $BUNDLE"
echo "  services: $SERVICES"
echo
echo "  This REMOVES the approval rows, so AG2 Space will have to ask again. It cannot"
echo "  grant anything — only macOS can, and only when the app next asks you."
echo "  It does not edit TCC.db directly (that needs SIP disabled, and is not worth it)."

if [ "$DRY_RUN" -eq 1 ]; then
  b "Dry run — commands that WOULD run"
  for s in $SERVICES; do echo "  tccutil reset $s $BUNDLE"; done
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '\n  Proceed? [y/N] '
  read -r reply </dev/tty || reply=""
  case "$reply" in [yY]*) ;; *) echo "  Aborted; nothing changed."; exit 1 ;; esac
fi

# Quit first. Resetting under a running app leaves it holding the old answer, which is
# exactly the confusing half-state this is meant to clear.
if [ -n "$PIDS" ]; then
  b "Quitting $APP_NAME"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    still="$(app_pids)"
    [ -z "$still" ] && break
  done
  if [ -n "${still:-}" ]; then
    no "still running (pid $still) — quit it by hand, then re-run. Not force-killing it."
    exit 1
  fi
  ok "quit"
fi

b "Resetting"
failed=0
for s in $SERVICES; do
  out="$(tccutil reset "$s" "$BUNDLE" 2>&1)"; rc=$?
  # Classify on rc AND text: tccutil prints 'Successfully reset' at rc=0 even when there
  # was no row to remove, so success here means 'the call was accepted', never 'a stale
  # row existed and is gone'. An unknown service name gives rc=70 / 'Failed to reset'.
  if [ "$rc" -eq 0 ] && [ "${out#Successfully}" != "$out" ]; then
    ok "$s — reset accepted"
  else
    no "$s — $out"
    failed=$(( failed + 1 ))
  fi
done
[ "$failed" -gt 0 ] && hm "$failed service(s) failed; a 'Failed to reset' line usually means an unknown service name"

b "Relaunching"
# Launch via LaunchServices, NOT by executing the binary from this shell. A GUI app started
# by `open` is launched by launchd and gets its own TCC identity; a binary run as a child of
# Terminal can have grants attributed to Terminal instead of to the app.
if open -b "$BUNDLE" 2>/dev/null || { [ -n "$APP_PATH" ] && open "$APP_PATH"; }; then
  ok "launched"
else
  no "could not launch — open it from Finder / Applications (not from a terminal)"
fi

b "Now do this"
cat <<EOF
  1. The app should prompt for permission as it needs it. Say yes.
  2. If it does NOT prompt, open System Settings → Privacy & Security → Accessibility.
     If AG2 Space is listed, select it and press "−" to remove the row, then reopen the app.
  3. Re-run this script with no arguments to confirm: accessibility_granted should be true
     and written seconds ago.

  Still false after a real re-grant? Then it is not a stale row, and the next thing to check
  is whether the app was ever launched from a terminal — that attributes the grant to the
  terminal, not to AG2 Space. Launch it from Finder and try once more.
EOF
