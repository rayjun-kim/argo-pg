"""ARGOSubmitResult: submit an LLM response to ARGO and route on the next action.

This component has FIVE output ports so that downstream wiring stays declarative:
  - continue       : loop back to ARGO Next Step
  - done           : terminal; carries final output and need_embedding flag
  - invoke_tool    : carries tool_info + args for ARGO Tool Router
  - wait_tasks     : delegate happened; carries pending child task ids
  - wait_approval  : human approval requested

Only the matching output is populated for a given run; others return None.
"""

from __future__ import annotations

from typing import Any

from langflow.custom import Component
from langflow.io import IntInput, DataInput, MessageTextInput, BoolInput, Output
from langflow.schema import Data

from _argo_db import call_function


class ARGOSubmitResult(Component):
    display_name = "ARGO Submit Result"
    description = (
        "Submit the LLM response to argo_public.fn_submit_result. "
        "Routes the next action to one of five output ports."
    )
    icon = "send"
    name = "ARGOSubmitResult"

    inputs = [
        DataInput(
            name="task_info",
            display_name="Task Info",
            info="Connect from ARGO Next Step's 'Step Data' output. task_id is extracted from it.",
            required=False,
        ),
        IntInput(
            name="task_id",
            display_name="Task ID (manual)",
            info="Used only when Task Info is not connected. Enter the task_id directly.",
            required=False,
        ),
        MessageTextInput(
            name="response",
            display_name="LLM Response",
            info="Raw LLM output text. JSON-shaped responses are parsed by ARGO.",
            required=True,
        ),
        BoolInput(
            name="is_final",
            display_name="Force Final",
            info="If true, the task is marked completed regardless of response content.",
            value=False,
            required=False,
        ),
    ]

    outputs = [
        Output(name="continue_out",     display_name="continue",       method="route_continue"),
        Output(name="done_out",         display_name="done",           method="route_done"),
        Output(name="invoke_tool_out",  display_name="invoke_tool",    method="route_invoke_tool"),
        Output(name="wait_tasks_out",   display_name="wait_tasks",     method="route_wait_tasks"),
        Output(name="wait_approval_out",display_name="wait_approval",  method="route_wait_approval"),
    ]

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
                "ARGOSubmitResult: provide a connected 'Task Info' or set 'Task ID' manually."
            ) from exc

    def _submit(self) -> dict[str, Any]:
        """Call DB once and cache the result."""
        cached = getattr(self, "_argo_result", None)
        if cached is not None:
            return cached

        task_id = self._resolve_task_id()

        response = self.response
        if hasattr(response, "text"):
            response = response.text
        if hasattr(response, "data") and isinstance(response.data, dict):
            response = response.data.get("text") or str(response.data)
        response = "" if response is None else str(response)

        result = call_function(
            "SELECT argo_public.fn_submit_result(%s, %s, %s)",
            (task_id, response, bool(self.is_final)),
        )
        if not isinstance(result, dict):
            raise RuntimeError(f"ARGOSubmitResult: unexpected response: {result!r}")

        self._argo_result = result
        self._resolved_task_id = task_id
        self.status = f"action={result.get('action')}"
        return result

    # ------------------------------------------------------------------
    def route_continue(self) -> Data | None:
        r = self._submit()
        if r.get("action") == "continue":
            return Data(data={"task_id": self._resolved_task_id, **r})
        self.stop("continue_out")
        return None

    def route_done(self) -> Data | None:
        r = self._submit()
        if r.get("action") == "done":
            return Data(data=r)
        self.stop("done_out")
        return None

    def route_invoke_tool(self) -> Data | None:
        r = self._submit()
        if r.get("action") == "invoke_tool":
            return Data(data=r)
        self.stop("invoke_tool_out")
        return None

    def route_wait_tasks(self) -> Data | None:
        r = self._submit()
        if r.get("action") == "wait_tasks":
            return Data(data=r)
        self.stop("wait_tasks_out")
        return None

    def route_wait_approval(self) -> Data | None:
        r = self._submit()
        if r.get("action") == "wait_approval":
            return Data(data=r)
        self.stop("wait_approval_out")
        return None
