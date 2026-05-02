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
from langflow.io import IntInput, MessageTextInput, BoolInput, Output
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
        IntInput(
            name="task_id",
            display_name="Task ID",
            info="Task this response belongs to.",
            required=True,
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

    # ---------------------------------------------------------------------
    # Internal helper: call DB once, cache the parsed response on self.
    # ---------------------------------------------------------------------
    def _submit(self) -> dict[str, Any]:
        cached = getattr(self, "_argo_result", None)
        if cached is not None:
            return cached

        try:
            task_id = int(self.task_id)
        except (TypeError, ValueError) as exc:
            raise ValueError("ARGOSubmitResult: 'task_id' must be an integer.") from exc

        response = self.response
        # Allow Message/Data inputs in addition to plain strings.
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
        self.status = f"action={result.get('action')}"
        return result

    # ---------------------------------------------------------------------
    # Five route methods. Each returns Data only if the action matches.
    # ---------------------------------------------------------------------
    def route_continue(self) -> Data | None:
        r = self._submit()
        if r.get("action") == "continue":
            # Echo task_id so the next ARGO Next Step can use it directly.
            return Data(data={"task_id": int(self.task_id), **r})
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