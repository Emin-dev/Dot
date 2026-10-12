#!/bin/bash
# End-to-end engine test for CI (clean macOS arm64 runner — not a user machine):
#  1. fetch the official llama.cpp release (same source the app auto-fetches)
#  2. download a small Qwen3-4B Q4 model
#  3. start llama-server with the app's exact flags
#  4. verify a real chat round-trip in the app's request shape (thinking on, low effort)
set -e
DIR="$HOME/.dot/ci-test"
mkdir -p "$DIR"

echo "▸ fetching llama.cpp engine"
API=$(curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases/latest)
URL=$(echo "$API" | python3 -c "
import json,sys
assets = json.load(sys.stdin).get('assets', [])
match = [x['browser_download_url'] for x in assets if x['name'].endswith('.zip') and 'bin-macos-arm64' in x['name']]
print(match[0] if match else '')")
[ -n "$URL" ] || { echo "no macos-arm64 asset in latest release"; exit 1; }
curl -sL "$URL" -o "$DIR/llama.zip"
unzip -oq "$DIR/llama.zip" -d "$DIR/eng"
chmod +x "$DIR/eng/llama-server"

echo "▸ downloading Qwen3-4B Q4 (2.5 GB)"
curl -sL --http1.1 -o "$DIR/q4b.gguf" \
  "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true"

echo "▸ starting engine (app's exact flags, 8K ctx for CI RAM)"
"$DIR/eng/llama-server" -m "$DIR/q4b.gguf" --host 127.0.0.1 --port 8649 \
  --alias qwen3-4b --jinja --n-gpu-layers 999 --ctx-size 8192 \
  --cache-type-k q8_0 --cache-type-v q8_0 --cache-reuse 4096 \
  --flash-attn on --reasoning-format deepseek --no-webui \
  > "$DIR/eng.log" 2>&1 &
EPID=$!
trap "kill $EPID 2>/dev/null" EXIT

UP=0
for i in $(seq 1 60); do
  sleep 5
  if curl -s -m 2 http://127.0.0.1:8649/health 2>/dev/null | grep -q ok; then UP=1; break; fi
  if ! kill -0 $EPID 2>/dev/null; then echo "engine exited:"; tail -20 "$DIR/eng.log"; exit 1; fi
done
[ "$UP" = 1 ] || { echo "engine never became healthy:"; tail -20 "$DIR/eng.log"; exit 1; }
echo "engine healthy"

echo "▸ chat round-trip (thinking on, low effort — the app's request shape)"
OUT=$(curl -sN -m 120 http://127.0.0.1:8649/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-4b","stream":true,"max_tokens":200,"temperature":1.0,"top_p":0.95,"messages":[{"role":"system","content":"You are Dot."},{"role":"user","content":"Reply with exactly: E2E_OK."}],"chat_template_kwargs":{"enable_thinking":true,"reasoning_effort":"low"}}')
echo "$OUT" | grep -q "E2E_OK" || { echo "E2E content missing; tail:"; echo "$OUT" | tail -5; exit 1; }
echo "E2E_OK"
