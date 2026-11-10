#!/bin/sh
# Codex hook for the Linux host (or the Mac, if Codex itself runs locally).
# Prints {} immediately so the turn is not delayed or continued.
port="${DS_CODEX_PORT:-8931}"
file=$(mktemp "${TMPDIR:-/tmp}/ds-codex.XXXXXX") || exit 0
cat > "$file"
printf '{}\n'
if command -v curl >/dev/null 2>&1; then
  nohup sh -c 'curl -sf --max-time 2 -H "Content-Type: application/json" --data-binary @"$1" "http://127.0.0.1:$2/event" >/dev/null 2>&1; rm -f "$1"' _ "$file" "$port" >/dev/null 2>&1 &
else
  rm -f "$file"
fi
exit 0
