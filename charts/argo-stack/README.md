# argo-stack — Helm chart

Single-command install of the ARGO agent framework on Kubernetes:

- **PostgreSQL** managed by [CloudNativePG](https://cloudnative-pg.io/)
  with the ARGO schema bootstrapped on first init.
- **Ollama** (CPU by default, GPU via values toggle) for chat + embeddings.
- **Langflow** with ARGO custom components and starter flows pre-mounted.

## Quick start

```bash
helm repo add argo https://<your-org>.github.io/argo-stack
helm repo update

helm install argo argo/argo-stack \
  --namespace argo --create-namespace \
  --wait
```

After install, port-forward Langflow:

```bash
kubectl -n argo port-forward svc/argo-argo-stack-langflow 7860:7860
open http://localhost:7860
```

The chart's `NOTES.txt` (printed by `helm install`) lists DB credentials and
sample data details.

## What gets deployed

| Component | Service                          | Port  |
|-----------|----------------------------------|-------|
| PostgreSQL (RW endpoint) | `<release>-argo-stack-argo-pg-rw`     | 5432  |
| Ollama                  | `<release>-argo-stack-ollama`         | 11434 |
| Langflow                | `<release>-argo-stack-langflow`       | 7860  |

## Configuration overview

The full reference lives in [`values.yaml`](values.yaml). The most common
toggles:

```yaml
postgresql:
  instances: 1            # bump to 2+ for HA
  storage: { size: 10Gi }

ollama:
  pullModels:
    - llama3.2
    - nomic-embed-text
  gpu:
    enabled: false        # set true for nvidia.com/gpu nodes
  resources:
    limits: { cpu: "4", memory: "8Gi" }

langflow:
  importFlows: true
  ingress:
    enabled: false        # set true and supply host/className for Ingress
  auth:
    enabled: false        # set true for password-protected Langflow

argo:
  applySchema: true
  seedExamples: true
  embedding:
    modelName: nomic-embed-text
    dimensions: 768
```

## Architecture

```
┌─────────┐                              ┌──────────────────────────┐
│ Langflow│  ── runs ARGO components ─►  │ PostgreSQL (CNPG)        │
│         │  ── calls LLM / embed ────►  │  • argo schema           │
│         │                              │  • tool_registry         │
└────┬────┘                              │  • execution_logs        │
     │                                   │  • memory + pgvector     │
     ▼                                   └──────────────────────────┘
┌─────────┐                                        ▲
│ Ollama  │  ◄── embedding/chat HTTP ────  cnpg-rw │
└─────────┘                                        │
                                                   │
                                            ARGO Roles:
                                              argo_operator
                                              argo_langflow  ← Langflow auth
                                              argo_<agent>
```

## Bootstrap order

1. `cloudnative-pg` operator (subchart, if not pre-installed)
2. `Cluster` resource — CNPG runs `initdb` then applies:
   - `01-schema.sql` (full ARGO schema)
   - `02-overrides.sql` (re-points embedding endpoint to the in-cluster Ollama)
3. `argo-roles` Job (Helm post-install) — sets passwords for the privileged
   ARGO roles using credentials from the Helm-generated Secret.
4. `argo-seed` Job (post-install) — inserts a sample agent + tool +
   flow_registry rows. Idempotent.
5. `langflow-import` Job (post-install) — uploads the bundled flow JSONs
   to the Langflow API.

## Sample data

When `argo.seedExamples: true` (default):

- Agent `sample_chat` configured to use Ollama with the chat model from
  `ollama.defaultChatModel`.
- Tool `sample_search` (MCP type, points at `http://example-mcp:8080/sse`
  — replace with a real MCP server to make it functional).
- Flow registry entries linking the bundled flows to `sample_chat`.

## Custom components

The chart ships six ARGO components in
[`files/components/`](files/components):

- `ARGOEnqueue`, `ARGONextStep`, `ARGOSubmitResult` — core control loop
- `ARGOSearchTools` — pgvector tool search
- `ARGOToolRouter` — splits invoke_tool by `tool_type`
- `ARGOEmbedder` — re-embeds rows after model rotation

They're mounted into Langflow at `/app/custom_components/argo/` via
ConfigMap, and Langflow loads them automatically through
`LANGFLOW_COMPONENTS_PATH`.

## Uninstall

```bash
helm uninstall argo -n argo
```

This removes the workloads but **keeps**:
- the password Secret (`<release>-argo-stack-argo-passwords`)
- the auth Secret (if enabled)

The PVC for Postgres data is also kept by CNPG semantics. Delete manually:

```bash
kubectl -n argo delete pvc -l app.kubernetes.io/instance=argo
kubectl -n argo delete secret <release>-argo-stack-argo-passwords
```

## Development

To work on the chart locally:

```bash
helm dependency update charts/argo-stack
helm template charts/argo-stack          # render to stdout
helm lint charts/argo-stack              # static check
helm install argo charts/argo-stack \
  -n argo --create-namespace --dry-run --debug
```
