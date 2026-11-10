#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/LightPattern.swift Sources/HookSignal.swift Sources/CodexPhase.swift Sources/SessionCue.swift Sources/HTTPRequest.swift \
  Sources/HoldState.swift Sources/TriggerGesture.swift Sources/StickNavigation.swift Sources/ConversationGeometry.swift \
  Sources/SendPolicy.swift Sources/DualSenseInput.swift Tests/main.swift -o build/logic-tests
./build/logic-tests
