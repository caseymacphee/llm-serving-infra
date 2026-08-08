#!/usr/bin/env bash
# Failover drill: send a request through the gateway every 2s and print which
# backend served it. Run this, then in another terminal:
#
#   kubectl scale deploy/llama-server -n llm --replicas=0   # watch failover to Kimi K2
#   kubectl scale deploy/llama-server -n llm --replicas=1   # traffic returns after cooldown
#
# Requires: curl, jq. Set LITELLM_MASTER_KEY in your env (or export from
# charts/llm-gateway/values-secrets.yaml).

set -euo pipefail

GATEWAY="${GATEWAY:-http://llm.home.macpheelabs.com}"
: "${LITELLM_MASTER_KEY:?set LITELLM_MASTER_KEY}"

echo "Sending requests to ${GATEWAY} as model group 'lab-chat' (ctrl-c to stop)"
while true; do
  ts=$(date +%H:%M:%S)
  resp=$(curl -s --max-time 150 "${GATEWAY}/v1/chat/completions" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "lab-chat",
      "max_tokens": 32,
      "messages": [{"role": "user", "content": "Reply with one word: ok"}]
    }' || echo '{"error": "request failed"}')

  model=$(echo "$resp" | jq -r '.model // .error.message // .error // "unknown"')
  echo "[$ts] served by: $model"
  sleep 2
done
