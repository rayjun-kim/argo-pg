"""Flow JSON builder for Langflow.

Generates Langflow flow JSON files from a declarative spec.
The output mirrors what Langflow's `/api/v1/flows/upload/` endpoint accepts
and what `/api/v1/flows/download/` produces for an exported flow.

Each node entry uses Langflow's `genericNode` type. Custom components built
with the modern `Component` base class need:
  - data.type             = component class name (e.g. "ARGOEnqueue")
  - data.node.template    = mapping of input fields to value entries
  - data.node.outputs     = list of output port definitions
  - data.node.display_name / description / icon
  - data.node.template["code"]  = the full source of the component class

Edges encode source/target node ids and the field/port being connected,
duplicated under `sourceHandle` / `targetHandle` (string-encoded JSON) and
`data.sourceHandle` / `data.targetHandle` (object form). Both shapes must
match for the visual editor to render the wire.

This builder is used to emit single_agent_flow.json, multi_agent_flow.json
and embedder_flow.json without hand-writing JSON.
"""

from __future__ import annotations

import json
import string
import random
from pathlib import Path
from typing import Any


COMPONENT_DIR = Path(__file__).resolve().parent.parent / "langflow-components"


def _suffix(n: int = 6) -> str:
    return "".join(random.choices(string.ascii_letters + string.digits, k=n))


def load_component_code(filename: str) -> str:
    """Read a component file as a string for embedding into the flow JSON."""
    p = COMPONENT_DIR / filename
    return p.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# Field templates per Langflow input type. Only the keys Langflow needs to
# render and validate the field.
# ---------------------------------------------------------------------------

def _msg_text(name: str, display: str, value: str = "", info: str = "",
              required: bool = True, advanced: bool = False) -> dict[str, Any]:
    return {
        "type": "str",
        "required": required,
        "placeholder": "",
        "list": False,
        "show": True,
        "multiline": False,
        "value": value,
        "fileTypes": [],
        "name": name,
        "display_name": display,
        "advanced": advanced,
        "dynamic": False,
        "info": info,
        "title_case": False,
        "input_types": ["Message"],
        "_input_type": "MessageTextInput",
    }


def _int_field(name: str, display: str, value: int | None = None,
               info: str = "", required: bool = False,
               advanced: bool = False) -> dict[str, Any]:
    return {
        "type": "int",
        "required": required,
        "show": True,
        "value": value,
        "name": name,
        "display_name": display,
        "advanced": advanced,
        "info": info,
        "_input_type": "IntInput",
    }


def _bool_field(name: str, display: str, value: bool = False,
                info: str = "", advanced: bool = False) -> dict[str, Any]:
    return {
        "type": "bool",
        "required": False,
        "show": True,
        "value": value,
        "name": name,
        "display_name": display,
        "advanced": advanced,
        "info": info,
        "_input_type": "BoolInput",
    }


def _data_field(name: str, display: str, info: str = "",
                required: bool = False, advanced: bool = False) -> dict[str, Any]:
    return {
        "type": "other",
        "required": required,
        "show": True,
        "name": name,
        "display_name": display,
        "advanced": advanced,
        "info": info,
        "input_types": ["Data"],
        "_input_type": "DataInput",
    }


def _code_field(code: str) -> dict[str, Any]:
    return {
        "type": "code",
        "required": True,
        "show": False,
        "value": code,
        "fileTypes": [],
        "name": "code",
        "advanced": True,
        "dynamic": True,
        "_input_type": "CodeInput",
    }


# ---------------------------------------------------------------------------
# Output specs
# ---------------------------------------------------------------------------

def _output(name: str, display_name: str, method: str,
            types: list[str] | None = None) -> dict[str, Any]:
    """Output definition compatible with Langflow 1.9+"""
    t = types or ["Data"]
    return {
        "name": name,
        "display_name": display_name,
        "method": method,
        "types": t,
        "selected": t[0],
        "value": "__UNDEFINED__",
        "cache": True,
        "allows_loop": False,
        "group_outputs": False,
        "tool_mode": False,
    }


