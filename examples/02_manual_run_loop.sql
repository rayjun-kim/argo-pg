-- =============================================================================
-- 02_manual_run_loop.sql
--
-- Drive an agent end-to-end without Langflow. Useful for understanding how
-- fn_next_step / fn_submit_result interact and for debugging stuck flows.
--
-- Run as `postgres` (argo_operator member). Adjust task text and tool calls
-- to suit the agent and tools you registered in 01_create_agent_and_tool.sql.
-- =============================================================================

-- 1) Enqueue a task. argo_operator can run on behalf of the agent.
SELECT argo_public.run_agent('researcher', 'What were Q3 cloud earnings for AWS?')
    AS task_info  \gset

-- 2) Ask ARGO what to do next.
SELECT jsonb_pretty(argo_public.fn_next_step((:'task_info')::jsonb->>'task_id')) AS step_1;

-- The result will look like:
--   {
--     "action": "call_llm",
--     "task_id": 1,
--     "messages": [...],
--     "llm_config": {...},
--     "tools": [...]
--   }
--
-- In a real worker, you'd send messages+llm_config to the model and feed the
-- response back. Here we'll simulate two LLM responses by hand.

-- 3) Simulate the LLM choosing to call a tool.
SELECT jsonb_pretty(argo_public.fn_submit_result(
    ((:'task_info')::jsonb->>'task_id')::int,
    '{"action":"call_tool","tool_name":"web_search","args":{"query":"AWS Q3 earnings 2025"}}'
)) AS step_2;

-- ARGO returns either:
--   - {"action":"continue"} for SQL tools (executed inline),
--   - {"action":"invoke_tool", "tool":{...}, "args":{...}} otherwise.
-- For mcp/http/custom tools, your worker is responsible for actually calling
-- the tool, capturing the output, and feeding it back via fn_submit_result.

-- 4) Pretend the tool returned something. We log it manually.
INSERT INTO argo_private.execution_logs(task_id, step_number, role, content)
SELECT
    ((:'task_info')::jsonb->>'task_id')::int,
    COALESCE(MAX(step_number), 0) + 1,
    'tool',
    'web_search returned: AWS reported $27.5B Q3 cloud revenue, up 19% YoY.'
FROM argo_private.execution_logs
WHERE task_id = ((:'task_info')::jsonb->>'task_id')::int;

-- 5) Loop again — get the next step (LLM with the tool result in context).
SELECT jsonb_pretty(argo_public.fn_next_step(((:'task_info')::jsonb->>'task_id')::int)) AS step_3;

-- 6) Simulate the LLM finishing.
SELECT jsonb_pretty(argo_public.fn_submit_result(
    ((:'task_info')::jsonb->>'task_id')::int,
    '{"action":"finish","final_answer":"AWS Q3 cloud revenue was $27.5B, up 19% YoY."}'
)) AS step_4;

-- 7) Inspect what happened.
SET ROLE researcher;
SELECT * FROM argo_public.v_my_tasks ORDER BY created_at DESC LIMIT 3;
RESET ROLE;

SELECT * FROM argo_public.v_session_progress;
