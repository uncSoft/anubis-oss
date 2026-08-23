#!/bin/bash
# Local benchmark smoke test — exercises the FULL benchmark path (backend
# selection, streaming, metric computation, DB write) against a real local
# LLM server, using the DEBUG-only auto-bench launch hook.
#
# Usage:
#   ./scripts/smoke-bench.sh                       # Ollama, first model
#   ./scripts/smoke-bench.sh "LM Studio" lfm       # backend name substring, model substring
#
# Requires: a Debug build (script builds one if missing), a running backend
# (Ollama at :11434 or `lms server start`), and sqlite3.
set -euo pipefail

BACKEND="${1:-ollama}"
MODEL="${2:-}"
MAX_TOKENS="${3:-300}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="$HOME/Library/Application Support/Anubis/anubis.sqlite"

APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/anubis-*/Build/Products/Debug/anubis.app 2>/dev/null | head -1 || true)
if [[ -z "$APP" ]]; then
    echo "→ No Debug build found — building..."
    (cd "$REPO_DIR/anubis" && xcodebuild -scheme anubis-oss -configuration Debug build -quiet)
    APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/anubis-*/Build/Products/Debug/anubis.app | head -1)
fi

LAST_ID=$(sqlite3 "$DB" "SELECT COALESCE(MAX(id),0) FROM benchmark_session" 2>/dev/null || echo 0)

echo "→ Launching auto-benchmark: backend='$BACKEND' model='$MODEL' max_tokens=$MAX_TOKENS"
pkill -x anubis 2>/dev/null || true
sleep 1
ARGS=(--auto-bench-backend "$BACKEND" --auto-bench-max-tokens "$MAX_TOKENS")
[[ -n "$MODEL" ]] && ARGS+=(--auto-bench-model "$MODEL")
"$APP/Contents/MacOS/anubis" "${ARGS[@]}" >/dev/null 2>&1 &
APP_PID=$!
disown "$APP_PID"   # suppress bash's "Terminated" job notice on cleanup

echo "→ Waiting for a completed session (id > $LAST_ID, up to 180s)..."
for i in $(seq 1 60); do
    ROW=$(sqlite3 "$DB" "SELECT id || '|' || model_name || '|' || status || '|' || round(tokens_per_second,2) || ' tok/s|TTFT ' || round(time_to_first_token,3) || 's|' || completion_tokens || ' tokens' FROM benchmark_session WHERE id > $LAST_ID AND status IN ('completed','failed') LIMIT 1" 2>/dev/null || true)
    [[ -n "$ROW" ]] && break
    sleep 3
done

kill "$APP_PID" 2>/dev/null || true

if [[ -z "${ROW:-}" ]]; then
    echo "✗ SMOKE FAILED: no session completed within 180s (backend down? model missing?)"
    exit 1
fi

echo "  $ROW"
if [[ "$ROW" == *"|failed|"* ]]; then
    echo "✗ SMOKE FAILED: run recorded as failed"
    exit 1
fi

TPS=$(echo "$ROW" | cut -d'|' -f4 | sed 's/ tok\/s//')
if ! python3 -c "import sys; v=float('$TPS'); sys.exit(0 if 0 < v < 2000 else 1)"; then
    echo "✗ SMOKE FAILED: implausible tokens/sec ($TPS)"
    exit 1
fi

echo "✓ Smoke passed."