# ---------------------------------------------------------------------------
# Generic node builder
# ---------------------------------------------------------------------------

def make_node(
    *,
    component_class: str,
    component_file: str,
    display_name: str,
    description: str,
    icon: str,
    template: dict[str, dict[str, Any]],
    outputs: list[dict[str, Any]],
    position: tuple[float, float],
    base_classes: list[str] | None = None,
) -> dict[str, Any]:
    node_id = f"{component_class}-{_suffix()}"
    code_value = _code_field(load_component_code(component_file))
    template = {**template, "code": code_value}

    base_classes = base_classes or ["Data"]

    return {
        "id": node_id,
        "type": "genericNode",
        "position": {"x": float(position[0]), "y": float(position[1])},
        "data": {
            "type": component_class,
            "id": node_id,
            "node": {
                "display_name": display_name,
                "description": description,
                "icon": icon,
                "template": template,
                "outputs": outputs,
                "base_classes": base_classes,
                "official": False,
                "edited": False,
                "tool_mode": False,
            },
        },
    }


# ---------------------------------------------------------------------------
# Edge builder
# ---------------------------------------------------------------------------

# Langflow 1.9 uses the œ character (U+0153) instead of quotes inside
# sourceHandle / targetHandle strings.
_Q = "œ"  # œ


def _encode_handle(d: dict[str, Any]) -> str:
    """Encode a handle dict using œ as quote character (Langflow 1.9 format)."""
    parts = []
    for k, v in d.items():
        key = f"{_Q}{k}{_Q}"
        if isinstance(v, list):
            items = ", ".join(f"{_Q}{i}{_Q}" for i in v)
            val = f"[{items}]"
        else:
            val = f"{_Q}{v}{_Q}"
        parts.append(f"{key}: {val}")
    return "{" + ", ".join(parts) + "}"


def make_edge(
    *,
    source_node: dict[str, Any],
    source_output_name: str,
    target_node: dict[str, Any],
    target_input_name: str,
) -> dict[str, Any]:
    source_id = source_node["id"]
    target_id = target_node["id"]

    out = next(
        (o for o in source_node["data"]["node"]["outputs"]
         if o["name"] == source_output_name),
        None,
    )
    if out is None:
        raise ValueError(f"unknown output {source_output_name!r} on {source_id}")

    output_types = out["types"]
    in_field = target_node["data"]["node"]["template"].get(target_input_name)
    if in_field is None:
        raise ValueError(f"unknown input {target_input_name!r} on {target_id}")
    input_types = in_field.get("input_types") or ["Data"]

    source_handle_obj = {
        "dataType": source_node["data"]["type"],
        "id": source_id,
        "name": source_output_name,
        "output_types": output_types,
    }
    target_handle_obj = {
        "fieldName": target_input_name,
        "id": target_id,
        "inputTypes": input_types,
        "type": in_field.get("type", "str"),
    }

    sh_str = _encode_handle(source_handle_obj)
    th_str = _encode_handle(target_handle_obj)

    return {
        "source": source_id,
        "target": target_id,
        "sourceHandle": sh_str,
        "targetHandle": th_str,
        "data": {
            "sourceHandle": source_handle_obj,
            "targetHandle": target_handle_obj,
        },
        "id": f"xy-edge__{source_id}{sh_str}-{target_id}{th_str}",
        "animated": False,
        "selected": False,
    }


# ---------------------------------------------------------------------------
# Flow assembly
# ---------------------------------------------------------------------------

def make_flow(
    *,
    name: str,
    description: str,
    nodes: list[dict[str, Any]],
    edges: list[dict[str, Any]],
    icon: str = "Workflow",
) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "icon": icon,
        "is_component": False,
        "data": {
            "nodes": nodes,
            "edges": edges,
            "viewport": {"x": 0, "y": 0, "zoom": 0.7},
        },
        "last_tested_version": "1.7.0",
        "tags": ["argo"],
    }


