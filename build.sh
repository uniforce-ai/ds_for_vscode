#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_path="${1:-$PWD/build/DS Codex SSH.app}"
mkdir -p "$app_path/Contents/MacOS" "$PWD/build/module-cache"
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -O -module-cache-path "$PWD/build/module-cache" \
  -framework AppKit -framework ApplicationServices -framework GameController -framework CoreHaptics \
  -framework AVFoundation -framework Speech -framework Network -framework IOKit \
  Sources/AppLog.swift Sources/LightPattern.swift Sources/HookSignal.swift Sources/CodexPhase.swift Sources/SessionCue.swift Sources/HTTPRequest.swift \
  Sources/HoldState.swift Sources/TriggerGesture.swift Sources/StickNavigation.swift Sources/ConversationGeometry.swift \
  Sources/SendPolicy.swift Sources/DualSenseInput.swift Sources/DualSenseLight.swift Sources/StatusServer.swift Sources/SpeechDictation.swift \
  Sources/ConversationLocator.swift Sources/AppMain.swift \
  -o "$app_path/Contents/MacOS/DSCodexSSH"
cp Info.plist "$app_path/Contents/Info.plist"
xattr -dr com.apple.FinderInfo "$app_path" 2>/dev/null || true
bash "$PWD/script/setup_signing.sh"
codesign --force --sign "DS Codex SSH Signing" --keychain "$HOME/Library/Keychains/ds-codex-ssh.keychain-db" "$app_path"
printf 'Built: %s\n' "$app_path"
