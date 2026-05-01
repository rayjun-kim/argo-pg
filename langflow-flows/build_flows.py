"""Generate the three ARGO starter flows.

Run:
    python build_flows.py

Outputs:
    single_agent_flow.json
    multi_agent_flow.json
    embedder_flow.json
"""

from __future__ import annotations

import random
from pathlib import Path

from _flow_builder import (
    make_edge,
    make_flow,
    node_argo_embedder,
    node_argo_enqueue,
    node_argo_next_step,
    node_argo_submit_result,
    node_argo_tool_router,
    node_ollama,
    write_flow,
)

OUT = Path(__file__).resolve().parent

# Stable suffixes between runs; helpful when diffing committed JSON.
random.seed(20260430)


# ---------------------------------------------------------------------------
# Flow 1: single agent
# ---------------------------------------------------------------------------
def build_single_agent_flow() -> None:
    enqueue   = node_argo_enqueue((  -200,   0), agent_role="my_agent",
                                  task="Hello from ARGO")
    next_step = node_argo_next_step(( 200,   0))
    ollama    = node_ollama((        550,   0))
    submit    = node_argo_submit_result(( 900, 0))
    router    = node_argo_tool_router((1500,  -150))

    edges = [
        # Enqueue.task_info -> NextStep.task_id
        make_edge(source_node=enqueue, source_output_name="task_info",
                  target_node=next_step, target_input_name="task_id"),

        # NextStep.step -> Ollama.input_value (LLM consumes the messages)
        make_edge(source_node=next_step, source_output_name="step",
                  target_node=ollama, target_input_name="input_value"),

        # Ollama.text_output -> SubmitResult.response
        make_edge(source_node=ollama, source_output_name="text_output",
                  target_node=submit, target_input_name="response"),

        # NextStep.step -> SubmitResult.task_id (so submit knows the task)
        make_edge(source_node=next_step, source_output_name="step",
                  target_node=submit, target_input_name="task_id"),

        # SubmitResult.continue_out -> NextStep.task_id (loop)
        make_edge(source_node=submit, source_output_name="continue_out",
                  target_node=next_step, target_input_name="task_id"),

        # SubmitResult.invoke_tool_out -> ToolRouter.invoke_payload
        make_edge(source_node=submit, source_output_name="invoke_tool_out",
                  target_node=router, target_input_name="invoke_payload"),
    ]

    flow = make_flow(
        name="ARGO Single Agent",
        description=(
            "Minimal ARGO flow: Enqueue -> Next Step -> Ollama -> Submit Result. "
            "Submit Result has five output ports — wire 'continue' back to "
            "Next Step (loop) and 'invoke_tool' to the Tool Router. "
            "Replace the Ollama node with any other LLM provider as needed."
        ),
        nodes=[enqueue, next_step, ollama, submit, router],
        edges=edges,
    )
    write_flow(flow, OUT / "single_agent_flow.json")
    print("wrote single_agent_flow.json")


# ---------------------------------------------------------------------------
# Flow 2: multi-agent (orchestrator + executor)
# ---------------------------------------------------------------------------
def build_multi_agent_flow() -> None:
    # Top lane: orchestrator
    orch_enq    = node_argo_enqueue((   -200,  -200),
                                    agent_role="orchestrator",
                                    task="Coordinate a research task")
    orch_next   = node_argo_next_step((  200,  -200))
    orch_llm    = node_ollama((           550, -200))
    orch_submit = node_argo_submit_result(( 900, -200))

    # Bottom lane: executor (its enqueue is implicit — delegate creates the
    # task. The executor flow's Next Step picks it up via v_ready_tasks.)
    exec_next   = node_argo_next_step((  200,  300))
    exec_llm    = node_ollama((           550,  300))
    exec_submit = node_argo_submit_result(( 900,  300))

    # Tool router shared
    router      = node_argo_tool_router((1500,  300))

    edges = [
        # ---- Orchestrator ----
        make_edge(source_node=orch_enq, source_output_name="task_info",
                  target_node=orch_next, target_input_name="task_id"),
        make_edge(source_node=orch_next, source_output_name="step",
                  target_node=orch_llm, target_input_name="input_value"),
        make_edge(source_node=orch_llm, source_output_name="text_output",
                  target_node=orch_submit, target_input_name="response"),
        make_edge(source_node=orch_next, source_output_name="step",
                  target_node=orch_submit, target_input_name="task_id"),
        make_edge(source_node=orch_submit, source_output_name="continue_out",
                  target_node=orch_next, target_input_name="task_id"),
        # delegate -> wait_tasks loops back to next_step once subtask completes
        make_edge(source_node=orch_submit, source_output_name="wait_tasks_out",
                  target_node=orch_next, target_input_name="task_id"),

        # ---- Executor ----
        make_edge(source_node=exec_next, source_output_name="step",
                  target_node=exec_llm, target_input_name="input_value"),
        make_edge(source_node=exec_llm, source_output_name="text_output",
                  target_node=exec_submit, target_input_name="response"),
        make_edge(source_node=exec_next, source_output_name="step",
                  target_node=exec_submit, target_input_name="task_id"),
        make_edge(source_node=exec_submit, source_output_name="continue_out",
                  target_node=exec_next, target_input_name="task_id"),
        # Executor invokes tools
        make_edge(source_node=exec_submit, source_output_name="invoke_tool_out",
                  target_node=router, target_input_name="invoke_payload"),
    ]

    flow = make_flow(
        name="ARGO Multi Agent",
        description=(
            "Orchestrator + executor pattern. The orchestrator delegates via "
            "fn_submit_result(action='delegate'); ARGO creates a subtask, marks "
            "the orchestrator task as 'waiting', and returns wait_tasks. When "
            "the executor finishes, the parent task is automatically returned to "
            "'pending' and the wait_tasks loop resumes Next Step."
        ),
        nodes=[orch_enq, orch_next, orch_llm, orch_submit,
               exec_next, exec_llm, exec_submit, router],
        edges=edges,
    )
    write_flow(flow, OUT / "multi_agent_flow.json")
    print("wrote multi_agent_flow.json")


# ---------------------------------------------------------------------------
# Flow 3: embedder
# ---------------------------------------------------------------------------
def build_embedder_flow() -> None:
    embedder = node_argo_embedder((0, 0))

    flow = make_flow(
        name="ARGO Embedder",
        description=(
            "Re-embed rows whose embedding is NULL or whose dimension does not "
            "match the active embedding model. Trigger after rotate_embedding_model "
            "or on a schedule. Reads v_reembedding_targets and writes back via "
            "fn_set_tool_embedding / fn_set_memory_embedding."
        ),
        nodes=[embedder],
        edges=[],
        icon="RefreshCw",
    )
    write_flow(flow, OUT / "embedder_flow.json")
    print("wrote embedder_flow.json")


if __name__ == "__main__":
    build_single_agent_flow()
    build_multi_agent_flow()
    build_embedder_flow()
