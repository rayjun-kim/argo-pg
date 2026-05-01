# ARGO Architecture

## Why DBaaCP?

Most agent frameworks store state across application servers, message queues
and vector DBs. The result: hard-to-debug race conditions, drifting policies,
and no single audit log. ARGO inverts this — the database **is** the
control plane. State, policy, RBAC, audit, and routing decisions all happen
in PostgreSQL.

Workers (Langflow, a Python script, or anything that can call SQL) are
**stateless**. They call `fn_next_step`, run an LLM, and call `fn_submit_result`.

## Layered architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ Interface (Langflow + custom ARGO components)                    │
│   Triggers, LLM calls, MCP/HTTP/custom tool execution            │
└──────────────────────────────────────────────────────────────────┘
                       ↑ ↓ SELECT / EXEC FUNCTION
┌──────────────────────────────────────────────────────────────────┐
│ Public API (argo_public schema)                                  │
│   Functions: run_agent, fn_next_step, fn_submit_result,           │
│              fn_search_tools, fn_search_memory,                   │
│              create_agent, fn_register_tool, fn_resolve_approval, │
│              rotate_embedding_model, fn_recover_stale_tasks       │
│   Views:    v_my_tasks, v_my_tools, v_my_memory,                  │
│              v_session_progress, v_pending_approvals,             │
│              v_tool_stats, v_agent_events,                        │
│              v_ready_tasks, v_stale_tasks, v_reembedding_targets, │
│              v_compressible_logs, v_session_audit, v_system_agents│
└──────────────────────────────────────────────────────────────────┘
                       ↑ ↓ SECURITY DEFINER
┌──────────────────────────────────────────────────────────────────┐
│ Private state (argo_private schema)                              │
│   Tables: agent_meta, agent_profiles, llm_configs,                │
│            sessions, tasks, execution_logs, memory,                │
│            tool_registry, agent_tool_permissions,                  │
│            tool_executions, agent_messages, human_approvals,       │
│            flow_registry, agent_events, embedding_config, ...      │
└──────────────────────────────────────────────────────────────────┘
                       ↑ ↓ pg_notify
┌──────────────────────────────────────────────────────────────────┐
│ Triggers + pgvector                                              │
│   tasks INSERT/UPDATE → argo_task_ready                           │
│   sessions UPDATE     → argo_session_done                         │
│   approvals INSERT    → argo_approval_needed                      │
└──────────────────────────────────────────────────────────────────┘
```

## RBAC model

| Role             | Login | Purpose                                              |
|------------------|-------|------------------------------------------------------|
| `argo_operator`  | yes   | Admin. Creates agents, tools, rotates embedding model |
| `argo_langflow`  | yes   | Langflow runtime. Can act on behalf of any agent     |
| `argo_agent_base`| no    | Inherited by every per-agent role                    |
| `argo_<agent>`   | yes   | Per-agent role (created by `create_agent`)            |
| `argo_sql_sandbox`| no   | SET ROLE'd to inside `fn_execute_sql`. Read-only on allowlisted views |

`session_user` checks (not `current_user`) protect every public function.
`SECURITY DEFINER` lets functions read private tables on behalf of the
caller, but only after explicit role checks.

## Two-function loop in detail

```
fn_next_step(task_id, [query_embedding])
  ├── verify task exists; mark running; bump heartbeat
  ├── if status='waiting'         → return {action:'wait_tasks', pending_task_ids}
  ├── if step_count >= max_steps  → fn_submit_result(force_final=true)
  ├── optionally search memory    (uses query_embedding + active dims)
  ├── build messages: system + history + agent_messages + current logs
  ├── load llm_config + tools list (filtered by agent_tool_permissions)
  └── return {action:'call_llm', messages, llm_config, tools, memory}

fn_submit_result(task_id, response, is_final)
  ├── append assistant log
  ├── parse response as JSON; if not JSON treat as plain finish
  ├── case action:
  │     finish           → mark completed; deliver result to parent if subtask
  │     call_tool        → ACL check; sql tools run inline, others return invoke_tool
  │     delegate         → create child task + dependency + agent_messages instruction
  │                          mark parent waiting; return wait_tasks
  │     request_approval → insert human_approvals row; mark waiting
  │     other            → return continue (LLM will refine)
  └── return next-action envelope
```

## Multi-agent topology

The chart's multi-agent flow has two lanes (orchestrator + executor) but
the **DB doesn't know about lanes** — it routes by `task.agent_id` and
`v_ready_tasks`. You can spin up arbitrarily many executor agents; each
Langflow flow scheduling itself for tasks where `agent_id = <my agent>`.

## Embedding lifecycle

`embedding_config` has exactly one active row at a time. Tools and memory
write `embedding_dims` alongside the vector. Search functions filter by
the active dims. Rotation is non-destructive:

```sql
SELECT argo_public.rotate_embedding_model('qwen3-embedding:4b', 2560, '...');
-- old vectors stay; search results just shrink until embedder catches up
```

The **embedder Flow** polls `v_reembedding_targets`, calls Ollama, and
writes back via `fn_set_tool_embedding` / `fn_set_memory_embedding`.

## Why we removed `plpython3u`

The original ARGO design called Ollama directly from inside `fn_get_embedding`.
That works, but it ties the DB to outbound HTTP and requires the
`plpython3u` extension (rarely available in managed PG offerings). We moved
embedding generation to the Langflow worker — a small departure from
"DB does everything" but keeps the DB image standard CNPG.

## What the chart does on `helm install`

1. Installs `cloudnative-pg` operator (subchart, optional).
2. Creates a `Cluster` with two `postInitApplicationSQLRefs`:
   `01-schema.sql` (the full ARGO schema) and `02-overrides.sql` (re-points
   the seed `embedding_config` row at the in-cluster Ollama service).
3. Post-install Job sets `LOGIN PASSWORD` for `argo_operator` /
   `argo_langflow` from a kept Secret.
4. Post-install Job seeds a sample agent + tool + flow_registry rows.
5. Ollama Deployment with an init-container that pulls configured models.
6. Langflow Deployment with a ConfigMap volume of ARGO components mounted
   under `/app/custom_components/argo/`.
7. Post-install Job uploads bundled flow JSONs via Langflow's API.

## Failure modes and recovery

| Failure                           | Recovery                                |
|-----------------------------------|-----------------------------------------|
| Langflow crashes mid-task         | `fn_recover_stale_tasks` reverts running tasks with stale heartbeats to pending; `retry_count` bumped; exceeds `max_retries` → failed |
| Embedding model rotated           | Existing data filtered out by dim mismatch; embedder Flow re-fills |
| MCP server down                   | Tool call fails; ARGO logs an error step and returns `continue` |
| ConfigMap > 1MB after schema growth | Split into multiple `configMapRefs` in `pg-cluster.yaml` |

## Observability

- Every interesting state change writes to `agent_events` (session_start,
  task_start, tool_call, delegation, approval_request, …).
- `tool_executions` has per-call latency.
- `execution_logs` has the full message history.
- `pg_notify` is fired for ready tasks, completed sessions, and pending
  approvals — useful for Webhook-driven integrations beyond Langflow.

The two Grafana dashboards in `grafana-dashboards/` cover overview and
per-agent activity. Hook your existing Grafana up to the Cluster's
`<release>-argo-pg-rw` service as a PostgreSQL data source.
