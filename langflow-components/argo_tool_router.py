"""ARGOToolRouter: split an `invoke_tool` payload into tool_type-specific outputs.

ARGO returns a payload like:
  {
    "action": "invoke_tool",
    "task_id": 42,
    "tool":  {"tool_id": 1, "name": "...", "tool_type": "mcp"|"http"|"custom", ...},
    "args":  {...}
  }

This component routes the payload to one of three output ports so that the
appropriate runtime node (MCP client / HTTP request / Code executor) can pick
it up. SQL tools never reach this router; they're executed inside ARGO itself.
"""

from __future__ import annotations

from typing import Any

from langflow.custom import Component
from langflow.io import DataInput, Output
from langflow.schema import Data


class ARGOToolRouter(Component):
    display_name = "ARGO Tool Router"
    description = (
        "Route an ARGO invoke_tool payload to the correct runtime "
        "(MCP / HTTP / custom code) based on tool_type."
    )
    icon = "git-branch"
    name = "ARGOToolRouter"

    inputs = [
        DataInput(
            name="invoke_payload",
            display_name="Invoke Payload",
            info="The Data emitted from ARGO Submit Result's invoke_tool port.",
            required=True,
        ),
    ]

    outputs = [
        Output(name="mcp_out",    display_name="mcp",    method="route_mcp"),
        Output(name="http_out",   display_name="http",   method="route_http"),
        Output(name="custom_out", display_name="custom", method="route_custom"),
    ]

    # ---------------------------------------------------------------------
    def _payload(self) -> dict[str, Any]:
        cached = getattr(self, "_argo_payload", None)
        if cached is not None:
            return cached

        value = self.invoke_payload
        if hasattr(value, "data"):
            value = value.data
        if not isinstance(value, dict):
            raise ValueError("ARGOToolRouter: 'invoke_payload' must be a dict / Data.")

        if value.get("action") != "invoke_tool":
            raise ValueError(
                f"ARGOToolRouter: expected action='invoke_tool', got {value.get('action')!r}"
            )

        tool = value.get("tool") or {}
        if not isinstance(tool, dict) or not tool.get("tool_type"):
            raise ValueError("ARGOToolRouter: payload missing tool.tool_type")

        self._argo_payload = value
        self.status = f"tool_type={tool.get('tool_type')} name={tool.get('name')}"
        return value

    def _tool_type(self) -> str:
        return (self._payload().get("tool") or {}).get("tool_type")

    # ---------------------------------------------------------------------
    def route_mcp(self) -> Data | None:
        if self._tool_type() == "mcp":
            return Data(data=self._payload())
        self.stop("mcp_out")
        return None

    def route_http(self) -> Data | None:
        if self._tool_type() == "http":
            return Data(data=self._payload())
        self.stop("http_out")
        return None

    def route_custom(self) -> Data | None:
        if self._tool_type() == "custom":
            return Data(data=self._payload())
        self.stop("custom_out")
        return None
