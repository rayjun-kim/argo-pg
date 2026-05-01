-- =============================================================================
-- 01_create_agent_and_tool.sql
--
-- Hands-on example for talking to ARGO from psql, without Langflow.
-- Connect as `postgres` (or any role with `argo_operator` membership):
--
--   psql -h <pg-rw-svc> -U postgres -d argo
--
-- =============================================================================

-- 1) Create an LLM-driven agent.
SELECT argo_public.create_agent(
    'researcher',                              -- PG role name (must be unique)
    jsonb_build_object(
        'name',          'Researcher',
        'agent_role',    'executor',
        'provider',      'ollama',
        'endpoint',      'http://argo-ollama:11434',
        'model_name',    'llama3.2',
        'temperature',   0.3,
        'max_tokens',    2048,
        'system_prompt', $sp$You are a careful researcher.
When you have a final answer, respond with JSON:
  {"action":"finish","final_answer":"..."}
When you need a tool, respond with:
  {"action":"call_tool","tool_name":"<name>","args":{...}}$sp$,
        'max_steps',     8
    )
);

-- 2) Register an MCP-style tool. Replace mcp_server_url with a real endpoint.
SELECT argo_public.fn_register_tool(jsonb_build_object(
    'name',           'web_search',
    'description',    'Search the web for recent information about a topic.',
    'tool_type',      'mcp',
    'mcp_server_url', 'http://my-mcp:8080/sse',
    'mcp_server_name','my-search-mcp',
    'input_schema',   jsonb_build_object(
        'type', 'object',
        'properties', jsonb_build_object(
            'query', jsonb_build_object('type','string','description','search query')
        ),
        'required', jsonb_build_array('query')
    )
)) AS tool_id;

-- 3) Grant the tool to the agent.
SELECT argo_public.fn_grant_tool(
    (SELECT agent_id FROM argo_private.agent_meta WHERE role_name = 'researcher'),
    (SELECT tool_id  FROM argo_private.tool_registry WHERE name     = 'web_search')
);

-- 4) Inspect: which tools does the agent see?
SET ROLE researcher;
SELECT * FROM argo_public.v_my_tools;
RESET ROLE;
