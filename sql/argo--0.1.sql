-- =============================================================================
-- argo--0.1.sql  ARGO v0.1 — DBaaCP Agent Framework
-- Designed for: CNPG bootstrap + Langflow interface
--
-- Section order:
--   01. Extensions
--   02. Schemas
--   03. Roles
--   04. Types
--   05. Tables
--   06. Views
--   07. Functions
--   08. Grants
--   09. Indexes
--   10. Triggers
--   11. Seed Data
-- =============================================================================

-- =============================================================================
-- 01. Required Extensions
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- 02. Schemas
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS argo_private;
CREATE SCHEMA IF NOT EXISTS argo_public;

COMMENT ON SCHEMA argo_private IS 'ARGO internal tables. Not directly accessible to agent roles.';
COMMENT ON SCHEMA argo_public  IS 'ARGO public API: views and functions for agent roles and Langflow.';

-- =============================================================================
-- 03. Roles
-- =============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'argo_operator')   THEN CREATE ROLE argo_operator   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'argo_agent_base') THEN CREATE ROLE argo_agent_base NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'argo_sql_sandbox')THEN CREATE ROLE argo_sql_sandbox NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'argo_langflow')   THEN CREATE ROLE argo_langflow   NOLOGIN; END IF;
END $$;

COMMENT ON ROLE argo_operator    IS 'ARGO admin role. Grant to human DBAs and management tools.';
COMMENT ON ROLE argo_agent_base  IS 'Base role inherited by all agent roles.';
COMMENT ON ROLE argo_sql_sandbox IS 'Minimal role used by fn_execute_sql. SELECT on allowlisted views only.';
COMMENT ON ROLE argo_langflow    IS 'Role used by Langflow runtime. Can run agents on behalf of any agent role.';

-- =============================================================================
-- 04. Types
-- =============================================================================
CREATE TYPE argo_public.agent_role_type AS ENUM ('orchestrator','executor','evaluator');
CREATE TYPE argo_public.task_status     AS ENUM ('pending','waiting','running','completed','failed','cancelled');
CREATE TYPE argo_public.llm_provider    AS ENUM ('anthropic','openai','ollama','custom');
CREATE TYPE argo_public.session_status  AS ENUM ('active','completed','failed');
CREATE TYPE argo_public.tool_type       AS ENUM ('mcp','sql','http','custom');
CREATE TYPE argo_public.approval_status AS ENUM ('pending','approved','rejected');

-- =============================================================================
-- 05. Tables
-- =============================================================================

