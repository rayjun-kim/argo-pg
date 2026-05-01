"""ARGONextStep: ask the ARGO control plane what to do next for a task.

Returns the action ('call_llm', 'wait_tasks', 'wait_approval', 'done')
plus messages, llm_config, tools and (optionally) memory snippets.

Optional input `query_embedding` triggers a memory search inside fn_next_step.
"""

from __future__ import annotations

from typing import Any

from langflow.custom import Component
from langflow.io import IntInput, DataInput, Output
from langflow.schema import Data

from ._argo_db import call_function, vector_literal


class ARGONextStep(Component):
    display_name = "ARGO Next Step"
    description = (
        "Call argo_public.fn_next_step(task_id) and return the next action. "
        "Optionally pass a query embedding to inject relevant memory."
    )
    icon = "step-forward"
    name = "ARGONextStep"

    inputs = [
        IntInput(
            name="task_id",
            display_name="Task ID",
            info="Task to advance. Usually piped from ARGO Enqueue or a previous Submit Result.",
            required=True,
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
            display_name="Step",
            method="next_step",
        ),
    ]

    def next_step(self) -> Data:
        try:
            task_id = int(self.task_id)
        except (TypeError, ValueError) as exc:
            raise ValueError("ARGONextStep: 'task_id' must be an integer.") from exc

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
        return Data(data=result)

    @staticmethod
    def _extract_embedding(value: Any) -> list[float] | None:
        if value is None:
            return None
        # DataInput delivers either a Data object or a raw list/dict
        if hasattr(value, "data"):
            value = value.data
        if isinstance(value, dict):
            value = value.get("embedding") or value.get("vector") or value.get("data")
        if isinstance(value, list) and value and isinstance(value[0], (int, float)):
            return [float(x) for x in value]
        return None
