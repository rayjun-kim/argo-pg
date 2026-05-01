# Using Langflow with ARGO

The chart installs Langflow with six ARGO components mounted automatically
and three starter flows ready to import.

## First run

After `helm install`:

```bash
kubectl -n argo port-forward svc/argo-argo-stack-langflow 7860:7860
```

Open [http://localhost:7860](http://localhost:7860). The starter flows
(uploaded by the `langflow-import` Job) appear under "Flows":

- **ARGO Single Agent** — minimal Enqueue → Next Step → Ollama → Submit Result loop
- **ARGO Multi Agent** — orchestrator + executor lanes with delegation
- **ARGO Embedder** — re-embed pgvector rows after model rotation

## Component reference

In the component sidebar, look under **Argo** (the category folder):

| Node                 | Inputs                          | Outputs                                                    |
|----------------------|---------------------------------|------------------------------------------------------------|
| `ARGO Enqueue`       | agent_role, task, [session_id]  | task_info {task_id, session_id, agent_id}                  |
| `ARGO Next Step`     | task_id, [query_embedding]      | step {action, messages, llm_config, tools, memory}         |
| `ARGO Submit Result` | task_id, response, [is_final]   | continue / done / invoke_tool / wait_tasks / wait_approval |
| `ARGO Tool Router`   | invoke_payload                  | mcp / http / custom                                        |
| `ARGO Search Tools`  | query_embedding, agent_id       | tools (top-k matches)                                       |
| `ARGO Embedder`      | batch_size                      | report                                                      |

## Single-agent flow

```
[Enqueue]→[Next Step]→[Ollama]→[Submit Result]
                ↑__________continue__|
                            invoke_tool→[Tool Router]→[mcp/http/custom]
                            done→ end
```

The Submit Result component has five output ports. Connect:
- `continue` back to Next Step's `task_id` for the loop.
- `invoke_tool` to Tool Router's `invoke_payload`.
- `wait_tasks` and `wait_approval` to whatever waiting node you prefer
  (or back to Next Step for a re-poll pattern).
- `done` to a Chat Output if you want the final answer surfaced.

## Multi-agent flow

Two lanes share a `session_id`:
- **Orchestrator lane**: triggered by user input. Its LLM emits `delegate`
  actions. Submit Result's `wait_tasks` port loops back to Next Step.
- **Executor lane**: schedules itself via the v_ready_tasks view. Its Next
  Step polls (or, more commonly, you trigger this lane from a webhook
  fired by the same orchestrator interaction).

When the executor finishes, the parent (orchestrator) task automatically
flips back to `pending`. The next time the orchestrator's Next Step is
called, it sees the executor's result via `agent_messages`.

## Tool execution patterns

When Submit Result emits `invoke_tool`, ARGO has already:
1. Verified the agent has permission for the tool.
2. Logged a `tool_call` event.

Your Tool Router then sends the payload to the right runtime:

```
mcp_out    → Langflow's MCP Client (point it at tool.mcp_server_url)
http_out   → Langflow's HTTP Request component
custom_out → Langflow's Code component (or your own)
```

After the tool runs, send the output back to a fresh Submit Result with
the LLM's next action wrapping it (often `continue` after logging the
tool result via fn_log_step inside a follow-up call).

## Connecting to the database

All components connect via environment variables set by the chart:

```
ARGO_PG_HOST     argo-argo-stack-argo-pg-rw
ARGO_PG_PORT     5432
ARGO_PG_DB       argo
ARGO_PG_USER     argo_langflow
ARGO_PG_PASSWORD <from the kept Secret>
```

The `argo_langflow` role can call all runtime functions (`run_agent`,
`fn_next_step`, `fn_submit_result`, `fn_resolve_approval`, `fn_search_*`,
embedding writes) on behalf of any agent. Admin functions
(`create_agent`, `fn_register_tool`, `rotate_embedding_model`) require
`argo_operator`, which Langflow does NOT have by default.

## Adding a new tool from Langflow

For now, register tools with SQL — see `examples/01_create_agent_and_tool.sql`.
A future Langflow component for tool registration is on the roadmap.

## Customising the components

The components live in
`charts/argo-stack/files/components/`. Edit, then:

```bash
helm upgrade argo charts/argo-stack -n argo
```

The chart re-creates the ConfigMap, the deployment annotation `checksum/components`
changes, and Langflow restarts with the new code.

## Troubleshooting

**Components don't show up in the sidebar.**
- Check `LANGFLOW_COMPONENTS_PATH=/app/custom_components` is set.
- The category folder must contain `__init__.py` (the init container creates one).
- View Langflow logs: `kubectl -n argo logs deploy/argo-argo-stack-langflow`.

**Submit Result returns the wrong port.**
- Verify your LLM produces well-formed JSON. Plain text is treated as
  `{action: 'finish', final_answer: '...'}`.
- Check `argo_private.execution_logs` for the actual response.

**Agent has no tools available.**
- `argo_langflow` role can read `v_my_tools` only when SET ROLE'd to the
  agent or when `pg_has_role` returns operator membership. Use Next Step's
  built-in lookup; don't query `v_my_tools` directly from a different role.