def write_flow(flow: dict[str, Any], path: Path) -> None:
    path.write_text(json.dumps(flow, indent=2, ensure_ascii=False), encoding="utf-8")


# ---------------------------------------------------------------------------
# Pre-built ARGO node factories
# ---------------------------------------------------------------------------

def node_argo_enqueue(position: tuple[float, float],
                      agent_role: str = "",
                      task: str = "") -> dict[str, Any]:
    return make_node(
        component_class="ARGOEnqueue",
        component_file="argo_enqueue.py",
        display_name="ARGO Enqueue",
        description="Enqueue a task for an ARGO agent.",
        icon="play",
        template={
            "agent_role": _msg_text("agent_role", "Agent Role", value=agent_role,
                                    info="PostgreSQL role name of the target agent."),
            "task":       _msg_text("task", "Task", value=task,
                                    info="Natural-language task for the agent."),
            "session_id": _int_field("session_id", "Session ID",
                                     info="Reuse an existing session. Leave empty to create one.",
                                     advanced=True),
        },
        outputs=[_output("task_info", "Task Info", "enqueue")],
        position=position,
    )


def node_argo_next_step(position: tuple[float, float]) -> dict[str, Any]:
    return make_node(
        component_class="ARGONextStep",
        component_file="argo_next_step.py",
        display_name="ARGO Next Step",
        description="Ask ARGO what to do next for a task.",
        icon="step-forward",
        template={
            "task_info":       _data_field("task_info", "Task Info",
                                           info="Connect from ARGO Enqueue or Submit Result (loop)."),
            "task_id":         _int_field("task_id", "Task ID (manual)",
                                          info="Used only when Task Info is not connected.",
                                          advanced=True),
            "query_embedding": _data_field("query_embedding", "Query Embedding",
                                           info="Optional embedding for memory injection.",
                                           advanced=True),
            "memory_limit":    _int_field("memory_limit", "Memory Limit",
                                          value=5, advanced=True),
        },
        outputs=[
            _output("step",   "Step Data", "next_step"),
            _output("prompt", "Prompt",    "format_prompt", types=["Message"]),
        ],
        position=position,
    )


def node_argo_submit_result(position: tuple[float, float]) -> dict[str, Any]:
    return make_node(
        component_class="ARGOSubmitResult",
        component_file="argo_submit_result.py",
        display_name="ARGO Submit Result",
        description="Submit LLM response. Routes to the matching action port.",
        icon="send",
        template={
            "task_info": _data_field("task_info", "Task Info",
                                     info="Connect from ARGO Next Step's 'Step Data' output."),
            "task_id":   _int_field("task_id", "Task ID (manual)",
                                    info="Used only when Task Info is not connected.",
                                    advanced=True),
            "response":  _msg_text("response", "LLM Response",
                                   info="The raw LLM output text."),
            "is_final":  _bool_field("is_final", "Force Final", value=False, advanced=True),
        },
        outputs=[
            _output("continue_out",      "continue",      "route_continue"),
            _output("done_out",          "done",          "route_done"),
            _output("invoke_tool_out",   "invoke_tool",   "route_invoke_tool"),
            _output("wait_tasks_out",    "wait_tasks",    "route_wait_tasks"),
            _output("wait_approval_out", "wait_approval", "route_wait_approval"),
        ],
        position=position,
    )


def node_argo_tool_router(position: tuple[float, float]) -> dict[str, Any]:
    return make_node(
        component_class="ARGOToolRouter",
        component_file="argo_tool_router.py",
        display_name="ARGO Tool Router",
        description="Routes invoke_tool payloads by tool_type.",
        icon="git-branch",
        template={
            "invoke_payload": _data_field("invoke_payload", "Invoke Payload",
                                          required=True),
        },
        outputs=[
            _output("mcp_out",    "mcp",    "route_mcp"),
            _output("http_out",   "http",   "route_http"),
            _output("custom_out", "custom", "route_custom"),
        ],
        position=position,
    )


