#!/bin/zsh
# Probe one app N times with the built Clicky and print the spread.
#
# A control app is only a control if it holds still. Measured 2026-09-09,
# System Settings read 177 / 176 / 170 / 170 nodes across four probes — two of
# them the *same binary* minutes apart. An unstable control launders a real
# regression as jitter, and jitter as a regression. Run this before trusting any
# app as a before/after baseline.
#
#   scripts/control-probe.sh "TextEdit" 3
set -e

APP=${1:?usage: control-probe.sh "App Name" [runs]}
RUNS=${2:-3}

REPO=${0:a:h:h}
DD=~/Library/Developer/Xcode/DerivedData/leanring-buddy-eljcrompchcbuefnluulcygynvxh
APP_BUNDLE="$DD/Build/Products/Debug/Clicky.app"
BINARY="$APP_BUNDLE/Contents/MacOS/Clicky"
OUT=/private/tmp/jarvis-ax-action

[[ -x "$BINARY" ]] || { echo "no built Clicky at $BINARY — build from Xcode first"; exit 1 }

# The trap this exists to catch: measuring a binary older than the source that
# is supposed to be under test. Detected, not assumed away by rebuilding.
NEWEST_SOURCE=$(find "$REPO/leanring-buddy" -name '*.swift' -newer "$BINARY" -print -quit)
if [[ -n "$NEWEST_SOURCE" ]]; then
  echo "╔═══════════════════════════════════════════════════════════════════════╗"
  echo "║  POSSIBLY STALE — a source file is newer than the build under test.   ║"
  echo "║  $(basename $NEWEST_SOURCE) is newer than Clicky."
  echo "║  A branch switch updates mtimes too, so this fires without an edit —  ║"
  echo "║  but it never stays quiet when the code HAS changed. Rebuild to be    ║"
  echo "║  sure: measuring a binary that no longer matches the source is the    ║"
  echo "║  cheapest way to get a plausible wrong number.                        ║"
  echo "╚═══════════════════════════════════════════════════════════════════════╝"
fi

# Warm the app first. Measured 2026-09-09: the first probe after an app comes
# forward reads exactly ONE node fewer than every probe after it — Finder 188
# then 189/189, Font Book 372 then 373, Finder on a 700-file folder 817 then
# 818/818/818. That off-by-one is ours, not the app's, and it was about to be
# written down as "no app holds still".
osascript -e "tell application \"$APP\" to activate" -e 'delay 2' >/dev/null 2>&1 || true

echo "app     $APP   ($RUNS runs, warmed)"
echo "binary  $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$BINARY")"
echo "source  $(git -C "$REPO" rev-parse --short HEAD)$(git -C "$REPO" diff --quiet -- leanring-buddy || echo ' +uncommitted')"
echo

for run in $(seq 1 $RUNS); do
  find "$OUT" -name 'probe-*.txt' -delete 2>/dev/null || true
  open -a "$APP_BUNDLE" --args --ax-probe
  osascript -e 'delay 2' -e "tell application \"$APP\" to activate" >/dev/null

  waited=0
  until [[ -n "$(find "$OUT" -name 'probe-*.txt' 2>/dev/null)" ]] || (( waited > 60 )); do
    osascript -e 'delay 1' >/dev/null
    (( waited += 1 ))
  done

  REPORT=$(find "$OUT" -name 'probe-*.txt' -exec cat {} \; 2>/dev/null)
  [[ -n "$REPORT" ]] || { echo "run $run: no report after ${waited}s"; continue }

  # Which window was actually read. Without this the runs are not comparable:
  # a slow activation reads whatever was in front instead, and the numbers look
  # like drift in the app under test.
  WINDOW=$(print -r -- "$REPORT" | sed -n '1p' | sed 's/^window: //')
  MARK=""
  [[ "$WINDOW" == "$APP"* ]] || MARK="   ← WRONG WINDOW ($WINDOW)"
  printf 'run %d  %s%s\n' $run "$(print -r -- "$REPORT" | sed -n '2p')" "$MARK"
done
