"""ARGONextStep: ask the ARGO control plane what to do next for a task.

Returns the action ('call_llm', 'wait_tasks', 'wait_approval', 'done')
plus messages, llm_config, tools and (optionally) memory snippets.

Optional input `query_embedding` triggers a memory search inside fn_next_step.
"""

from __future__ import annotations

from typing import Any

from langflow.custom import Component
from langflow.io import IntInput, DataInput, Output
from langflow.schema import Data, Message

from _argo_db import call_function, vector_literal


class ARGONextStep(Component):
    display_name = "ARGO Next Step"
    description = (
        "Call argo_public.fn_next_step(task_id) and return the next action. "
        "Optionally pass a query embedding to inject relevant memory."
    )
    icon = "step-forward"
    name = "ARGONextStep"

    inputs = [
        DataInput(
            name="task_info",
            display_name="Task Info",
            info="Connect from ARGO Enqueue or Submit Result (continue/wait_tasks loop). "
                 "task_id is extracted from the incoming Data.",
            required=False,
        ),
        IntInput(
            name="task_id",
            display_name="Task ID (manual)",
            info="Used only when Task Info is not connected. Enter the task_id directly.",
            required=False,
        ),
        DataInput(
            name="query_embedding",
            display_name="Query Embedding",
            info="Optional. List[float] for memory search. Skip if no memory injection is needed.",
            required=False,
        ),
        IntInput(
            name="memory_limit",
            display_name="Memory Limit",
            info="Top-k memory rows to inject when query_embedding is provided.",
            value=5,
            required=False,
        ),
    ]

    outputs = [
        Output(
            name="step",
            display_name="Step Data",
            method="next_step",
        ),
        Output(
            name="prompt",
            display_name="Prompt",
            method="format_prompt",
        ),
    ]

    # ------------------------------------------------------------------
    # Cache the DB result so next_step() and format_prompt() share one call.
    # ------------------------------------------------------------------
    def _get_result(self) -> dict[str, Any]:
        cached = getattr(self, "_argo_step_result", None)
        if cached is not None:
            return cached

        task_id = self._resolve_task_id()
        embedding = self._extract_embedding(self.query_embedding)

        if embedding is None:
            sql = "SELECT argo_public.fn_next_step(%s, NULL, %s)"
            params: tuple[Any, ...] = (task_id, int(self.memory_limit or 5))
        else:
            sql = "SELECT argo_public.fn_next_step(%s, %s::vector, %s)"
            params = (task_id, vector_literal(embedding), int(self.memory_limit or 5))

        result = call_function(sql, params)
        if not isinstance(result, dict):
            raise RuntimeError(f"ARGONextStep: unexpected response: {result!r}")

        action = result.get("action", "?")
        self.status = f"action={action} task_id={task_id}"
        self._argo_step_result = result
        return result

    def next_step(self) -> Data:
        """Return the full step payload (task_id, messages, llm_config, tools…)."""
        return Data(data=self._get_result())

    def format_prompt(self) -> Message:
        """Return the conversation history as a Message for the LLM node."""
        result = self._get_result()
        messages: list[dict] = result.get("messages", [])
        parts: list[str] = []
        for msg in messages:
            role = msg.get("role", "user").upper()
            content = msg.get("content", "")
            parts.append(f"{role}: {content}")
        return Message(text="\n\n".join(parts))

    # ------------------------------------------------------------------

    def _resolve_task_id(self) -> int:
        """Extract task_id from task_info Data, or fall back to the manual task_id field."""
        ti = self.task_info
        if ti is not None:
            raw = ti.data if hasattr(ti, "data") else ti
            if isinstance(raw, dict) and "task_id" in raw:
                return int(raw["task_id"])
        try:
            return int(self.task_id)
        except (TypeError, ValueError) as exc:
            raise ValueError(
                "ARGONextStep: provide a connected 'Task Info' or set 'Task ID' manually."
            ) from exc

    @staticmethod
    def _extract_embedding(value: Any) -> list[float] | None:
        if value is None:
            return None
        if hasattr(value, "data"):
            value = value.data
        if isinstance(value, dict):
            value = value.get("embedding") or value.get("vector") or value.get("data")
        if isinstance(value, list) and value and isinstance(value[0], (int, float)):
            return [float(x) for x in value]
        return None