def node_argo_search_tools(position: tuple[float, float]) -> dict[str, Any]:
    return make_node(
        component_class="ARGOSearchTools",
        component_file="argo_search_tools.py",
        display_name="ARGO Search Tools",
        description="Vector search over the agent's allowed tools.",
        icon="search",
        template={
            "query_embedding": _data_field("query_embedding", "Query Embedding",
                                           required=True),
            "agent_id":        _int_field("agent_id", "Agent ID", required=True),
            "top_k":           _int_field("top_k", "Top K", value=5),
        },
        outputs=[_output("tools", "Tools", "search")],
        position=position,
    )


def node_argo_embedder(position: tuple[float, float]) -> dict[str, Any]:
    return make_node(
        component_class="ARGOEmbedder",
        component_file="argo_embedder.py",
        display_name="ARGO Embedder",
        description="Re-embed rows whose vectors don't match the active model.",
        icon="refresh-cw",
        template={
            "batch_size": _int_field("batch_size", "Batch Size", value=20),
        },
        outputs=[_output("report", "Report", "run_embedder")],
        position=position,
    )


def node_ollama(position: tuple[float, float],
                base_url: str = "http://argo-argo-stack-ollama:11434",
                model_name: str = "gemma4:e2b") -> dict[str, Any]:
    """Built-in Langflow Ollama component (LCModelComponent).

    No code embedding needed; Langflow ships with this class as `OllamaModel`.
    """
    node_id = f"OllamaModel-{_suffix()}"
    template = {
        "base_url": {
            "type": "str", "required": True, "show": True,
            "value": base_url, "name": "base_url",
            "display_name": "Base URL",
            "info": "Ollama server URL.",
            "_input_type": "MessageTextInput",
            "input_types": ["Message"],
        },
        "model_name": {
            "type": "str", "required": True, "show": True,
            "value": model_name, "name": "model_name",
            "display_name": "Model Name",
            "info": "Model tag to use (e.g. gemma4:e2b, llama3.2).",
            "_input_type": "MessageTextInput",
            "input_types": ["Message"],
        },
        "temperature": {
            "type": "float", "required": False, "show": True,
            "value": 0.2, "name": "temperature",
            "display_name": "Temperature",
            "_input_type": "SliderInput",
            "advanced": True,
        },
        "input_value": {
            "type": "str", "required": False, "show": True,
            "value": "", "name": "input_value",
            "display_name": "Input",
            "input_types": ["Message"],
            "_input_type": "MessageTextInput",
        },
        "system_message": {
            "type": "str", "required": False, "show": True,
            "value": "", "name": "system_message",
            "display_name": "System Message",
            "input_types": ["Message"],
            "_input_type": "MessageTextInput",
            "advanced": True,
        },
        "stream": {
            "type": "bool", "required": False, "show": True,
            "value": False, "name": "stream",
            "display_name": "Stream",
            "_input_type": "BoolInput",
            "advanced": True,
        },
    }

    return {
        "id": node_id,
        "type": "genericNode",
        "position": {"x": float(position[0]), "y": float(position[1])},
        "data": {
            "type": "OllamaModel",
            "id": node_id,
            "node": {
                "display_name": "Ollama",
                "description": "Generate text using a local Ollama model.",
                "icon": "Ollama",
                "template": template,
                "outputs": [
                    {
                        "name": "text_output",
                        "display_name": "Model Response",
                        "method": "text_response",
                        "types": ["Message"],
                        "selected": "Message",
                        "value": "__UNDEFINED__",
                        "cache": True,
                    },
                ],
                "base_classes": ["Message"],
                "official": True,
                "edited": False,
            },
        },
    }