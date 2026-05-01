-- =============================================================================
-- 03_multi_agent_and_approval.sql
--
-- Demonstrates two ARGO actions that require multiple agents or external
-- intervention:
--
--   delegate          → orchestrator hands a subtask to an executor
--   request_approval  → agent pauses for a human to approve
--
-- Run as a privileged role (postgres / argo_operator member).
-- =============================================================================

-- ---- Multi-agent: orchestrator delegates to researcher ---------------------

-- Make sure we have an orchestrator agent (researcher already exists from 01).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM argo_private.agent_meta WHERE role_name='boss') THEN
        PERFORM argo_public.create_agent('boss', jsonb_build_object(
            'name',          'Boss',
            'agent_role',    'orchestrator',
            'provider',      'ollama',
            'endpoint',      'http://argo-ollama:11434',
            'model_name',    'llama3.2',
            'system_prompt', 'You orchestrate. Delegate research with: {"action":"delegate","to_agent":"researcher","task":"..."}'
        ));
    END IF;
END $$;

-- Enqueue a top-level task to the orchestrator.
SELECT argo_public.run_agent('boss', 'Compile a Q3 earnings briefing.') AS info \gset

-- Pretend the LLM chose to delegate to researcher.
SELECT jsonb_pretty(argo_public.fn_submit_result(
    ((:'info')::jsonb->>'task_id')::int,
    '{"action":"delegate","to_agent":"researcher","task":"Find AWS Q3 cloud revenue."}'
)) AS delegate_response;
-- Expected: {"action":"wait_tasks", "pending_task_ids":[<child_task_id>]}

-- Inspect the resulting task graph.
SELECT t.task_id, am.role_name AS agent, t.status, t.input
FROM argo_private.tasks t
JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
WHERE t.session_id = ((:'info')::jsonb->>'session_id')::int
ORDER BY t.task_id;

-- The instruction message recorded:
SELECT message_id, from_a.role_name AS sender, to_a.role_name AS receiver,
       direction, status, content
FROM argo_private.agent_messages m
JOIN argo_private.agent_meta from_a ON from_a.agent_id = m.from_agent_id
JOIN argo_private.agent_meta to_a   ON to_a.agent_id   = m.to_agent_id
WHERE m.session_id = ((:'info')::jsonb->>'session_id')::int;

-- ---- Approval workflow -----------------------------------------------------

-- Pretend an executor wants human sign-off before sending an external email.
SELECT argo_public.run_agent('researcher', 'Send the briefing email to leadership.')
    AS info  \gset

SELECT jsonb_pretty(argo_public.fn_submit_result(
    ((:'info')::jsonb->>'task_id')::int,
    '{"action":"request_approval","reason":"About to send external email to leadership@acme."}'
)) AS approval_response;
-- Expected: {"action":"wait_approval","approval_id":<id>}

-- View the pending queue.
SELECT * FROM argo_public.v_pending_approvals;

-- A human approves.
SELECT argo_public.fn_resolve_approval(
    (SELECT approval_id FROM argo_public.v_pending_approvals
     ORDER BY created_at DESC LIMIT 1),
    'approved',
    'Verified with the legal team.'
);

-- Task should be back to pending and ready for the next fn_next_step.
SELECT t.task_id, t.status FROM argo_private.tasks t
WHERE t.task_id = ((:'info')::jsonb->>'task_id')::int;
