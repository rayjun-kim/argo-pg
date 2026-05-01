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

### 1. CNPG Operator 설치 (최초 1회)

CloudNativePG Operator는 클러스터 전체에 하나만 설치되어야 합니다.

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --wait
```

### 2. ARGO 설치

```bash
helm repo add argo https://rayjun-kim.github.io/argo-pg
helm repo update
helm install argo argo/argo-stack \
  --namespace argo \
  --create-namespace \
  --set cloudnative-pg.enabled=false \
  --wait
```

### 3. Langflow 접속

```bash
kubectl -n argo port-forward svc/argo-argo-stack-langflow 7860:7860
# 브라우저에서 http://localhost:7860 열기
```

---

## Repository layout

```
argo-pg/
├── sql/argo--0.1.sql         The full ARGO schema (single file)
├── langflow-components/      Six custom Langflow nodes:
│                               ARGOEnqueue, ARGONextStep, ARGOSubmitResult,
│                               ARGOSearchTools, ARGOToolRouter, ARGOEmbedder
├── langflow-flows/           Starter Flow JSONs (single / multi / embedder)
├── charts/argo-stack/        The Helm chart (CNPG Cluster + Ollama + Langflow)
├── examples/                 Hand-runnable SQL examples for direct DB use
├── grafana-dashboards/       PostgreSQL data-source dashboards for monitoring
├── docs/                     Concept docs and architecture diagrams
└── .github/workflows/        Release automation (Helm repo on GitHub Pages)
```

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

| Table                       | Purpose |
|-----------------------------|---------|
| `agent_meta`                | Agent identity (1:1 with PG roles) |
| `agent_profiles`            | System prompt, max_steps, max_retries |
| `llm_configs`               | Provider, model, temperature |
| `agent_profile_assignments` | Joins agent ↔ profile ↔ LLM |
| `sessions` / `tasks`        | Execution state |
| `task_dependencies`         | DAG edges (used for delegate) |
| `agent_messages`            | Inter-agent instructions / results |
| `execution_logs`            | Per-step message history |
| `memory`                    | Long-term agent memory + pgvector |
| `tool_registry`             | MCP-spec tools + custom (sql/http/custom) |
| `agent_tool_permissions`    | Per-agent tool ACL |
| `tool_executions`           | Audit log for tool calls |
| `human_approvals`           | Human-in-the-loop queue |
| `flow_registry`             | Maps Langflow flow names ↔ agents |
| `agent_events`              | Monitoring event stream |
| `embedding_config`          | Active embedding model + dims |
| `sql_sandbox_allowlist`     | Views the SQL tool may read |
| `system_agent_configs`      | Built-in compressor / embedder agents |

Fourteen `argo_public.*` views and 32 functions form the API. Four PG roles
(`argo_operator`, `argo_agent_base`, `argo_langflow`, `argo_sql_sandbox`, plus per-agent roles)
isolate access.

---

## Tool model

Tools follow the MCP spec for `name`, `description`, and `input_schema`
([reference](https://modelcontextprotocol.io/specification/server/tools)).
Beyond MCP, ARGO supports three additional `tool_type`s:

| `tool_type` | Where it runs                      | Configured fields                              |
|-------------|------------------------------------|------------------------------------------------|
| `mcp`       | External MCP server (Langflow MCP) | `mcp_server_url`, `mcp_server_name`            |
| `http`      | Generic REST endpoint              | `http_endpoint`, `http_method`, `http_headers` |
| `custom`    | Inline Python / JS                 | `custom_code`, `runtime`                       |
| `sql`       | Inside the DB (SQL sandbox)        | (uses `sql_sandbox_allowlist`)                 |

Tool descriptions are embedded by the embedder flow into `description_embedding`
via pgvector, and `fn_search_tools` does cosine-similarity search filtered by
`agent_tool_permissions` and the active `embedding_dims`. Rotating embedding
models doesn't break anything — mismatched dims are filtered out, and
re-embedding catches up.

---

## Multi-agent flow

Orchestrator emits:

```json
{"action":"delegate","to_agent":"researcher","task":"find Q3 earnings"}
```

ARGO atomically:
1. Creates a child task assigned to `researcher`.
2. Adds a `task_dependencies` edge.
3. Marks the parent task as `waiting`.
4. Inserts an `agent_messages` instruction row.
5. Returns `{action: wait_tasks, pending_task_ids: [...]}` to the orchestrator's flow.

When the executor finishes, ARGO:
1. Inserts a `result` row in `agent_messages`.
2. Flips the parent task back to `pending` (if no other dependencies).
3. Notifies via `pg_notify('argo_task_ready', ...)`.

---

## Embedding rotation

```sql
SELECT argo_public.rotate_embedding_model(
  'qwen3-embedding:4b',  -- new model
  2560,                  -- new dimensions
  'http://argo-ollama:11434'
);
```

Existing rows are NOT cleared — they're ignored by `fn_search_*` because
their `embedding_dims` no longer match the active config. Run the ARGO
Embedder flow to rebuild them at your own pace.

---

## Helm chart configuration

See [`charts/argo-stack/values.yaml`](charts/argo-stack/values.yaml) and
[`charts/argo-stack/README.md`](charts/argo-stack/README.md) for the full reference.

Common overrides:

```yaml
ollama:
  pullModels: ["llama3.2", "nomic-embed-text"]
  gpu:
    enabled: true                # use NVIDIA GPUs
    nodeSelector: {gpu: "true"}

postgresql:
  instances: 3                   # HA: primary + 2 replicas

langflow:
  ingress:
    enabled: true
    host: argo.example.com
  auth:
    enabled: true
```

> **Note:** `cloudnative-pg.enabled` is `false` by default. CNPG Operator
> must be installed separately (see Quick start above). This avoids ownership
> conflicts when CNPG is already present in the cluster.

---

## Monitoring

Pre-built Grafana dashboards in [`grafana-dashboards/`](grafana-dashboards/):

- `argo-overview.json` — Sessions, tasks, errors, tool latencies
- `argo-agents.json` — Per-agent activity and step counts

Add your CNPG PostgreSQL RW service as a Grafana data source, then import
the JSON files. CNPG ships its own PG-infra dashboards; together they cover
the full stack.

---

## Local development

```bash
# Render the chart without installing
helm template argo charts/argo-stack \
  --set cloudnative-pg.enabled=false > /tmp/manifests.yaml

# Static analysis
helm lint charts/argo-stack

# Dry-run install
helm install argo charts/argo-stack \
  -n argo --create-namespace \
  --set cloudnative-pg.enabled=false \
  --dry-run --debug
```

Building the Flow JSONs from sources:

```bash
cd langflow-flows
python3 build_flows.py
```

---

## Project status

Research-grade prototype. Production hardening to layer on top: CNPG-I plugin
packaging, Barman Cloud backup integration, fine-grained ingress auth, and
PodSecurity standards.

---

## License

MIT
