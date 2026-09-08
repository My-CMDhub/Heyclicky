#!/bin/zsh
# Run the test suite by driving Xcode's own test action.
#
# Why not xcodebuild: it invalidates this app's TCC grants, and the project
# depends on Screen Recording, Accessibility and Microphone being granted to
# the DerivedData build. This is the Cmd+U an operator would press.
#
# Why we watch the .xcresult instead of asking AppleScript: Xcode's scheme
# action result reports "not yet started" as a terminal-looking status, so the
# obvious `repeat until status is not running` exits immediately and reports a
# failure three seconds in. `completed` never flipped either. A new .xcresult
# bundle appearing on disk is the honest signal that the run finished.
set -e

PROJECT_DIRECTORY="${0:A:h:h}"
TEST_LOG_DIRECTORY=$(ls -d ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Logs/Test 2>/dev/null | head -1)

if [[ -z "$TEST_LOG_DIRECTORY" ]]; then
  echo "no DerivedData for leanring-buddy — build once in Xcode first" >&2
  exit 1
fi

bundleBefore=$(ls -dt "$TEST_LOG_DIRECTORY"/*.xcresult 2>/dev/null | head -1)

osascript -e "tell application \"Xcode\"
  open \"$PROJECT_DIRECTORY/leanring-buddy.xcodeproj\"
  set d to workspace document \"leanring-buddy.xcodeproj\"
  repeat until (loaded of d) is true
    delay 1
  end repeat
  test d
end tell" >/dev/null 2>&1 &

for _ in {1..180}; do
  sleep 2
  bundleNow=$(ls -dt "$TEST_LOG_DIRECTORY"/*.xcresult 2>/dev/null | head -1)
  [[ "$bundleNow" == "$bundleBefore" || -z "$bundleNow" ]] && continue
  summary=$(xcrun xcresulttool get test-results summary --path "$bundleNow" 2>/dev/null) || continue
  echo "$summary" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d.get('result'): raise SystemExit(1)
print(f\"{d['result']}: {d['passedTests']} passed, {d['failedTests']} failed, {d['skippedTests']} skipped\")
for failure in d.get('testFailures', []):
    print('  FAIL', failure.get('testName'), '-', failure.get('failureText', '')[:300])
raise SystemExit(0 if d['result'] == 'Passed' else 1)
" && exit 0 || { [[ $? -eq 1 ]] && exit 1; }
done

echo "timed out waiting for a new .xcresult" >&2
exit 1
