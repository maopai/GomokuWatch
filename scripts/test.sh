#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${WATCH_SIMULATOR_ID:-}" ]]; then
  WATCH_SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
items = [d for runtime, devices in json.load(sys.stdin)["devices"].items() if "watchOS" in runtime for d in devices if d.get("isAvailable")]
items.sort(key=lambda d: d.get("state") != "Booted")
if not items: sys.exit("No watchOS simulator available; install a watchOS runtime in Xcode.")
print(items[0]["udid"])
')
fi
xcodebuild test -project GomokuWatch.xcodeproj -scheme GomokuWatch \
  -destination "platform=watchOS Simulator,id=$WATCH_SIMULATOR_ID" \
  -derivedDataPath .build/DerivedData \
  -parallel-testing-enabled NO \
  -only-testing:GomokuWatchTests CODE_SIGNING_ALLOWED=NO "$@"
