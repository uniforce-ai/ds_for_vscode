#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/AppLog.swift Sources/LightPattern.swift Sources/HookSignal.swift Sources/CodexPhase.swift Sources/SessionCue.swift Sources/RemoteLightBridge.swift Sources/HTTPRequest.swift \
  Sources/HoldState.swift Sources/TriggerGesture.swift Sources/StickNavigation.swift Sources/ConversationGeometry.swift \
  Sources/SendPolicy.swift Sources/DualSenseInput.swift Tests/main.swift -o build/logic-tests
./build/logic-tests
root=$(mktemp -d)
mkdir -p "$root/sessions/2026/11/10"
printf '%s\n' '{"timestamp":"2026-11-10T03:20:19.910Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"secret"}}' > "$root/sessions/2026/11/10/rollout.jsonl"
CODEX_HOME="$root" DS_CODEX_FOLLOW_ONCE=1 python3 hooks/remote-session-follow.py > "$root/out"
grep -q '"turn_id":"t1"' "$root/out"
if grep -q secret "$root/out"; then
  echo "remote follower leaked message text" >&2
  exit 1
fi
rm -rf "$root"
echo "Remote session follower passed."