-- -----------------------------------------------------------------------------
-- embedding_config: Single source of truth for the active embedding model.
-- Tools and memory store embedding_dims alongside vectors so that mismatched
-- vectors are automatically excluded from search after model rotation.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.embedding_config (
    config_id     SERIAL PRIMARY KEY,
    model_name    TEXT    NOT NULL,
    dimensions    INT     NOT NULL CHECK (dimensions > 0),
    endpoint      TEXT    NOT NULL,
    is_active     BOOLEAN NOT NULL DEFAULT FALSE,
    activated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_embedding_config_active
    ON argo_private.embedding_config (is_active) WHERE is_active = TRUE;
COMMENT ON TABLE argo_private.embedding_config IS
    'Active embedding model registry. Only one row may have is_active=TRUE at a time.';

-- -----------------------------------------------------------------------------
-- llm_configs: LLM provider/model settings.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.llm_configs (
    llm_config_id   SERIAL PRIMARY KEY,
    provider        TEXT    NOT NULL CHECK (provider IN ('anthropic','openai','ollama','custom')),
    endpoint        TEXT    NOT NULL DEFAULT '',
    model_name      TEXT    NOT NULL,
    api_key_ref     TEXT,
    temperature     FLOAT   NOT NULL DEFAULT 0.7 CHECK (temperature >= 0 AND temperature <= 2),
    max_tokens      INT     NOT NULL DEFAULT 4096 CHECK (max_tokens > 0),
    request_options JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE argo_private.llm_configs IS
    'LLM provider and model config. api_key_ref = env var name only, never the key itself.';

-- -----------------------------------------------------------------------------
-- agent_profiles: behavioural settings.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.agent_profiles (
    profile_id    SERIAL PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    agent_role    TEXT NOT NULL CHECK (agent_role IN ('orchestrator','executor','evaluator')),
    system_prompt TEXT NOT NULL DEFAULT '',
    max_steps     INT  NOT NULL DEFAULT 10 CHECK (max_steps > 0),
    max_retries   INT  NOT NULL DEFAULT 3  CHECK (max_retries >= 0),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- agent_meta: agent identity. role_name must match a PostgreSQL role.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.agent_meta (
    agent_id     SERIAL PRIMARY KEY,
    role_name    TEXT    NOT NULL UNIQUE,
    display_name TEXT    NOT NULL,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- agent_profile_assignments: profile + LLM config per agent.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.agent_profile_assignments (
    assignment_id SERIAL PRIMARY KEY,
    role_name     TEXT NOT NULL UNIQUE REFERENCES argo_private.agent_meta(role_name) ON DELETE CASCADE ON UPDATE CASCADE,
    profile_id    INT  NOT NULL REFERENCES argo_private.agent_profiles(profile_id)   ON DELETE RESTRICT,
    llm_config_id INT  NOT NULL REFERENCES argo_private.llm_configs(llm_config_id)   ON DELETE RESTRICT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- sessions: top-level execution unit.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.sessions (
    session_id   SERIAL PRIMARY KEY,
    agent_id     INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed','failed')),
    goal         TEXT NOT NULL,
    final_answer TEXT,
    started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ
);
COMMENT ON COLUMN argo_private.sessions.agent_id IS 'Owning agent (orchestrator in multi-agent flows).';

-- -----------------------------------------------------------------------------
-- session_participants: agents participating in a session (multi-agent).
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.session_participants (
    session_id   INT NOT NULL REFERENCES argo_private.sessions(session_id)   ON DELETE CASCADE,
    agent_id     INT NOT NULL REFERENCES argo_private.agent_meta(agent_id)   ON DELETE CASCADE,
    joined_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, agent_id)
);
COMMENT ON TABLE argo_private.session_participants IS
    'All agents that participate in a session. Used for visibility checks on shared sessions.';

-- -----------------------------------------------------------------------------
-- tasks: individual execution steps within a session.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.tasks (
    task_id       SERIAL PRIMARY KEY,
    session_id    INT  NOT NULL REFERENCES argo_private.sessions(session_id) ON DELETE CASCADE,
    agent_id      INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','waiting','running','completed','failed','cancelled')),
    input         TEXT NOT NULL,
    output        TEXT,
    retry_count   INT  NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    heartbeat_at  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE argo_private.tasks IS 'Task queue between Langflow workers and ARGO control plane.';
COMMENT ON COLUMN argo_private.tasks.status IS
    'pending=ready to run; waiting=blocked on subtasks; running=in flight; completed/failed/cancelled=terminal.';
COMMENT ON COLUMN argo_private.tasks.heartbeat_at IS
    'Updated by Langflow during long-running steps. Stale heartbeats trigger recovery.';

-- -----------------------------------------------------------------------------
-- task_dependencies: DAG ordering between tasks.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.task_dependencies (
    dependency_id      SERIAL PRIMARY KEY,
    task_id            INT NOT NULL REFERENCES argo_private.tasks(task_id) ON DELETE CASCADE,
    depends_on_task_id INT NOT NULL REFERENCES argo_private.tasks(task_id) ON DELETE CASCADE,
    CONSTRAINT uq_task_dep     UNIQUE (task_id, depends_on_task_id),
    CONSTRAINT chk_no_self_dep CHECK  (task_id <> depends_on_task_id)
);

-- -----------------------------------------------------------------------------
-- execution_logs: full message history per task.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.execution_logs (
    log_id              SERIAL PRIMARY KEY,
    task_id             INT  NOT NULL REFERENCES argo_private.tasks(task_id) ON DELETE CASCADE,
    step_number         INT  NOT NULL,
    role                TEXT NOT NULL CHECK (role IN ('system','user','assistant','tool')),
    content             TEXT NOT NULL,
    compressed_content  TEXT,
    compression_quality FLOAT CHECK (compression_quality IS NULL OR (compression_quality >= 0 AND compression_quality <= 1)),
    compressed_at       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- memory: long-term agent memory with embeddings.
-- embedding_dims is recorded at insert time so that search can filter mismatched
-- vectors after embedding model rotation.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.memory (
    memory_id      SERIAL PRIMARY KEY,
    agent_id       INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    session_id     INT  REFERENCES argo_private.sessions(session_id) ON DELETE SET NULL,
    content        TEXT NOT NULL,
    embedding      vector,
    embedding_dims INT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON COLUMN argo_private.memory.embedding_dims IS
    'Dimensionality recorded at insert. Used to filter mismatched vectors after rotate_embedding_model.';

-- -----------------------------------------------------------------------------
-- agent_messages: instruction/result exchange between agents (multi-agent).
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.agent_messages (
    message_id     SERIAL PRIMARY KEY,
    from_agent_id  INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    to_agent_id    INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    session_id     INT  REFERENCES argo_private.sessions(session_id) ON DELETE SET NULL,
    parent_task_id INT  REFERENCES argo_private.tasks(task_id) ON DELETE SET NULL,
    child_task_id  INT  REFERENCES argo_private.tasks(task_id) ON DELETE SET NULL,
    direction      TEXT NOT NULL CHECK (direction IN ('instruction','result')),
    status         TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','delivered','failed')),
    content        TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE argo_private.agent_messages IS
    'Messages between agents. instruction=delegation; result=subtask output returned to parent.';

-- -----------------------------------------------------------------------------
-- human_approvals: human-in-the-loop approval queue.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.human_approvals (
    approval_id           SERIAL PRIMARY KEY,
    task_id               INT  NOT NULL REFERENCES argo_private.tasks(task_id) ON DELETE CASCADE,
    session_id            INT  NOT NULL REFERENCES argo_private.sessions(session_id) ON DELETE CASCADE,
    requested_by_agent_id INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    reason                TEXT NOT NULL,
    status                TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','approved','rejected')),
    resolved_by           TEXT,
    resolved_at           TIMESTAMPTZ,
    resolution_note       TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- tool_registry: MCP-spec compliant tool definitions, plus custom extensions.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.tool_registry (
    tool_id               SERIAL PRIMARY KEY,

    -- MCP standard fields (1:1 with tools/list response)
    name                  TEXT  NOT NULL UNIQUE,
    description           TEXT  NOT NULL,
    input_schema          JSONB NOT NULL DEFAULT '{"type":"object","properties":{}}'::jsonb,

    -- Tool type discriminator
    tool_type             TEXT  NOT NULL
                          CHECK (tool_type IN ('mcp','sql','http','custom')),

    -- MCP-typed fields
    mcp_server_url        TEXT,
    mcp_server_name       TEXT,
    mcp_server_status     TEXT  DEFAULT 'unknown'
                          CHECK (mcp_server_status IN ('healthy','unhealthy','unknown')),
    mcp_last_health_check TIMESTAMPTZ,

    -- HTTP-typed fields
    http_endpoint         TEXT,
    http_method           TEXT  DEFAULT 'POST',
    http_headers          JSONB,

    -- Custom-typed fields
    custom_code           TEXT,
    runtime               TEXT,                  -- e.g. 'python', 'javascript'

    -- SQL-typed fields use the existing fn_execute_sql sandbox

    -- Vector search
    description_embedding vector,
    embedding_dims        INT,

    -- Common
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Validation
    CHECK (
        (tool_type = 'mcp'    AND mcp_server_url IS NOT NULL)
     OR (tool_type = 'http'   AND http_endpoint  IS NOT NULL)
     OR (tool_type = 'custom' AND custom_code    IS NOT NULL)
     OR (tool_type = 'sql')
    )
);
COMMENT ON TABLE argo_private.tool_registry IS
    'Tool catalogue. MCP-compliant input_schema with type-specific routing fields.';

-- -----------------------------------------------------------------------------
-- agent_tool_permissions: which agent can use which tool.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.agent_tool_permissions (
    agent_id   INT NOT NULL REFERENCES argo_private.agent_meta(agent_id)    ON DELETE CASCADE,
    tool_id    INT NOT NULL REFERENCES argo_private.tool_registry(tool_id)  ON DELETE CASCADE,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (agent_id, tool_id)
);

-- -----------------------------------------------------------------------------
-- tool_executions: audit log of tool calls.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.tool_executions (
    exec_id     BIGSERIAL PRIMARY KEY,
    task_id     INT  NOT NULL REFERENCES argo_private.tasks(task_id) ON DELETE CASCADE,
    tool_id     INT  NOT NULL REFERENCES argo_private.tool_registry(tool_id) ON DELETE CASCADE,
    input       JSONB,
    output      TEXT,
    error       TEXT,
    duration_ms INT,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- flow_registry: maps Langflow flow_name to ARGO agent.
-- We use flow_name (UNIQUE, stable) instead of flow_id, which changes on import.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.flow_registry (
    flow_id     SERIAL PRIMARY KEY,
    flow_name   TEXT NOT NULL UNIQUE,
    agent_id    INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    webhook_url TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- agent_events: monitoring event stream for Grafana.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.agent_events (
    event_id   BIGSERIAL PRIMARY KEY,
    agent_id   INT REFERENCES argo_private.agent_meta(agent_id) ON DELETE SET NULL,
    session_id INT REFERENCES argo_private.sessions(session_id) ON DELETE SET NULL,
    task_id    INT REFERENCES argo_private.tasks(task_id)       ON DELETE SET NULL,
    event_type TEXT NOT NULL
               CHECK (event_type IN (
                   'session_start','session_end',
                   'task_start','task_end',
                   'tool_call','tool_result',
                   'delegation','approval_request','approval_resolved',
                   'embedding_rotated'
               )),
    payload    JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE argo_private.agent_events IS
    'Event log for monitoring. Consider partitioning by created_at for retention.';

-- -----------------------------------------------------------------------------
-- sql_sandbox_allowlist: views accessible from fn_execute_sql.
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.sql_sandbox_allowlist (
    view_name   TEXT PRIMARY KEY,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- system_agent_configs: built-in system agents (compressor, embedder).
-- -----------------------------------------------------------------------------
CREATE TABLE argo_private.system_agent_configs (
    config_id         SERIAL PRIMARY KEY,
    agent_type        TEXT    NOT NULL UNIQUE
                      CHECK (agent_type IN ('compressor','embedder')),
    is_enabled        BOOLEAN NOT NULL DEFAULT FALSE,
    role_name         TEXT    REFERENCES argo_private.agent_meta(role_name) ON DELETE SET NULL ON UPDATE CASCADE,
    run_interval_secs INT     NOT NULL DEFAULT 3600 CHECK (run_interval_secs > 0),
    settings          JSONB   NOT NULL DEFAULT '{}',
    last_run_at       TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================================
-- 06. Views
-- =============================================================================

-- v_agent_context: current agent's profile + LLM config (scoped to session_user).
CREATE OR REPLACE VIEW argo_public.v_agent_context AS
SELECT am.agent_id, am.role_name, am.display_name, am.is_active,
       ap.profile_id, ap.agent_role, ap.system_prompt, ap.max_steps, ap.max_retries,
       lc.llm_config_id, lc.provider, lc.endpoint, lc.model_name,
       lc.api_key_ref, lc.temperature, lc.max_tokens, lc.request_options
FROM argo_private.agent_meta am
JOIN argo_private.agent_profile_assignments apa ON apa.role_name = am.role_name
JOIN argo_private.agent_profiles ap             ON ap.profile_id = apa.profile_id
JOIN argo_private.llm_configs lc                ON lc.llm_config_id = apa.llm_config_id
WHERE am.role_name = session_user::text AND am.is_active = TRUE;

-- v_my_tasks: tasks for the current agent, OR agent specified via SET ROLE.
CREATE OR REPLACE VIEW argo_public.v_my_tasks AS
SELECT t.task_id, t.session_id, t.status, t.input, t.output,
       t.retry_count, t.heartbeat_at, t.created_at, t.updated_at
FROM argo_private.tasks t
JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
WHERE am.role_name = session_user::text
   OR pg_has_role(session_user, 'argo_operator', 'MEMBER');

-- v_my_memory: scoped memory access.
CREATE OR REPLACE VIEW argo_public.v_my_memory AS
SELECT m.memory_id, m.session_id, m.content, m.embedding, m.embedding_dims, m.created_at
FROM argo_private.memory m
JOIN argo_private.agent_meta am ON am.agent_id = m.agent_id
WHERE am.role_name = session_user::text
   OR pg_has_role(session_user, 'argo_operator', 'MEMBER')
ORDER BY m.created_at DESC;

-- v_my_tools: tools the current agent is allowed to use.
CREATE OR REPLACE VIEW argo_public.v_my_tools AS
SELECT t.tool_id, t.name, t.description, t.input_schema, t.tool_type, t.is_active
FROM argo_private.tool_registry t
JOIN argo_private.agent_tool_permissions p ON p.tool_id = t.tool_id
JOIN argo_private.agent_meta am             ON am.agent_id = p.agent_id
WHERE (am.role_name = session_user::text
       OR pg_has_role(session_user, 'argo_operator', 'MEMBER'))
  AND t.is_active = TRUE;

-- v_session_progress: aggregated progress per session.
-- Visible to: session owner, any participant, or argo_operator.
CREATE OR REPLACE VIEW argo_public.v_session_progress AS
SELECT s.session_id, s.status, s.goal, s.started_at, s.completed_at,
       am.role_name, am.display_name,
       COUNT(t.task_id)                                                   AS total_tasks,
       COUNT(t.task_id) FILTER (WHERE t.status = 'completed')             AS completed_tasks,
       COUNT(t.task_id) FILTER (WHERE t.status = 'running')               AS running_tasks,
       COUNT(t.task_id) FILTER (WHERE t.status IN ('failed','cancelled')) AS failed_tasks
FROM argo_private.sessions s
JOIN argo_private.agent_meta am ON am.agent_id = s.agent_id
LEFT JOIN argo_private.tasks t ON t.session_id = s.session_id
WHERE am.role_name = session_user::text
   OR EXISTS (
       SELECT 1 FROM argo_private.session_participants sp
       JOIN argo_private.agent_meta am2 ON am2.agent_id = sp.agent_id
       WHERE sp.session_id = s.session_id AND am2.role_name = session_user::text
   )
   OR pg_has_role(session_user, 'argo_operator', 'MEMBER')
GROUP BY s.session_id, am.role_name, am.display_name;

-- v_session_audit: full audit log (operator only).
CREATE OR REPLACE VIEW argo_public.v_session_audit AS
SELECT s.session_id, s.status AS session_status, s.goal, s.final_answer,
       s.started_at, s.completed_at,
       am.role_name, am.display_name,
       t.task_id, t.status AS task_status, t.input AS task_input, t.output AS task_output,
       el.log_id, el.step_number, el.role AS log_role, el.content AS log_content,
       el.compressed_at, el.compression_quality,
       el.created_at AS log_created_at
FROM argo_private.sessions s
JOIN argo_private.agent_meta am ON am.agent_id = s.agent_id
LEFT JOIN argo_private.tasks t  ON t.session_id = s.session_id
LEFT JOIN argo_private.execution_logs el ON el.task_id = t.task_id
ORDER BY s.session_id, t.task_id, el.step_number;

-- v_ready_tasks: pending tasks whose dependencies are satisfied.
-- Scoped to session_user's agent_id (or all for argo_operator/argo_langflow).
CREATE OR REPLACE VIEW argo_public.v_ready_tasks AS
SELECT t.task_id, t.session_id, t.agent_id, t.status, t.input, t.created_at,
       am.role_name AS agent_role_name
FROM argo_private.tasks t
JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
WHERE t.status = 'pending'
  AND (
      am.role_name = session_user::text
      OR pg_has_role(session_user, 'argo_operator', 'MEMBER')
      OR pg_has_role(session_user, 'argo_langflow', 'MEMBER')
  )
  AND NOT EXISTS (
      SELECT 1 FROM argo_private.task_dependencies td
      JOIN argo_private.tasks dep ON dep.task_id = td.depends_on_task_id
      WHERE td.task_id = t.task_id AND dep.status <> 'completed'
  );

-- v_pending_approvals: approval requests waiting for human action.
CREATE OR REPLACE VIEW argo_public.v_pending_approvals AS
SELECT ha.approval_id, ha.task_id, ha.session_id, ha.reason, ha.created_at,
       am.role_name AS requested_by, am.display_name AS requested_by_name,
       t.input AS task_input, s.goal AS session_goal
FROM argo_private.human_approvals ha
JOIN argo_private.agent_meta am ON am.agent_id = ha.requested_by_agent_id
JOIN argo_private.tasks t       ON t.task_id   = ha.task_id
JOIN argo_private.sessions s    ON s.session_id = ha.session_id
WHERE ha.status = 'pending'
ORDER BY ha.created_at ASC;

-- v_tool_stats: aggregated tool usage for monitoring.
CREATE OR REPLACE VIEW argo_public.v_tool_stats AS
SELECT t.tool_id, t.name, t.tool_type, t.is_active,
       COUNT(te.exec_id)                                       AS total_calls,
       COUNT(te.exec_id) FILTER (WHERE te.error IS NOT NULL)   AS error_count,
       AVG(te.duration_ms)::INT                                AS avg_duration_ms,
       MAX(te.executed_at)                                     AS last_called_at
FROM argo_private.tool_registry t
LEFT JOIN argo_private.tool_executions te ON te.tool_id = t.tool_id
GROUP BY t.tool_id, t.name, t.tool_type, t.is_active;

-- v_agent_events: monitoring event stream with agent context.
CREATE OR REPLACE VIEW argo_public.v_agent_events AS
SELECT e.event_id, e.event_type, e.payload, e.created_at,
       e.session_id, e.task_id,
       am.agent_id, am.role_name, am.display_name
FROM argo_private.agent_events e
LEFT JOIN argo_private.agent_meta am ON am.agent_id = e.agent_id
ORDER BY e.created_at DESC;

-- v_compressible_logs: tasks eligible for log compression.
CREATE OR REPLACE VIEW argo_public.v_compressible_logs AS
SELECT t.task_id, t.session_id,
       COUNT(*)                                              AS total_steps,
       COUNT(*) FILTER (WHERE el.compressed_at IS NULL)     AS uncompressed_steps,
       COUNT(*) FILTER (WHERE el.compressed_at IS NOT NULL) AS compressed_steps
FROM argo_private.tasks t
JOIN argo_private.execution_logs el ON el.task_id = t.task_id
WHERE t.status IN ('completed','failed')
GROUP BY t.task_id, t.session_id
HAVING COUNT(*) >= COALESCE(
    (SELECT (settings->>'compress_after_steps')::int
     FROM argo_private.system_agent_configs WHERE agent_type = 'compressor'), 20)
   AND COUNT(*) FILTER (WHERE el.compressed_at IS NULL) > 0;

-- v_stale_tasks: running tasks with old heartbeats (recovery target).
CREATE OR REPLACE VIEW argo_public.v_stale_tasks AS
SELECT t.task_id, t.session_id, t.agent_id, t.status, t.input,
       t.heartbeat_at, t.retry_count, t.updated_at,
       EXTRACT(EPOCH FROM (now() - COALESCE(t.heartbeat_at, t.updated_at)))::INT AS stale_seconds
FROM argo_private.tasks t
WHERE t.status = 'running'
  AND COALESCE(t.heartbeat_at, t.updated_at) < (now() - INTERVAL '5 minutes');

-- v_reembedding_targets: rows whose embedding doesn't match active model.
CREATE OR REPLACE VIEW argo_public.v_reembedding_targets AS
SELECT 'memory' AS source, m.memory_id::text AS row_id, m.content,
       m.embedding_dims AS current_dims
FROM argo_private.memory m
CROSS JOIN argo_private.embedding_config ec
WHERE ec.is_active = TRUE
  AND (m.embedding IS NULL OR m.embedding_dims IS DISTINCT FROM ec.dimensions)
UNION ALL
SELECT 'tool_registry' AS source, t.tool_id::text AS row_id, t.description,
       t.embedding_dims AS current_dims
FROM argo_private.tool_registry t
CROSS JOIN argo_private.embedding_config ec
WHERE ec.is_active = TRUE
  AND t.is_active = TRUE
  AND (t.description_embedding IS NULL OR t.embedding_dims IS DISTINCT FROM ec.dimensions);
COMMENT ON VIEW argo_public.v_reembedding_targets IS
    'Rows whose embedding is missing or does not match the active model. Embedder flow polls this.';

-- v_system_agents: system agent status overview.
CREATE OR REPLACE VIEW argo_public.v_system_agents AS
SELECT sc.config_id, sc.agent_type, sc.is_enabled, sc.role_name,
       am.display_name, am.is_active AS agent_is_active,
       sc.run_interval_secs, sc.settings, sc.last_run_at,
       CASE WHEN sc.last_run_at IS NOT NULL
            THEN sc.last_run_at + (sc.run_interval_secs || ' seconds')::interval
            ELSE NULL END AS next_run_at,
       CASE
           WHEN sc.agent_type = 'compressor'
                THEN (SELECT COUNT(*) FROM argo_public.v_compressible_logs)
           WHEN sc.agent_type = 'embedder'
                THEN (SELECT COUNT(*) FROM argo_public.v_reembedding_targets)
           ELSE NULL
       END AS pending_targets,
       sc.updated_at
FROM argo_private.system_agent_configs sc
LEFT JOIN argo_private.agent_meta am ON am.role_name = sc.role_name;

-- =============================================================================
-- 07. Functions
-- =============================================================================

-- -----------------------------------------------------------------------------
-- fn_log_event: append-only event logging used internally by other functions.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_private.fn_log_event(
    p_agent_id   INT,
    p_session_id INT,
    p_task_id    INT,
    p_event_type TEXT,
    p_payload    JSONB DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
BEGIN
    INSERT INTO argo_private.agent_events
        (agent_id, session_id, task_id, event_type, payload)
    VALUES
        (p_agent_id, p_session_id, p_task_id, p_event_type, p_payload);
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_log_step: append a step to execution_logs.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_private.fn_log_step(
    p_task_id INT, p_step INT, p_role TEXT, p_content TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
BEGIN
    INSERT INTO argo_private.execution_logs (task_id, step_number, role, content)
    VALUES (p_task_id, p_step, p_role, p_content);
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_execute_sql: allowlisted read-only SQL sandbox.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_private.fn_execute_sql(p_sql TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_sql        TEXT;
    v_result     TEXT;
    v_table_name TEXT;
BEGIN
    -- Strip comments
    v_sql := regexp_replace(p_sql, '--[^\n]*', '', 'g');
    v_sql := regexp_replace(v_sql, '/\*.*?\*/', '', 'gs');
    v_sql := btrim(v_sql);

    IF v_sql = '' THEN
        RAISE EXCEPTION 'fn_execute_sql: empty SQL';
    END IF;
    IF position(';' IN v_sql) > 0 THEN
        RAISE EXCEPTION 'fn_execute_sql: multiple statements not allowed';
    END IF;
    IF NOT (v_sql ~* '^[[:space:]]*SELECT[[:space:]]') THEN
        RAISE EXCEPTION 'fn_execute_sql: only SELECT allowed (got: %)', left(v_sql, 50);
    END IF;

    v_table_name := lower(trim(substring(v_sql FROM '(?i)FROM[[:space:]]+([\w.]+)')));

    IF v_table_name IS NULL OR v_table_name = '' THEN
        RAISE EXCEPTION 'fn_execute_sql: cannot parse FROM clause';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM argo_private.sql_sandbox_allowlist
        WHERE lower(view_name) = v_table_name
    ) THEN
        RAISE EXCEPTION 'fn_execute_sql: view % not in sandbox allowlist', v_table_name;
    END IF;

    -- Execute with sandbox role
    SET LOCAL ROLE argo_sql_sandbox;
    EXECUTE 'SELECT json_agg(t)::text FROM (' || v_sql || ') t' INTO v_result;
    RESET ROLE;

    RETURN COALESCE(v_result, '[]');
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_search_memory: cosine-similarity search over memory.
-- Filters on embedding_dims = active model's dims to avoid mismatch errors.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_search_memory(
    p_query_embedding vector,
    p_agent_id        INT,
    p_limit           INT DEFAULT 5
)
RETURNS TABLE (memory_id INT, content TEXT, similarity FLOAT, created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = argo_private, public, pg_catalog AS $$
DECLARE
    v_active_dims INT;
BEGIN
    SELECT dimensions INTO v_active_dims
    FROM argo_private.embedding_config
    WHERE is_active = TRUE;

    IF v_active_dims IS NULL THEN
        RETURN;  -- no active embedding config; return empty
    END IF;

    RETURN QUERY
    SELECT m.memory_id, m.content,
           (1 - (m.embedding <=> p_query_embedding))::FLOAT AS similarity,
           m.created_at
    FROM argo_private.memory m
    WHERE m.agent_id = p_agent_id
      AND m.embedding IS NOT NULL
      AND m.embedding_dims = v_active_dims
    ORDER BY m.embedding <=> p_query_embedding
    LIMIT p_limit;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_search_tools: cosine-similarity search over tool_registry,
-- restricted to tools the agent has permission for.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_search_tools(
    p_query_embedding vector,
    p_agent_id        INT,
    p_limit           INT DEFAULT 5
)
RETURNS TABLE (tool_id INT, name TEXT, description TEXT,
               input_schema JSONB, tool_type TEXT, similarity FLOAT)
LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = argo_private, public, pg_catalog AS $$
DECLARE
    v_active_dims INT;
BEGIN
    SELECT dimensions INTO v_active_dims
    FROM argo_private.embedding_config
    WHERE is_active = TRUE;

    IF v_active_dims IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT t.tool_id, t.name, t.description, t.input_schema, t.tool_type::TEXT,
           (1 - (t.description_embedding <=> p_query_embedding))::FLOAT AS similarity
    FROM argo_private.tool_registry t
    JOIN argo_private.agent_tool_permissions p ON p.tool_id = t.tool_id
    WHERE p.agent_id = p_agent_id
      AND t.is_active = TRUE
      AND t.description_embedding IS NOT NULL
      AND t.embedding_dims = v_active_dims
    ORDER BY t.description_embedding <=> p_query_embedding
    LIMIT p_limit;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_build_messages: assemble system + history + agent_messages + current logs.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_private.fn_build_messages(p_task_id INT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_task     RECORD;
    v_sys      TEXT;
    v_history  JSONB;
    v_messages JSONB;
    v_cur_logs JSONB;
    v_msgs     JSONB;
BEGIN
    SELECT t.*, am.agent_id INTO v_task
    FROM argo_private.tasks t
    JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
    WHERE t.task_id = p_task_id;

    SELECT ap.system_prompt INTO v_sys
    FROM argo_private.agent_profile_assignments apa
    JOIN argo_private.agent_profiles ap ON ap.profile_id = apa.profile_id
    WHERE apa.role_name = (
        SELECT role_name FROM argo_private.agent_meta WHERE agent_id = v_task.agent_id
    );

    -- Completed task pairs in same session
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_array(
                jsonb_build_object('role','user',    'content', t_prev.input),
                jsonb_build_object('role','assistant','content', t_prev.output)
            )
            ORDER BY t_prev.task_id
        ),
        '[]'::jsonb
    ) INTO v_history
    FROM argo_private.tasks t_prev
    WHERE t_prev.session_id = v_task.session_id
      AND t_prev.task_id    < p_task_id
      AND t_prev.status     = 'completed'
      AND t_prev.output     IS NOT NULL;

    SELECT COALESCE(
        (SELECT jsonb_agg(elem)
         FROM jsonb_array_elements(v_history) AS outer_arr(pair),
              jsonb_array_elements(pair) AS elem),
        '[]'::jsonb
    ) INTO v_history;

    -- Subagent results addressed to this agent in this session
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'role','tool',
                'content',
                'Subagent result from ' || am2.display_name || ': ' || mm.content
            ) ORDER BY mm.created_at
        ),
        '[]'::jsonb
    ) INTO v_messages
    FROM argo_private.agent_messages mm
    JOIN argo_private.agent_meta am2 ON am2.agent_id = mm.from_agent_id
    WHERE mm.to_agent_id = v_task.agent_id
      AND mm.session_id  = v_task.session_id
      AND mm.direction   = 'result'
      AND mm.status      = 'delivered';

    -- Current task logs (assistant + tool round-trips)
    SELECT COALESCE(
        (SELECT jsonb_agg(
                    jsonb_build_object('role', el.role, 'content', el.content)
                    ORDER BY el.step_number
                )
         FROM argo_private.execution_logs el
         WHERE el.task_id = p_task_id
           AND el.role IN ('user','assistant','tool')),
        '[]'::jsonb
    ) INTO v_cur_logs;

    -- Prepend the user input if not yet logged
    IF NOT EXISTS (
        SELECT 1 FROM argo_private.execution_logs
        WHERE task_id = p_task_id AND role = 'user'
    ) THEN
        v_cur_logs := jsonb_build_array(
                          jsonb_build_object('role','user','content', v_task.input)
                      ) || v_cur_logs;
    END IF;

    v_msgs := jsonb_build_array(
                  jsonb_build_object('role','system','content', COALESCE(v_sys, ''))
              )
              || v_history
              || v_messages
              || v_cur_logs;

    RETURN v_msgs;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_next_step: control plane decision for the next action.
-- Optionally accepts a query embedding; if provided, fn_search_memory results
-- are appended to the system prompt.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_next_step(
    p_task_id         INT,
    p_query_embedding vector DEFAULT NULL,
    p_memory_limit    INT    DEFAULT 5
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_task        RECORD;
    v_max_steps   INT;
    v_cur_steps   INT;
    v_messages    JSONB;
    v_llm_config  JSONB;
    v_tools       JSONB;
    v_memory_ctx  TEXT;
    v_memory_rows JSONB;
BEGIN
    SELECT t.*, am.agent_id INTO v_task
    FROM argo_private.tasks t
    JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
    WHERE t.task_id = p_task_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_next_step: task_id % not found', p_task_id;
    END IF;

    -- Terminal states
    IF v_task.status IN ('completed','failed','cancelled') THEN
        RETURN jsonb_build_object('action','done','output', v_task.output);
    END IF;

    -- Waiting on subagent: not ready to call LLM yet
    IF v_task.status = 'waiting' THEN
        RETURN jsonb_build_object(
            'action','wait_tasks',
            'task_id', p_task_id,
            'pending_task_ids', (
                SELECT COALESCE(jsonb_agg(td.depends_on_task_id), '[]'::jsonb)
                FROM argo_private.task_dependencies td
                JOIN argo_private.tasks dep ON dep.task_id = td.depends_on_task_id
                WHERE td.task_id = p_task_id AND dep.status NOT IN ('completed','failed','cancelled')
            )
        );
    END IF;

    -- Mark running, set heartbeat
    UPDATE argo_private.tasks
       SET status = 'running', heartbeat_at = now(), updated_at = now()
     WHERE task_id = p_task_id AND status IN ('pending','waiting');

    -- Step budget
    SELECT ap.max_steps INTO v_max_steps
    FROM argo_private.agent_profile_assignments apa
    JOIN argo_private.agent_profiles ap ON ap.profile_id = apa.profile_id
    WHERE apa.role_name = (SELECT role_name FROM argo_private.agent_meta WHERE agent_id = v_task.agent_id);

    SELECT COUNT(*) INTO v_cur_steps
    FROM argo_private.execution_logs
    WHERE task_id = p_task_id AND role = 'assistant';

    IF v_cur_steps >= v_max_steps THEN
        PERFORM argo_public.fn_submit_result(
            p_task_id,
            'Max steps (' || v_max_steps || ') reached.',
            TRUE
        );
        RETURN jsonb_build_object('action','done');
    END IF;

    -- Optional memory injection
    IF p_query_embedding IS NOT NULL THEN
        SELECT COALESCE(
            jsonb_agg(jsonb_build_object('content', m.content, 'similarity', m.similarity)
                      ORDER BY m.similarity DESC),
            '[]'::jsonb
        ) INTO v_memory_rows
        FROM argo_public.fn_search_memory(p_query_embedding, v_task.agent_id, p_memory_limit) m;
    ELSE
        v_memory_rows := '[]'::jsonb;
    END IF;

    -- Build messages
    v_messages := argo_private.fn_build_messages(p_task_id);

    -- LLM config
    SELECT jsonb_build_object(
        'provider', lc.provider, 'endpoint', lc.endpoint, 'model_name', lc.model_name,
        'api_key_ref', lc.api_key_ref, 'temperature', lc.temperature,
        'max_tokens', lc.max_tokens, 'request_options', lc.request_options
    ) INTO v_llm_config
    FROM argo_private.llm_configs lc
    JOIN argo_private.agent_profile_assignments apa ON lc.llm_config_id = apa.llm_config_id
    JOIN argo_private.agent_meta am ON am.role_name = apa.role_name
    WHERE am.agent_id = v_task.agent_id;

    -- Tools available to this agent (MCP-spec shape)
    SELECT COALESCE(
        jsonb_agg(jsonb_build_object(
            'name', t.name,
            'description', t.description,
            'input_schema', t.input_schema,
            'tool_type', t.tool_type
        )),
        '[]'::jsonb
    ) INTO v_tools
    FROM argo_private.tool_registry t
    JOIN argo_private.agent_tool_permissions p ON p.tool_id = t.tool_id
    WHERE p.agent_id = v_task.agent_id AND t.is_active = TRUE;

    -- Log task_start event (only first time)
    IF v_cur_steps = 0 THEN
        PERFORM argo_private.fn_log_event(
            v_task.agent_id, v_task.session_id, p_task_id, 'task_start',
            jsonb_build_object('input', v_task.input)
        );
    END IF;

    RETURN jsonb_build_object(
        'action',     'call_llm',
        'task_id',    p_task_id,
        'agent_id',   v_task.agent_id,
        'session_id', v_task.session_id,
        'messages',   v_messages,
        'llm_config', v_llm_config,
        'tools',      v_tools,
        'memory',     v_memory_rows
    );
END;
$$;
COMMENT ON FUNCTION argo_public.fn_next_step(INT, vector, INT) IS
    'Control plane: returns {action:call_llm,...}, {action:wait_tasks,...}, or {action:done}.';

-- -----------------------------------------------------------------------------
-- fn_submit_result: ingest LLM response, decide next action.
-- Action vocabulary (from LLM response):
--   finish          -> task completed; need_embedding flag returned
--   call_tool       -> route to Langflow tool router (or run sql tool inline)
--   delegate        -> create subtask for another agent; this task waits
--   request_approval-> create human approval; this task waits
--   (anything else) -> continue (LLM should refine)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_submit_result(
    p_task_id   INT,
    p_response  TEXT,
    p_is_final  BOOLEAN DEFAULT FALSE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_task          RECORD;
    v_parsed        JSONB;
    v_action        TEXT;
    v_step          INT;
    v_ans           TEXT;
    v_sql_result    TEXT;
    v_tool          RECORD;
    v_tool_name     TEXT;
    v_tool_args     JSONB;
    v_to_role       TEXT;
    v_to_agent_id   INT;
    v_subtask_id    INT;
    v_approval_id   INT;
    v_session_active BOOLEAN;
BEGIN
    SELECT * INTO v_task FROM argo_private.tasks WHERE task_id = p_task_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_submit_result: task_id % not found', p_task_id;
    END IF;

    -- Append assistant log
    SELECT COALESCE(MAX(step_number), 0) + 1 INTO v_step
    FROM argo_private.execution_logs WHERE task_id = p_task_id;

    PERFORM argo_private.fn_log_step(p_task_id, v_step, 'assistant', p_response);

    -- Update heartbeat
    UPDATE argo_private.tasks SET heartbeat_at = now() WHERE task_id = p_task_id;

    ---------------------------------------------------------------------------
    -- Forced finalization (e.g. max_steps in fn_next_step)
    ---------------------------------------------------------------------------
    IF p_is_final THEN
        UPDATE argo_private.tasks
           SET status = 'completed', output = p_response, updated_at = now()
         WHERE task_id = p_task_id;

        PERFORM argo_private.fn_log_event(
            v_task.agent_id, v_task.session_id, p_task_id, 'task_end',
            jsonb_build_object('forced', TRUE)
        );

        RETURN jsonb_build_object('action','done','output', p_response, 'need_embedding', FALSE);
    END IF;

    ---------------------------------------------------------------------------
    -- Parse response. If not valid JSON, treat as 'finish'.
    ---------------------------------------------------------------------------
    BEGIN
        v_parsed := p_response::jsonb;
    EXCEPTION WHEN OTHERS THEN
        v_parsed := jsonb_build_object('action','finish','final_answer', p_response);
    END;

    v_action := v_parsed->>'action';

    ---------------------------------------------------------------------------
    -- finish
    ---------------------------------------------------------------------------
    IF v_action = 'finish' THEN
        v_ans := v_parsed->>'final_answer';

        UPDATE argo_private.tasks
           SET status = 'completed', output = v_ans, updated_at = now()
         WHERE task_id = p_task_id;

        -- Close session if all tasks terminal AND owner agent finished
        SELECT EXISTS (
            SELECT 1 FROM argo_private.tasks
            WHERE session_id = v_task.session_id
              AND status NOT IN ('completed','failed','cancelled')
        ) INTO v_session_active;

        IF NOT v_session_active THEN
            UPDATE argo_private.sessions
               SET status = 'completed', final_answer = v_ans, completed_at = now()
             WHERE session_id = v_task.session_id;

            PERFORM argo_private.fn_log_event(
                v_task.agent_id, v_task.session_id, p_task_id, 'session_end',
                jsonb_build_object('final_answer', left(COALESCE(v_ans,''), 500))
            );
        END IF;

        -- If this is a subtask, deliver result to parent agent
        DECLARE
            v_parent RECORD;
        BEGIN
            SELECT mm.* INTO v_parent
            FROM argo_private.agent_messages mm
            WHERE mm.child_task_id = p_task_id
              AND mm.direction = 'instruction';

            IF FOUND THEN
                INSERT INTO argo_private.agent_messages
                    (from_agent_id, to_agent_id, session_id,
                     parent_task_id, child_task_id,
                     direction, status, content)
                VALUES
                    (v_task.agent_id, v_parent.from_agent_id, v_task.session_id,
                     v_parent.parent_task_id, p_task_id,
                     'result', 'delivered', v_ans);

                -- If parent task was waiting and all deps now complete -> pending
                UPDATE argo_private.tasks
                   SET status = 'pending', updated_at = now()
                 WHERE task_id = v_parent.parent_task_id
                   AND status = 'waiting'
                   AND NOT EXISTS (
                       SELECT 1 FROM argo_private.task_dependencies td
                       JOIN argo_private.tasks dep ON dep.task_id = td.depends_on_task_id
                       WHERE td.task_id = v_parent.parent_task_id
                         AND dep.status NOT IN ('completed','failed','cancelled')
                   );
            END IF;
        END;

        PERFORM argo_private.fn_log_event(
            v_task.agent_id, v_task.session_id, p_task_id, 'task_end',
            jsonb_build_object('output_preview', left(COALESCE(v_ans,''), 200))
        );

        RETURN jsonb_build_object(
            'action','done',
            'output', v_ans,
            'need_embedding', TRUE,
            'agent_id', v_task.agent_id,
            'session_id', v_task.session_id
        );

    ---------------------------------------------------------------------------
    -- call_tool
    ---------------------------------------------------------------------------
    ELSIF v_action = 'call_tool' THEN
        v_tool_name := v_parsed->>'tool_name';
        v_tool_args := COALESCE(v_parsed->'args', '{}'::jsonb);

        IF v_tool_name IS NULL THEN
            PERFORM argo_private.fn_log_step(p_task_id, v_step + 1, 'tool',
                'TOOL ERROR: tool_name missing in response');
            RETURN jsonb_build_object('action','continue');
        END IF;

        SELECT t.* INTO v_tool
        FROM argo_private.tool_registry t
        JOIN argo_private.agent_tool_permissions p ON p.tool_id = t.tool_id
        WHERE p.agent_id = v_task.agent_id
          AND t.name = v_tool_name
          AND t.is_active = TRUE;

        IF NOT FOUND THEN
            PERFORM argo_private.fn_log_step(p_task_id, v_step + 1, 'tool',
                'TOOL ERROR: tool not found or not permitted: ' || v_tool_name);
            RETURN jsonb_build_object('action','continue');
        END IF;

        PERFORM argo_private.fn_log_event(
            v_task.agent_id, v_task.session_id, p_task_id, 'tool_call',
            jsonb_build_object('tool_name', v_tool_name, 'tool_type', v_tool.tool_type)
        );

        -- SQL tool: execute inline (in DB)
        IF v_tool.tool_type = 'sql' THEN
            BEGIN
                v_sql_result := argo_private.fn_execute_sql(v_tool_args->>'sql');
                INSERT INTO argo_private.tool_executions
                    (task_id, tool_id, input, output, duration_ms)
                VALUES
                    (p_task_id, v_tool.tool_id, v_tool_args, v_sql_result, NULL);
            EXCEPTION WHEN OTHERS THEN
                v_sql_result := 'SQL ERROR: ' || SQLERRM;
                INSERT INTO argo_private.tool_executions
                    (task_id, tool_id, input, error)
                VALUES
                    (p_task_id, v_tool.tool_id, v_tool_args, SQLERRM);
            END;

            PERFORM argo_private.fn_log_step(p_task_id, v_step + 1, 'tool', v_sql_result);
            RETURN jsonb_build_object('action','continue');
        END IF;

        -- Non-SQL tools: hand back to Langflow for execution
        RETURN jsonb_build_object(
            'action','invoke_tool',
            'task_id', p_task_id,
            'tool', jsonb_build_object(
                'tool_id', v_tool.tool_id,
                'name', v_tool.name,
                'tool_type', v_tool.tool_type,
                'mcp_server_url', v_tool.mcp_server_url,
                'mcp_server_name', v_tool.mcp_server_name,
                'http_endpoint', v_tool.http_endpoint,
                'http_method', v_tool.http_method,
                'http_headers', v_tool.http_headers,
                'custom_code', v_tool.custom_code,
                'runtime', v_tool.runtime,
                'input_schema', v_tool.input_schema
            ),
            'args', v_tool_args
        );

    ---------------------------------------------------------------------------
    -- delegate (multi-agent)
    ---------------------------------------------------------------------------
    ELSIF v_action = 'delegate' THEN
        v_to_role := v_parsed->>'to_agent';

        SELECT agent_id INTO v_to_agent_id
        FROM argo_private.agent_meta
        WHERE role_name = v_to_role AND is_active = TRUE;

        IF v_to_agent_id IS NULL THEN
            PERFORM argo_private.fn_log_step(p_task_id, v_step + 1, 'tool',
                'DELEGATE ERROR: agent not found: ' || COALESCE(v_to_role, '(null)'));
            RETURN jsonb_build_object('action','continue');
        END IF;

        -- Add to session participants
        INSERT INTO argo_private.session_participants (session_id, agent_id)
        VALUES (v_task.session_id, v_to_agent_id)
        ON CONFLICT DO NOTHING;

        -- Create subtask
        INSERT INTO argo_private.tasks (session_id, agent_id, status, input)
        VALUES (v_task.session_id, v_to_agent_id, 'pending', v_parsed->>'task')
        RETURNING task_id INTO v_subtask_id;

        -- Dependency: parent waits for child
        INSERT INTO argo_private.task_dependencies (task_id, depends_on_task_id)
        VALUES (p_task_id, v_subtask_id);

        -- Mark parent as waiting
        UPDATE argo_private.tasks
           SET status = 'waiting', updated_at = now()
         WHERE task_id = p_task_id;

        -- Record the instruction
        INSERT INTO argo_private.agent_messages
            (from_agent_id, to_agent_id, session_id,
             parent_task_id, child_task_id,
             direction, status, content)
        VALUES
            (v_task.agent_id, v_to_agent_id, v_task.session_id,
             p_task_id, v_subtask_id,
             'instruction', 'delivered', v_parsed->>'task');

        PERFORM argo_private.fn_log_event(
            v_task.agent_id, v_task.session_id, p_task_id, 'delegation',
            jsonb_build_object('to_agent', v_to_role, 'subtask_id', v_subtask_id)
        );

        RETURN jsonb_build_object(
            'action','wait_tasks',
            'task_id', p_task_id,
            'pending_task_ids', jsonb_build_array(v_subtask_id)
        );

    ---------------------------------------------------------------------------
    -- request_approval
    ---------------------------------------------------------------------------
    ELSIF v_action = 'request_approval' THEN
        INSERT INTO argo_private.human_approvals
            (task_id, session_id, requested_by_agent_id, reason)
        VALUES
            (p_task_id, v_task.session_id, v_task.agent_id, v_parsed->>'reason')
        RETURNING approval_id INTO v_approval_id;

        UPDATE argo_private.tasks
           SET status = 'waiting', updated_at = now()
         WHERE task_id = p_task_id;

        PERFORM argo_private.fn_log_event(
            v_task.agent_id, v_task.session_id, p_task_id, 'approval_request',
            jsonb_build_object('approval_id', v_approval_id, 'reason', v_parsed->>'reason')
        );

        RETURN jsonb_build_object(
            'action','wait_approval',
            'task_id', p_task_id,
            'approval_id', v_approval_id
        );

    ---------------------------------------------------------------------------
    -- Anything else: continue and let LLM refine
    ---------------------------------------------------------------------------
    ELSE
        RETURN jsonb_build_object('action','continue');
    END IF;
END;
$$;
COMMENT ON FUNCTION argo_public.fn_submit_result(INT, TEXT, BOOLEAN) IS
    'Ingests LLM response and decides next action: continue/done/invoke_tool/wait_tasks/wait_approval.';

-- -----------------------------------------------------------------------------
-- run_agent: enqueue a new task. Allowed for the agent itself OR
--            for argo_operator / argo_langflow acting on behalf of the agent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.run_agent(
    p_agent_role  TEXT,
    p_task        TEXT,
    p_session_id  INT  DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_agent_id   INT;
    v_session_id INT;
    v_task_id    INT;
BEGIN
    -- session_user must equal the agent OR be a privileged role
    IF session_user::text <> p_agent_role
       AND NOT pg_has_role(session_user, 'argo_operator', 'MEMBER')
       AND NOT pg_has_role(session_user, 'argo_langflow', 'MEMBER') THEN
        RAISE EXCEPTION 'run_agent: permission denied — session_user(%) cannot run as agent(%)',
            session_user, p_agent_role;
    END IF;

    SELECT agent_id INTO v_agent_id
    FROM argo_private.agent_meta
    WHERE role_name = p_agent_role AND is_active = TRUE;

    IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'run_agent: agent not found or inactive: %', p_agent_role;
    END IF;

    IF p_session_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM argo_private.sessions
            WHERE session_id = p_session_id AND agent_id = v_agent_id
        ) THEN
            RAISE EXCEPTION 'run_agent: session % does not belong to agent %', p_session_id, p_agent_role;
        END IF;
        v_session_id := p_session_id;
    ELSE
        INSERT INTO argo_private.sessions (agent_id, status, goal)
        VALUES (v_agent_id, 'active', p_task)
        RETURNING session_id INTO v_session_id;

        INSERT INTO argo_private.session_participants (session_id, agent_id)
        VALUES (v_session_id, v_agent_id)
        ON CONFLICT DO NOTHING;

        PERFORM argo_private.fn_log_event(
            v_agent_id, v_session_id, NULL, 'session_start',
            jsonb_build_object('goal', p_task)
        );
    END IF;

    INSERT INTO argo_private.tasks (session_id, agent_id, status, input)
    VALUES (v_session_id, v_agent_id, 'pending', p_task)
    RETURNING task_id INTO v_task_id;

    RETURN jsonb_build_object(
        'task_id', v_task_id,
        'session_id', v_session_id,
        'agent_id', v_agent_id
    );
END;
$$;
COMMENT ON FUNCTION argo_public.run_agent(TEXT, TEXT, INT) IS
    'Enqueue a task for the given agent. Returns task_id and session_id.';

-- -----------------------------------------------------------------------------
-- fn_resolve_approval: human approves or rejects a pending approval.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_resolve_approval(
    p_approval_id INT,
    p_status      TEXT,
    p_note        TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_approval RECORD;
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER')
       AND NOT pg_has_role(session_user, 'argo_langflow', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_resolve_approval: privileged role required';
    END IF;

    IF p_status NOT IN ('approved','rejected') THEN
        RAISE EXCEPTION 'fn_resolve_approval: status must be approved or rejected';
    END IF;

    SELECT * INTO v_approval FROM argo_private.human_approvals
    WHERE approval_id = p_approval_id AND status = 'pending';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_resolve_approval: approval % not pending', p_approval_id;
    END IF;

    UPDATE argo_private.human_approvals
       SET status = p_status,
           resolved_by = session_user::text,
           resolved_at = now(),
           resolution_note = p_note
     WHERE approval_id = p_approval_id;

    -- Resume task: approved -> pending; rejected -> failed
    IF p_status = 'approved' THEN
        UPDATE argo_private.tasks
           SET status = 'pending', updated_at = now()
         WHERE task_id = v_approval.task_id AND status = 'waiting';
    ELSE
        UPDATE argo_private.tasks
           SET status = 'failed',
               output = COALESCE(p_note, 'Rejected by human reviewer'),
               updated_at = now()
         WHERE task_id = v_approval.task_id;
    END IF;

    PERFORM argo_private.fn_log_event(
        v_approval.requested_by_agent_id, v_approval.session_id, v_approval.task_id,
        'approval_resolved',
        jsonb_build_object('approval_id', p_approval_id, 'status', p_status)
    );

    RETURN jsonb_build_object(
        'approval_id', p_approval_id,
        'status', p_status,
        'task_id', v_approval.task_id
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- create_agent: PG role + LLM config + profile + meta in one shot.
-- p_config JSONB:
--   name, agent_role, provider, model_name (required)
--   endpoint, api_key_ref, temperature, max_tokens, request_options (optional)
--   system_prompt, max_steps, max_retries (optional)
--   password (optional; auto-generated if absent)
--   tool_ids INT[] (optional; granted permissions)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.create_agent(
    p_role_name TEXT,
    p_config    JSONB
)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_config_id  INT;
    v_profile_id INT;
    v_agent_id   INT;
    v_password   TEXT;
    v_tool_ids   INT[];
    v_tool       INT;
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'create_agent: argo_operator required';
    END IF;

    IF p_config->>'name' IS NULL OR p_config->>'agent_role' IS NULL
       OR p_config->>'provider' IS NULL OR p_config->>'model_name' IS NULL THEN
        RAISE EXCEPTION 'create_agent: name, agent_role, provider, model_name required';
    END IF;

    PERFORM (p_config->>'agent_role')::argo_public.agent_role_type;
    PERFORM (p_config->>'provider')::argo_public.llm_provider;

    v_password := COALESCE(
        p_config->>'password',
        encode(sha256((random()::text || clock_timestamp()::text)::bytea), 'hex')
    );

    EXECUTE format(
        'CREATE ROLE %I WITH LOGIN PASSWORD %L INHERIT IN ROLE argo_agent_base',
        p_role_name, v_password
    );

    INSERT INTO argo_private.llm_configs (
        provider, endpoint, model_name, api_key_ref,
        temperature, max_tokens, request_options
    ) VALUES (
        p_config->>'provider',
        COALESCE(p_config->>'endpoint', ''),
        p_config->>'model_name',
        p_config->>'api_key_ref',
        COALESCE((p_config->>'temperature')::float, 0.7),
        COALESCE((p_config->>'max_tokens')::int, 4096),
        p_config->'request_options'
    ) RETURNING llm_config_id INTO v_config_id;

    INSERT INTO argo_private.agent_profiles (
        name, agent_role, system_prompt, max_steps, max_retries
    ) VALUES (
        p_config->>'name',
        p_config->>'agent_role',
        COALESCE(p_config->>'system_prompt', ''),
        COALESCE((p_config->>'max_steps')::int, 10),
        COALESCE((p_config->>'max_retries')::int, 3)
    ) RETURNING profile_id INTO v_profile_id;

    INSERT INTO argo_private.agent_meta (role_name, display_name)
    VALUES (p_role_name, p_config->>'name')
    RETURNING agent_id INTO v_agent_id;

    INSERT INTO argo_private.agent_profile_assignments (role_name, profile_id, llm_config_id)
    VALUES (p_role_name, v_profile_id, v_config_id);

    -- Optional tool permissions
    IF p_config ? 'tool_ids' THEN
        SELECT array(SELECT jsonb_array_elements_text(p_config->'tool_ids')::int)
            INTO v_tool_ids;
        FOREACH v_tool IN ARRAY v_tool_ids LOOP
            INSERT INTO argo_private.agent_tool_permissions (agent_id, tool_id)
            VALUES (v_agent_id, v_tool)
            ON CONFLICT DO NOTHING;
        END LOOP;
    END IF;

    RETURN 'Agent created: ' || p_role_name || ' (password: ' || v_password || ')';
EXCEPTION
    WHEN duplicate_object THEN RAISE EXCEPTION 'create_agent: role % already exists', p_role_name;
    WHEN unique_violation  THEN RAISE EXCEPTION 'create_agent: name or role already exists';
END;
$$;

-- -----------------------------------------------------------------------------
-- drop_agent: remove agent and PG role.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.drop_agent(p_role_name TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'drop_agent: argo_operator required';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM argo_private.agent_meta WHERE role_name = p_role_name) THEN
        RAISE EXCEPTION 'drop_agent: agent not found: %', p_role_name;
    END IF;

    UPDATE argo_private.system_agent_configs SET role_name = NULL WHERE role_name = p_role_name;
    DELETE FROM argo_private.agent_meta WHERE role_name = p_role_name;
    EXECUTE format('DROP ROLE IF EXISTS %I', p_role_name);

    RETURN 'Agent dropped: ' || p_role_name;
END;
$$;

-- -----------------------------------------------------------------------------
-- list_agents: agent overview.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.list_agents()
RETURNS TABLE (
    agent_id     INT,
    role_name    TEXT,
    display_name TEXT,
    agent_role   TEXT,
    provider     TEXT,
    model_name   TEXT,
    is_active    BOOLEAN,
    created_at   TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
    SELECT am.agent_id, am.role_name, am.display_name, ap.agent_role,
           lc.provider, lc.model_name, am.is_active, am.created_at
    FROM argo_private.agent_meta am
    JOIN argo_private.agent_profile_assignments apa ON apa.role_name = am.role_name
    JOIN argo_private.agent_profiles ap             ON ap.profile_id = apa.profile_id
    JOIN argo_private.llm_configs lc                ON lc.llm_config_id = apa.llm_config_id
    ORDER BY am.created_at;
$$;

-- -----------------------------------------------------------------------------
-- list_sessions / get_session: read helpers.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.list_sessions(p_agent_role TEXT DEFAULT NULL)
RETURNS TABLE (
    session_id   INT,
    agent_role   TEXT,
    status       TEXT,
    goal         TEXT,
    started_at   TIMESTAMPTZ,
    completed_at TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
    SELECT s.session_id, am.role_name, s.status, s.goal, s.started_at, s.completed_at
    FROM argo_private.sessions s
    JOIN argo_private.agent_meta am ON am.agent_id = s.agent_id
    WHERE p_agent_role IS NULL OR am.role_name = p_agent_role
    ORDER BY s.started_at DESC;
$$;

CREATE OR REPLACE FUNCTION argo_public.get_session(p_session_id INT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'session', to_jsonb(s),
        'tasks',  COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.task_id)
                            FROM argo_private.tasks t
                            WHERE t.session_id = s.session_id), '[]'::jsonb),
        'participants', COALESCE((SELECT jsonb_agg(am.role_name)
                                  FROM argo_private.session_participants sp
                                  JOIN argo_private.agent_meta am ON am.agent_id = sp.agent_id
                                  WHERE sp.session_id = s.session_id), '[]'::jsonb)
    ) INTO v_result
    FROM argo_private.sessions s
    WHERE s.session_id = p_session_id;

    RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_register_tool: insert into tool_registry.
-- p_config JSONB:
--   name, description, tool_type (required)
--   input_schema (default: empty object)
--   mcp_server_url, mcp_server_name (for tool_type='mcp')
--   http_endpoint, http_method, http_headers (for tool_type='http')
--   custom_code, runtime (for tool_type='custom')
-- Embedding is set later by the embedder flow.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_register_tool(p_config JSONB)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
DECLARE
    v_tool_id INT;
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_register_tool: argo_operator required';
    END IF;

    INSERT INTO argo_private.tool_registry (
        name, description, input_schema, tool_type,
        mcp_server_url, mcp_server_name,
        http_endpoint, http_method, http_headers,
        custom_code, runtime
    ) VALUES (
        p_config->>'name',
        p_config->>'description',
        COALESCE(p_config->'input_schema', '{"type":"object","properties":{}}'::jsonb),
        p_config->>'tool_type',
        p_config->>'mcp_server_url',
        p_config->>'mcp_server_name',
        p_config->>'http_endpoint',
        COALESCE(p_config->>'http_method', 'POST'),
        p_config->'http_headers',
        p_config->>'custom_code',
        p_config->>'runtime'
    ) RETURNING tool_id INTO v_tool_id;

    RETURN v_tool_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_grant_tool / fn_revoke_tool
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_grant_tool(p_agent_id INT, p_tool_id INT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_grant_tool: argo_operator required';
    END IF;
    INSERT INTO argo_private.agent_tool_permissions (agent_id, tool_id)
    VALUES (p_agent_id, p_tool_id) ON CONFLICT DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION argo_public.fn_revoke_tool(p_agent_id INT, p_tool_id INT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_revoke_tool: argo_operator required';
    END IF;
    DELETE FROM argo_private.agent_tool_permissions
    WHERE agent_id = p_agent_id AND tool_id = p_tool_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_set_tool_embedding: called by embedder flow after generating an embedding.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_set_tool_embedding(
    p_tool_id   INT,
    p_embedding vector,
    p_dims      INT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER')
       AND NOT pg_has_role(session_user, 'argo_langflow', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_set_tool_embedding: privileged role required';
    END IF;

    UPDATE argo_private.tool_registry
       SET description_embedding = p_embedding,
           embedding_dims = p_dims,
           updated_at = now()
     WHERE tool_id = p_tool_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_set_memory_embedding: called by embedder flow.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_set_memory_embedding(
    p_memory_id INT,
    p_embedding vector,
    p_dims      INT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER')
       AND NOT pg_has_role(session_user, 'argo_langflow', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_set_memory_embedding: privileged role required';
    END IF;

    UPDATE argo_private.memory
       SET embedding = p_embedding, embedding_dims = p_dims
     WHERE memory_id = p_memory_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_insert_memory: store a finished task as memory (called by Langflow).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_insert_memory(
    p_agent_id   INT,
    p_session_id INT,
    p_content    TEXT,
    p_embedding  vector,
    p_dims       INT
) RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
DECLARE v_id INT;
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER')
       AND NOT pg_has_role(session_user, 'argo_langflow', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_insert_memory: privileged role required';
    END IF;

    INSERT INTO argo_private.memory (agent_id, session_id, content, embedding, embedding_dims)
    VALUES (p_agent_id, p_session_id, p_content, p_embedding, p_dims)
    RETURNING memory_id INTO v_id;

    RETURN v_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- rotate_embedding_model: switch active embedding config.
-- Existing vectors are NOT cleared; they're naturally excluded from search by
-- embedding_dims mismatch and can be reembedded by the embedder flow.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.rotate_embedding_model(
    p_model_name TEXT,
    p_dimensions INT,
    p_endpoint   TEXT
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'rotate_embedding_model: argo_operator required';
    END IF;

    UPDATE argo_private.embedding_config SET is_active = FALSE WHERE is_active = TRUE;

    INSERT INTO argo_private.embedding_config (model_name, dimensions, endpoint, is_active)
    VALUES (p_model_name, p_dimensions, p_endpoint, TRUE);

    PERFORM argo_private.fn_log_event(
        NULL, NULL, NULL, 'embedding_rotated',
        jsonb_build_object('model', p_model_name, 'dims', p_dimensions)
    );

    RETURN format('Embedding model rotated to %s (%s dims). Run embedder flow to reembed existing rows.',
                  p_model_name, p_dimensions);
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_recover_stale_tasks: revert long-stalled running tasks back to pending.
-- Called periodically (e.g. every 5 minutes by a maintenance flow or cron).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_recover_stale_tasks(
    p_threshold_seconds INT DEFAULT 300
) RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
DECLARE v_count INT;
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER')
       AND NOT pg_has_role(session_user, 'argo_langflow', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_recover_stale_tasks: privileged role required';
    END IF;

    WITH stale AS (
        SELECT task_id, retry_count
        FROM argo_private.tasks
        WHERE status = 'running'
          AND COALESCE(heartbeat_at, updated_at)
              < (now() - (p_threshold_seconds || ' seconds')::interval)
    ),
    updated AS (
        UPDATE argo_private.tasks t
           SET status = CASE
                          WHEN t.retry_count + 1 > (
                              SELECT ap.max_retries
                              FROM argo_private.agent_profile_assignments apa
                              JOIN argo_private.agent_profiles ap ON ap.profile_id = apa.profile_id
                              JOIN argo_private.agent_meta am ON am.role_name = apa.role_name
                              WHERE am.agent_id = t.agent_id
                          ) THEN 'failed'
                          ELSE 'pending'
                        END,
               retry_count = t.retry_count + 1,
               updated_at = now()
         WHERE t.task_id IN (SELECT task_id FROM stale)
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_count FROM updated;

    RETURN v_count;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_register_flow: register a Langflow flow under a stable name.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_register_flow(
    p_flow_name   TEXT,
    p_agent_id    INT,
    p_webhook_url TEXT DEFAULT NULL
) RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
DECLARE v_id INT;
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_register_flow: argo_operator required';
    END IF;

    INSERT INTO argo_private.flow_registry (flow_name, agent_id, webhook_url)
    VALUES (p_flow_name, p_agent_id, p_webhook_url)
    ON CONFLICT (flow_name) DO UPDATE
        SET agent_id = EXCLUDED.agent_id,
            webhook_url = EXCLUDED.webhook_url
    RETURNING flow_id INTO v_id;

    RETURN v_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_purge_compressed_logs: operator-only, deletes compressed logs.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_purge_compressed_logs(
    p_task_id INT,
    p_quality_threshold FLOAT DEFAULT 0.9
)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
DECLARE v_deleted INT;
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_purge_compressed_logs: argo_operator required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM argo_private.execution_logs
        WHERE task_id = p_task_id
          AND (compressed_at IS NULL OR compression_quality < p_quality_threshold)
    ) THEN
        RAISE EXCEPTION 'fn_purge_compressed_logs: uncompressed or low-quality logs exist for task %', p_task_id;
    END IF;
    DELETE FROM argo_private.execution_logs WHERE task_id = p_task_id;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_purge_old_events: retention helper for agent_events.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION argo_public.fn_purge_old_events(p_keep_days INT DEFAULT 30)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
DECLARE v_count INT;
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'fn_purge_old_events: argo_operator required';
    END IF;
    DELETE FROM argo_private.agent_events
    WHERE created_at < (now() - (p_keep_days || ' days')::interval);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- =============================================================================
-- 08. Grants
-- =============================================================================
REVOKE ALL ON SCHEMA argo_private FROM PUBLIC;
REVOKE ALL ON SCHEMA argo_public  FROM PUBLIC;

-- -- argo_operator: full access
GRANT USAGE ON SCHEMA argo_private TO argo_operator;
GRANT USAGE ON SCHEMA argo_public  TO argo_operator;
GRANT ALL   ON ALL TABLES    IN SCHEMA argo_private TO argo_operator;
GRANT ALL   ON ALL SEQUENCES IN SCHEMA argo_private TO argo_operator;
GRANT ALL   ON ALL TABLES    IN SCHEMA argo_public  TO argo_operator;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA argo_private TO argo_operator;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA argo_public  TO argo_operator;
ALTER DEFAULT PRIVILEGES IN SCHEMA argo_private GRANT ALL ON TABLES    TO argo_operator;
ALTER DEFAULT PRIVILEGES IN SCHEMA argo_private GRANT ALL ON SEQUENCES TO argo_operator;
ALTER DEFAULT PRIVILEGES IN SCHEMA argo_public  GRANT ALL ON TABLES    TO argo_operator;
ALTER DEFAULT PRIVILEGES IN SCHEMA argo_public  GRANT ALL ON SEQUENCES TO argo_operator;

-- -- argo_agent_base: views and runtime functions
GRANT USAGE ON SCHEMA argo_public TO argo_agent_base;
GRANT SELECT ON argo_public.v_agent_context    TO argo_agent_base;
GRANT SELECT ON argo_public.v_my_tasks         TO argo_agent_base;
GRANT SELECT ON argo_public.v_my_memory        TO argo_agent_base;
GRANT SELECT ON argo_public.v_my_tools         TO argo_agent_base;
GRANT SELECT ON argo_public.v_session_progress TO argo_agent_base;
GRANT SELECT ON argo_public.v_ready_tasks      TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.run_agent(TEXT, TEXT, INT)              TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.fn_next_step(INT, vector, INT)          TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.fn_submit_result(INT, TEXT, BOOLEAN)    TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.fn_search_memory(vector, INT, INT)      TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.fn_search_tools(vector, INT, INT)       TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.list_sessions(TEXT)                     TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.get_session(INT)                        TO argo_agent_base;

-- -- argo_langflow: same runtime grants as agents, plus session control
GRANT USAGE ON SCHEMA argo_public TO argo_langflow;
GRANT SELECT ON argo_public.v_agent_context    TO argo_langflow;
GRANT SELECT ON argo_public.v_my_tasks         TO argo_langflow;
GRANT SELECT ON argo_public.v_my_memory        TO argo_langflow;
GRANT SELECT ON argo_public.v_my_tools         TO argo_langflow;
GRANT SELECT ON argo_public.v_session_progress TO argo_langflow;
GRANT SELECT ON argo_public.v_ready_tasks      TO argo_langflow;
GRANT SELECT ON argo_public.v_pending_approvals TO argo_langflow;
GRANT SELECT ON argo_public.v_reembedding_targets TO argo_langflow;
GRANT SELECT ON argo_public.v_stale_tasks      TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.run_agent(TEXT, TEXT, INT)              TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.fn_next_step(INT, vector, INT)          TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.fn_submit_result(INT, TEXT, BOOLEAN)    TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.fn_search_memory(vector, INT, INT)      TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.fn_search_tools(vector, INT, INT)       TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.fn_resolve_approval(INT, TEXT, TEXT)    TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.fn_set_tool_embedding(INT, vector, INT) TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.fn_set_memory_embedding(INT, vector, INT) TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.fn_insert_memory(INT, INT, TEXT, vector, INT) TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.fn_recover_stale_tasks(INT)             TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.list_sessions(TEXT)                     TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.get_session(INT)                        TO argo_langflow;
GRANT EXECUTE ON FUNCTION argo_public.list_agents()                           TO argo_langflow;

-- -- operator-only views and management functions
GRANT SELECT ON argo_public.v_session_audit       TO argo_operator;
GRANT SELECT ON argo_public.v_system_agents       TO argo_operator;
GRANT SELECT ON argo_public.v_compressible_logs   TO argo_operator;
GRANT SELECT ON argo_public.v_tool_stats          TO argo_operator;
GRANT SELECT ON argo_public.v_agent_events        TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.create_agent(TEXT, JSONB)               TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.drop_agent(TEXT)                        TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.list_agents()                           TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.fn_register_tool(JSONB)                 TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.fn_grant_tool(INT, INT)                 TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.fn_revoke_tool(INT, INT)                TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.rotate_embedding_model(TEXT, INT, TEXT) TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.fn_register_flow(TEXT, INT, TEXT)       TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.fn_purge_compressed_logs(INT, FLOAT)    TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.fn_purge_old_events(INT)                TO argo_operator;

-- -- argo_sql_sandbox: read-only on allowlisted views
GRANT USAGE ON SCHEMA argo_public TO argo_sql_sandbox;
GRANT SELECT ON argo_public.v_my_tasks         TO argo_sql_sandbox;
GRANT SELECT ON argo_public.v_my_memory        TO argo_sql_sandbox;
GRANT SELECT ON argo_public.v_my_tools         TO argo_sql_sandbox;
GRANT SELECT ON argo_public.v_session_progress TO argo_sql_sandbox;
GRANT SELECT ON argo_public.v_ready_tasks      TO argo_sql_sandbox;

-- =============================================================================
-- 09. Indexes
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_tasks_agent_id        ON argo_private.tasks (agent_id);
CREATE INDEX IF NOT EXISTS idx_tasks_session_id      ON argo_private.tasks (session_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status          ON argo_private.tasks (status);
CREATE INDEX IF NOT EXISTS idx_tasks_heartbeat       ON argo_private.tasks (heartbeat_at) WHERE status = 'running';
CREATE INDEX IF NOT EXISTS idx_sessions_agent_id     ON argo_private.sessions (agent_id);
CREATE INDEX IF NOT EXISTS idx_sessions_status       ON argo_private.sessions (status);
CREATE INDEX IF NOT EXISTS idx_sessions_started_at   ON argo_private.sessions (started_at DESC);
CREATE INDEX IF NOT EXISTS idx_exec_logs_task_step   ON argo_private.execution_logs (task_id, step_number);
CREATE INDEX IF NOT EXISTS idx_exec_logs_uncompressed ON argo_private.execution_logs (task_id) WHERE compressed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_memory_agent_id       ON argo_private.memory (agent_id);
CREATE INDEX IF NOT EXISTS idx_memory_agent_dims     ON argo_private.memory (agent_id, embedding_dims);
CREATE INDEX IF NOT EXISTS idx_agent_profile_role    ON argo_private.agent_profile_assignments (role_name);
CREATE INDEX IF NOT EXISTS idx_agent_msg_session     ON argo_private.agent_messages (session_id);
CREATE INDEX IF NOT EXISTS idx_agent_msg_to_session  ON argo_private.agent_messages (to_agent_id, session_id);
CREATE INDEX IF NOT EXISTS idx_task_dep_task         ON argo_private.task_dependencies (task_id);
CREATE INDEX IF NOT EXISTS idx_task_dep_dep          ON argo_private.task_dependencies (depends_on_task_id);
CREATE INDEX IF NOT EXISTS idx_tool_active           ON argo_private.tool_registry (is_active, embedding_dims);
CREATE INDEX IF NOT EXISTS idx_tool_perm_agent       ON argo_private.agent_tool_permissions (agent_id);
CREATE INDEX IF NOT EXISTS idx_tool_exec_task        ON argo_private.tool_executions (task_id);
CREATE INDEX IF NOT EXISTS idx_tool_exec_tool        ON argo_private.tool_executions (tool_id, executed_at DESC);
CREATE INDEX IF NOT EXISTS idx_approvals_status      ON argo_private.human_approvals (status);
CREATE INDEX IF NOT EXISTS idx_events_created        ON argo_private.agent_events (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_agent_type     ON argo_private.agent_events (agent_id, event_type);
CREATE INDEX IF NOT EXISTS idx_events_session        ON argo_private.agent_events (session_id);

-- HNSW vector indexes (created only if vectors will exist; pgvector requires
-- explicit dim, so we skip this in v0.1 and rely on sequential scan + filter
-- on embedding_dims. Once a stable model is chosen, an index can be added
-- manually for better performance. VectorChord can replace these later.)

-- =============================================================================
-- 10. Triggers
-- =============================================================================

-- Auto-update tasks.updated_at
CREATE OR REPLACE FUNCTION argo_private.fn_tasks_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$;
CREATE TRIGGER trg_tasks_updated_at
    BEFORE UPDATE ON argo_private.tasks
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_tasks_updated_at();

-- Auto-update tool_registry.updated_at
CREATE OR REPLACE FUNCTION argo_private.fn_tool_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$;
CREATE TRIGGER trg_tool_updated_at
    BEFORE UPDATE ON argo_private.tool_registry
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_tool_updated_at();

-- Auto-update system_agent_configs.updated_at
CREATE OR REPLACE FUNCTION argo_private.fn_sac_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$;
CREATE TRIGGER trg_sac_updated_at
    BEFORE UPDATE ON argo_private.system_agent_configs
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_sac_updated_at();

-- pg_notify on session completion
CREATE OR REPLACE FUNCTION argo_private.fn_session_notify()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('completed','failed') AND OLD.status = 'active' THEN
        PERFORM pg_notify('argo_session_done', json_build_object(
            'session_id', NEW.session_id,
            'status', NEW.status,
            'agent_id', NEW.agent_id,
            'final_answer', left(COALESCE(NEW.final_answer, ''), 500)
        )::text);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_session_notify
    AFTER UPDATE ON argo_private.sessions
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_session_notify();

-- pg_notify on pending task
CREATE OR REPLACE FUNCTION argo_private.fn_task_notify()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'pending' AND (TG_OP = 'INSERT' OR OLD.status <> 'pending') THEN
        PERFORM pg_notify('argo_task_ready', json_build_object(
            'task_id', NEW.task_id,
            'session_id', NEW.session_id,
            'agent_id', NEW.agent_id
        )::text);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_task_notify
    AFTER INSERT OR UPDATE ON argo_private.tasks
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_task_notify();

-- pg_notify on pending approval
CREATE OR REPLACE FUNCTION argo_private.fn_approval_notify()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'pending' THEN
        PERFORM pg_notify('argo_approval_needed', json_build_object(
            'approval_id', NEW.approval_id,
            'task_id', NEW.task_id,
            'session_id', NEW.session_id
        )::text);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_approval_notify
    AFTER INSERT ON argo_private.human_approvals
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_approval_notify();

-- =============================================================================
-- 11. Seed Data
-- =============================================================================

-- Default embedding config: nomic-embed-text on Ollama (CPU-friendly).
-- Helm chart can override via init SQL if a different model is desired.
INSERT INTO argo_private.embedding_config (model_name, dimensions, endpoint, is_active)
VALUES ('nomic-embed-text', 768, 'http://argo-ollama:11434', TRUE)
ON CONFLICT DO NOTHING;

-- SQL sandbox allowlist
INSERT INTO argo_private.sql_sandbox_allowlist (view_name, description) VALUES
    ('argo_public.v_my_tasks',         'Agent own task list'),
    ('argo_public.v_my_memory',        'Agent own memory'),
    ('argo_public.v_my_tools',         'Tools available to agent'),
    ('argo_public.v_session_progress', 'Session progress summary'),
    ('argo_public.v_ready_tasks',      'Ready-to-run tasks')
ON CONFLICT DO NOTHING;

-- System agent configs
INSERT INTO argo_private.system_agent_configs (agent_type, is_enabled, run_interval_secs, settings)
VALUES
    ('compressor', FALSE, 3600,
     '{"quality_threshold":0.9,"retry_threshold":0.8,"max_retries":2,
       "compress_after_steps":20,"tool_result_max_chars":300,"batch_size":5}'),
    ('embedder',   FALSE, 600,
     '{"batch_size":20}')
ON CONFLICT DO NOTHING;

-- =============================================================================
-- End of argo--0.1.sql
-- =============================================================================
