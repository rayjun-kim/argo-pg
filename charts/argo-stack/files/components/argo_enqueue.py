"""ARGOEnqueue: start an agent execution by inserting a task into ARGO.

This is typically the FIRST node in any ARGO flow.
"""

from __future__ import annotations

from langflow.custom import Component
from langflow.io import MessageTextInput, IntInput, Output
from langflow.schema import Data

from _argo_db import call_function


class ARGOEnqueue(Component):
    display_name = "ARGO Enqueue"
    description = (
        "Enqueue a task for an ARGO agent. "
        "Returns task_id and session_id for downstream components."
    )
    icon = "play"
    name = "ARGOEnqueue"

    inputs = [
        MessageTextInput(
            name="agent_role",
            display_name="Agent Role",
            info="PostgreSQL role name of the target agent (e.g. 'researcher').",
            required=True,
        ),
        MessageTextInput(
            name="task",
            display_name="Task",
            info="Natural-language task description for the agent.",
            required=True,
        ),
        IntInput(
            name="session_id",
            display_name="Session ID",
            info="Optional. Reuse an existing session by ID. Leave empty to create a new one.",
            required=False,
        ),
    ]

    outputs = [
        Output(
            name="task_info",
            display_name="Task Info",
            method="enqueue",
        ),
    ]

    def enqueue(self) -> Data:
        agent_role = (self.agent_role or "").strip()
        task_text  = (self.task or "").strip()

        if not agent_role:
            raise ValueError("ARGOEnqueue: 'agent_role' is required.")
        if not task_text:
            raise ValueError("ARGOEnqueue: 'task' is required.")

        session_id = None
        if self.session_id is not None and str(self.session_id).strip() != "":
            try:
                session_id = int(self.session_id)
            except (TypeError, ValueError):
                session_id = None

        result = call_function(
            "SELECT argo_public.run_agent(%s, %s, %s)",
            (agent_role, task_text, session_id),
        )

        # result is JSONB -> dict via psycopg2
        if not isinstance(result, dict):
            raise RuntimeError(f"ARGOEnqueue: unexpected response: {result!r}")

        self.status = (
            f"Enqueued task #{result.get('task_id')} "
            f"in session #{result.get('session_id')}"
        )
        return Data(data=result)