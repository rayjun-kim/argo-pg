# ARGO — DBaaCP Agent Framework

ARGO is a database-as-a-control-plane (DBaaCP) agent framework. The PostgreSQL
database is the single source of truth for agent identity, policies, tools,
sessions, tasks, and execution logs. Workers (here, Langflow) are stateless —
they call two functions, `fn_next_step` and `fn_submit_result`, and let the DB
decide what happens next.

This repository ships a complete, helm-installable stack:

- **PostgreSQL** with the ARGO schema, managed by [CloudNativePG](https://cloudnative-pg.io/)
- **Ollama** for chat + embeddings (CPU by default, GPU optional)
- **Langflow** as the visual interface, with ARGO custom components and
  pre-built starter flows

---

## Quick start

### Option A: Install script (recommended)

```bash
curl -O https://raw.githubusercontent.com/rayjun-kim/argo-pg/main/argo-install.sh
chmod +x argo-install.sh
./argo-install.sh install
```

Available commands:

```bash
./argo-install.sh install     # Install everything
./argo-install.sh uninstall   # Remove everything (with confirmation)
./argo-install.sh status      # Check current status
./argo-install.sh help        # Show usage
```

### Option B: Manual install

**Step 1. Install CNPG Operator (once per cluster)**

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --wait
```

**Step 2. Install ARGO**

```bash
helm repo add argo https://rayjun-kim.github.io/argo-pg
helm repo update
helm install argo argo/argo-stack \
  --namespace argo \
  --create-namespace \
  --set cloudnative-pg.enabled=false
```

**Step 3. Access Langflow**

```bash
kubectl -n argo port-forward svc/argo-argo-stack-langflow 7860:7860
# Open http://localhost:7860
```

> **Note:** Model download (gemma4:e2b ~7GB, nomic-embed-text ~270MB) runs
> in the background. Check progress:
> ```bash
> kubectl logs -n argo -l app.kubernetes.io/component=ollama-model-pull -f
> ```

---

## Requirements

- Kubernetes cluster with `kubectl` configured
- Helm 3.x
- Cluster-admin permissions
- Storage: ~40GB (30GB Ollama models + 10GB PostgreSQL)

---

## Repository layout

```
argo-pg/
├── argo-install.sh           Install / uninstall / status script
├── sql/argo--0.1.sql         Full ARGO schema (single file)
├── langflow-components/      Six custom Langflow nodes
│                               ARGOEnqueue, ARGONextStep, ARGOSubmitResult
│                               ARGOSearchTools, ARGOToolRouter, ARGOEmbedder
├── langflow-flows/           Starter Flow JSONs (single / multi / embedder)
├── charts/argo-stack/        Helm chart (CNPG Cluster + Ollama + Langflow)
├── examples/                 Hand-runnable SQL examples
├── grafana-dashboards/       Grafana dashboard JSONs for monitoring
├── docs/                     Architecture and Langflow guide
└── .github/workflows/        Helm repo release automation (GitHub Pages)
```

---

## What gets installed

| Component | Service | Port |
|-----------|---------|------|
| PostgreSQL (CNPG) | `argo-argo-stack-argo-pg-rw` | 5432 |
| Ollama | `argo-argo-stack-ollama` | 11434 |
| Langflow | `argo-argo-stack-langflow` | 7860 |

Default models: `gemma4:e2b` (chat), `nomic-embed-text` (embeddings)

Default sample data:
- Agent: `sample_chat`
- Tool: `sample_search` (MCP stub)
- Flows: ARGO Single Agent, ARGO Multi Agent, ARGO Embedder

---

## Concepts in 60 seconds

ARGO has exactly two control-plane functions:

```
fn_next_step(task_id, [query_embedding])
   → {action: 'call_llm',      messages, llm_config, tools, memory}
   | {action: 'wait_tasks',    pending_task_ids}
   | {action: 'wait_approval', approval_id}
   | {action: 'done',          output}

fn_submit_result(task_id, llm_response, is_final)
   → {action: 'continue'}
   | {action: 'done',          output, need_embedding}
   | {action: 'invoke_tool',   tool, args}
   | {action: 'wait_tasks',    pending_task_ids}
   | {action: 'wait_approval', approval_id}
```

A worker — Langflow in this repo, but you could write one in any language —
loops over these calls. Everything else (RBAC, tool catalogue, memory search,
multi-agent delegation, human approval) lives in SQL.

---

## What's in the database

| Table | Purpose |
|-------|---------|
| `agent_meta` | Agent identity (1:1 with PG roles) |
| `agent_profiles` | System prompt, max_steps, max_retries |
| `llm_configs` | Provider, model, temperature |
| `agent_profile_assignments` | Joins agent ↔ profile ↔ LLM |
| `sessions` / `tasks` | Execution state |
| `task_dependencies` | DAG edges (used for delegate) |
| `agent_messages` | Inter-agent instructions / results |
| `execution_logs` | Per-step message history |
| `memory` | Long-term agent memory + pgvector |
| `tool_registry` | MCP-spec tools + custom extensions |
| `agent_tool_permissions` | Per-agent tool ACL |
| `tool_executions` | Audit log for tool calls |
| `human_approvals` | Human-in-the-loop queue |
| `flow_registry` | Maps Langflow flow names ↔ agents |
| `agent_events` | Monitoring event stream |
| `embedding_config` | Active embedding model + dims |
| `sql_sandbox_allowlist` | Views the SQL tool may read |
| `system_agent_configs` | Built-in compressor / embedder agents |

14 `argo_public.*` views and 32 functions form the API. Four PG roles
(`argo_operator`, `argo_agent_base`, `argo_langflow`, `argo_sql_sandbox`)
plus per-agent roles isolate access.

---

## Tool model

Tools follow the MCP spec for `name`, `description`, and `input_schema`.
Beyond MCP, ARGO supports three additional `tool_type`s:

| `tool_type` | Where it runs | Configured fields |
|-------------|---------------|-------------------|
| `mcp` | External MCP server | `mcp_server_url`, `mcp_server_name` |
| `http` | Generic REST endpoint | `http_endpoint`, `http_method`, `http_headers` |
| `custom` | Inline Python / JS | `custom_code`, `runtime` |
| `sql` | Inside the DB sandbox | (uses `sql_sandbox_allowlist`) |

Tool descriptions are embedded by the Embedder flow via pgvector.
`fn_search_tools` does cosine-similarity search filtered by agent permissions
and active `embedding_dims`. Rotating embedding models doesn't break anything —
mismatched dims are filtered out, re-embedding catches up gradually.

---

## Multi-agent

Orchestrator emits:

```json
{"action":"delegate","to_agent":"researcher","task":"find Q3 earnings"}
```

ARGO atomically creates a child task, adds a dependency edge, marks the parent
as `waiting`, and returns `{action: wait_tasks}`. When the executor finishes,
the parent is automatically flipped back to `pending`.

---

## Embedding rotation

```sql
SELECT argo_public.rotate_embedding_model(
  'qwen3-embedding:4b', 2560, 'http://argo-argo-stack-ollama:11434'
);
-- Then run the ARGO Embedder flow to rebuild existing vectors
```

---

## Helm configuration

See [`charts/argo-stack/values.yaml`](charts/argo-stack/values.yaml) for full reference.

Common overrides:

```yaml
ollama:
  pullModels: ["gemma4:e2b", "nomic-embed-text"]
  gpu:
    enabled: true
    nodeSelector: {gpu: "true"}

postgresql:
  instances: 3       # HA: primary + 2 replicas

langflow:
  ingress:
    enabled: true
    host: argo.example.com
  auth:
    enabled: true
```

> `cloudnative-pg.enabled` defaults to `false`. CNPG Operator must be
> installed separately to avoid ownership conflicts.

---

## Monitoring

Import the Grafana dashboards from [`grafana-dashboards/`](grafana-dashboards/)
using your CNPG PostgreSQL RW service as the data source:

- `argo-overview.json` — Sessions, tasks, tool latencies, errors
- `argo-agents.json` — Per-agent activity and step counts

---

## Local development

```bash
# Lint
helm lint charts/argo-stack

# Dry-run
helm install argo charts/argo-stack \
  -n argo --create-namespace \
  --set cloudnative-pg.enabled=false \
  --dry-run --debug

# Rebuild Flow JSONs
cd langflow-flows && python3 build_flows.py
```

---

## Project status

Research-grade prototype. Production hardening roadmap: CNPG-I plugin
packaging, Barman Cloud backup, fine-grained ingress auth, PodSecurity
standards.

---

## License

MIT