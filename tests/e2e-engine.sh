#!/bin/bash
# End-to-end engine test for CI (clean macOS arm64 runner — not a user machine):
#  1. fetch the exact pinned llama.cpp build the app ships with
#  2. download a small Qwen3-4B Q4 model
#  3. start llama-server with the app's exact flags
#  4. verify a real chat round-trip in the app's request shape (thinking on, low effort)
set -euo pipefail

DIR="$HOME/.dot/ci-test"
rm -rf "$DIR"
mkdir -p "$DIR/eng"
BUILD="b11564"   # MUST match EngineManager.engineBuild in src/Engine.swift

# On failure, best-effort push the logs to a ci-diag branch: unauthenticated API
# calls cannot read job logs, so this makes any failure legible from a git clone.
push_diag() {
  [ -n "${GITHUB_TOKEN:-}" ] || return 0
  [ -n "${GITHUB_WORKSPACE:-}" ] || return 0
  [ -d "$GITHUB_WORKSPACE/.git" ] || return 0
  (
    cd "$GITHUB_WORKSPACE"
    git config user.email "dot-ci@github" >/dev/null
    git config user.name "Dot CI" >/dev/null
    git checkout -qB ci-diag >/dev/null 2>&1 || git checkout -q ci-diag >/dev/null 2>&1
    mkdir -p diag
    cp "$DIR"/eng.log diag/ 2>/dev/null || true
    cp "$DIR"/chat.log diag/ 2>/dev/null || true
    cp "$DIR"/fetch.log diag/ 2>/dev/null || true
    git add -A diag >/dev/null 2>&1
    git commit -q -m "ci diagnostics $(date -u +%s)" >/dev/null 2>&1
    git push -qf "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" ci-diag >/dev/null 2>&1 || true
    git checkout -q main >/dev/null 2>&1 || true
  ) >/dev/null 2>&1
  return 0
}
die() {
  echo "FAIL: $*"
  [ -f "$DIR/eng.log" ] && tail -30 "$DIR/eng.log" || true
  push_diag
  exit 1
}

echo "▸ fetching llama.cpp engine ($BUILD — same pinned build the app downloads)"
URL="https://github.com/ggml-org/llama.cpp/releases/download/$BUILD/llama-$BUILD-bin-macos-arm64.tar.gz"
curl -fsSL "$URL" -o "$DIR/llama.tar.gz" 2>"$DIR/fetch.log" || { cat "$DIR/fetch.log" || true; die "engine download failed"; }
[ -s "$DIR/llama.tar.gz" ] || die "engine download empty"
tar xzf "$DIR/llama.tar.gz" -C "$DIR/eng" || die "engine extract failed"
chmod +x "$DIR/eng/$BUILD/llama-server" || die "llama-server missing after extract"
SERVER="$DIR/eng/$BUILD/llama-server"

echo "▸ downloading Qwen3-4B Q4_K_M (~2.5 GB)"
curl -fsSL --http1.1 -o "$DIR/q4b.gguf" \
  "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true" 2>"$DIR/fetch.log" \
  || die "model download failed"
SZ=$(stat -f%z "$DIR/q4b.gguf")
[ "$SZ" -gt 1000000000 ] || die "model download too small ($SZ bytes — probably an error page)"

echo "▸ starting engine (app's exact flags, 8K ctx for CI RAM)"
"$SERVER" -m "$DIR/q4b.gguf" --host 127.0.0.1 --port 8649 \
  --alias qwen3-4b --jinja --n-gpu-layers 999 --ctx-size 8192 \
  --cache-type-k q8_0 --cache-type-v q8_0 --cache-reuse 4096 \
  --flash-attn on --reasoning-format deepseek --no-webui \
  > "$DIR/eng.log" 2>&1 &
EPID=$!
trap 'kill $EPID 2>/dev/null || true' EXIT

UP=0
for i in $(seq 1 60); do
  sleep 5
  if curl -s -m 2 http://127.0.0.1:8649/health 2>/dev/null | grep -q ok; then UP=1; break; fi
  if ! kill -0 $EPID 2>/dev/null; then die "engine exited during load"; fi
done
[ "$UP" = 1 ] || die "engine never became healthy"
echo "engine healthy"

echo "▸ chat round-trip (thinking on, low effort — the app's request shape)"
curl -sN -m 180 http://127.0.0.1:8649/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-4b","stream":true,"max_tokens":200,"temperature":1.0,"top_p":0.95,"messages":[{"role":"system","content":"You are Dot."},{"role":"user","content":"Reply with exactly: E2E_OK."}],"chat_template_kwargs":{"enable_thinking":true,"reasoning_effort":"low"}}' \
  > "$DIR/chat.log" || die "chat request failed/timed out"
grep -q "E2E_OK" "$DIR/chat.log" || { echo "--- chat.log tail:"; tail -5 "$DIR/chat.log"; die "E2E_OK not in response"; }
echo "E2E_OK"
