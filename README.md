# serving-infra

Self-hosted LLM serving stack for a homelab k3s cluster ([homelab-k8s-infra](https://github.com/caseymacphee/homelab-k8s-infra)). CPU-only inference with production-shaped ops: gateway routing, provider failover, and three-layer observability.

Built to answer a question that is hard to answer from the outside: **what does an LLM application actually cost, and where does the time go?** Not at the API boundary — at every layer beneath it.

```
Agent application
      │  OTel/Langfuse traces (layer 1: semantics — which node, which turn)
      ▼
LiteLLM (llm.home.macpheelabs.com) ──── Langfuse (langfuse.home.macpheelabs.com)
   │        │                            (layer 2: economics — cost, tokens, cache, latency)
   │        └──► hosted models (Moonshot, Anthropic) — routing + failover
   ▼
llama-server ──► existing kube-prometheus-stack via ServiceMonitor
                 (layer 3: engine health — throughput, KV cache, queue depth)
```

Everything runs on `lab-worker-01` (16 cores / 32GB). No standalone Prometheus: the cluster's kube-prometheus-stack scrapes llama-server directly.

**The join that makes it useful**: layers 1 and 2 only correlate if the application propagates `trace_id`/`session_id` through the gateway's metadata. Without it you have two disconnected views of the same request. See [The trace join](#the-trace-join).

## Layout

- `charts/llm-gateway/` — own chart: llama-server + LiteLLM + ingress + ServiceMonitor. Model auto-downloads to a local-path PVC via initContainer.
- `langfuse/` — values for the official `langfuse/langfuse` chart (v3, bundled postgres/clickhouse/redis/minio).
- `scripts/failover-drill.sh` — kill-the-primary failover exercise.
- `grafana/` — dashboard for llama-server engine metrics.

## Phases

1. **Inference engine** — llama-server on CPU, always on ✅
2. **Gateway** — LiteLLM routing local + hosted, with per-error retries, cooldown, and fallback ✅
3. **Observability** — Langfuse (LLM economics) + existing Prometheus/Grafana (engine health) ✅
4. **Application workload** — a multi-turn agent exercising the stack, with an eval harness whose assertions run over traces ✅ *(separate repo, not yet public)*
5. **Model comparison** — same workload, same instrument, models as the variable
6. **GPU serving** — vLLM on rented GPUs, instrumented at the hardware layer

Phase 4 is deliberately a *workload*, not a product. Its job is to generate realistic multi-turn traffic so the telemetry has something real to measure. It was originally sketched as a LangGraph voice bot; it ended up as a text-first Pydantic AI agent with a deterministic eval suite, because the eval instrument turned out to matter more than the framework choice.

## Deploy

Prereqs: kubeconfig pointing at the cluster, Helm 3.

```sh
# 1. Langfuse first (litellm needs its keys)
helm repo add langfuse https://langfuse.github.io/langfuse-k8s && helm repo update
cd langfuse
cp values-secrets.example.yaml values-secrets.yaml   # fill with openssl rand -hex 32
# sanity-check value names against: helm show values langfuse/langfuse
helm upgrade --install langfuse langfuse/langfuse \
  --namespace langfuse --create-namespace \
  -f values.yaml -f values-secrets.yaml

# 2. DNS (same pattern as other apps)
ssh casey@lab-core
echo "192.168.1.10 llm.home.macpheelabs.com" | sudo tee -a /etc/pihole/custom.list
echo "192.168.1.10 langfuse.home.macpheelabs.com" | sudo tee -a /etc/pihole/custom.list
pihole restartdns

# 3. Create org/project in Langfuse UI (http://langfuse.home.macpheelabs.com),
#    copy API keys into charts/llm-gateway/values-secrets.yaml

# 4. Gateway + inference
cd ../charts/llm-gateway
cp values-secrets.example.yaml values-secrets.yaml   # master key, moonshot key, langfuse keys
helm upgrade --install llm-gateway . \
  --namespace llm --create-namespace \
  -f values.yaml -f values-secrets.yaml
# First rollout downloads the GGUF (~2GB) in an initContainer; watch with:
kubectl logs -n llm deploy/llama-server -c model-download -f
```

Smoke test:

```sh
curl http://llm.home.macpheelabs.com/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "lab-chat", "messages": [{"role": "user", "content": "hello"}]}'
```

The call should appear in Langfuse within a few seconds, and `llama-server` metrics under Prometheus targets in Grafana.

## Failover drill

The reliability layer in the LiteLLM config mirrors a production provider-failover setup (same shape as OpenAI → Azure failover): per-error-type retries, then cooldown (deployment pulled from the pool after `allowed_fails` failures), then fallback to the hosted deployment.

```sh
LITELLM_MASTER_KEY=... ./scripts/failover-drill.sh      # terminal 1: request loop
kubectl scale deploy/llama-server -n llm --replicas=0   # terminal 2: kill the primary
```

What to watch:

- Drill output flips from the local model to `kimi-k2-*` after retries exhaust
- Langfuse shows failed attempts and fallback calls with their costs
- Scale back to 1: traffic returns only after `cooldown_time` (60s) expires, not immediately

Knobs to experiment with (in `charts/llm-gateway/files/litellm-config.yaml`): `allowed_fails`, `cooldown_time`, per-error retry counts. Watch failover latency cost in Langfuse.

## The trace join

Layers 1 and 2 only correlate if the application propagates identifiers through the gateway. Each request to LiteLLM carries:

```json
{"metadata": {"trace_id": "...", "session_id": "..."}}
```

LiteLLM forwards that metadata to Langfuse, joining gateway-level call economics (cost, tokens, cache hits, latency) to application-level semantic traces (which node, which turn, which tool). Without the join you can see *that* a call was expensive and *that* a turn was slow, but not that they were the same request.

This contract is also the seam for swapping the application layer: any runtime that speaks OpenAI-compatible and propagates these IDs plugs into the same stack unchanged.

## Notes

- **Resource budget on lab-worker-01**: llama-server requests 4 CPU / 6GB with a 12-CPU limit; the monitoring stack and Langfuse (clickhouse especially) also live there. If the node gets tight, lower `--parallel` or llama's limits first.
- vLLM is deliberately absent: it is GPU-first and this node is CPU-only. llama.cpp fills that role until Phase 6.
- Large MoE models (Kimi K2 and similar) are API-consumption territory, not self-hosting candidates — multi-GPU datacenter hardware.
- The Langfuse values file is written against that chart's documented layout; run `helm show values langfuse/langfuse` and reconcile before first install.
- Hostnames and IPs here are for a private network behind Tailscale; nothing is internet-exposed.

## License

MIT — see [LICENSE](LICENSE).
