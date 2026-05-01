"""ARGOEmbedder: re-generate embeddings for rows whose vectors don't match
the active embedding model.

The embedder polls argo_public.v_reembedding_targets, asks an Ollama-compatible
embedding endpoint for new vectors, and writes them back via
fn_set_tool_embedding / fn_set_memory_embedding.

Typical usage: trigger this flow manually (or on a schedule) after calling
argo_public.rotate_embedding_model(...).
"""

from __future__ import annotations

import os
from typing import Any

import requests

from langflow.custom import Component
from langflow.io import IntInput, Output
from langflow.schema import Data

from ._argo_db import call_function_all, execute, vector_literal


class ARGOEmbedder(Component):
    display_name = "ARGO Embedder"
    description = (
        "Re-embed rows where embedding is NULL or the dimension does not match "
        "the active embedding model. Reads v_reembedding_targets and writes back "
        "via fn_set_tool_embedding / fn_set_memory_embedding."
    )
    icon = "refresh-cw"
    name = "ARGOEmbedder"

    inputs = [
        IntInput(
            name="batch_size",
            display_name="Batch Size",
            info="How many rows to process per run.",
            value=20,
            required=False,
        ),
    ]

    outputs = [
        Output(
            name="report",
            display_name="Report",
            method="run_embedder",
        ),
    ]

    # ---------------------------------------------------------------------
    def run_embedder(self) -> Data:
        batch_size = int(self.batch_size or 20)

        active = call_function_all(
            "SELECT model_name, dimensions, endpoint "
            "FROM argo_private.embedding_config WHERE is_active = TRUE LIMIT 1"
        )
        if not active:
            self.status = "no active embedding_config"
            return Data(data={"processed": 0, "reason": "no active embedding_config"})

        cfg = active[0]
        model_name = cfg["model_name"]
        dimensions = int(cfg["dimensions"])
        endpoint   = cfg["endpoint"].rstrip("/")

        targets = call_function_all(
            "SELECT source, row_id, content FROM argo_public.v_reembedding_targets LIMIT %s",
            (batch_size,),
        )
        if not targets:
            self.status = "0 targets"
            return Data(data={"processed": 0, "model": model_name, "dimensions": dimensions})

        ok = 0
        errors: list[dict[str, Any]] = []

        for t in targets:
            try:
                vector = self._embed(endpoint, model_name, t["content"])
            except Exception as exc:  # noqa: BLE001
                errors.append({"row": t, "error": str(exc)})
                continue

            if len(vector) != dimensions:
                errors.append({
                    "row": t,
                    "error": f"dim mismatch: got {len(vector)} expected {dimensions}",
                })
                continue

            try:
                if t["source"] == "tool_registry":
                    execute(
                        "SELECT argo_public.fn_set_tool_embedding(%s, %s::vector, %s)",
                        (int(t["row_id"]), vector_literal(vector), dimensions),
                    )
                elif t["source"] == "memory":
                    execute(
                        "SELECT argo_public.fn_set_memory_embedding(%s, %s::vector, %s)",
                        (int(t["row_id"]), vector_literal(vector), dimensions),
                    )
                else:
                    errors.append({"row": t, "error": f"unknown source: {t['source']}"})
                    continue
                ok += 1
            except Exception as exc:  # noqa: BLE001
                errors.append({"row": t, "error": str(exc)})

        self.status = f"embedded {ok} / {len(targets)} (errors: {len(errors)})"
        return Data(data={
            "processed": ok,
            "attempted": len(targets),
            "errors": errors,
            "model": model_name,
            "dimensions": dimensions,
        })

    # ---------------------------------------------------------------------
    def _embed(self, endpoint: str, model: str, text: str) -> list[float]:
        """Call an Ollama-compatible /api/embeddings endpoint."""
        url = f"{endpoint}/api/embeddings"
        timeout = int(os.getenv("ARGO_EMBED_TIMEOUT", "30"))
        resp = requests.post(
            url,
            json={"model": model, "prompt": text or ""},
            timeout=timeout,
        )
        resp.raise_for_status()
        body = resp.json()
        vector = body.get("embedding")
        if not isinstance(vector, list):
            raise RuntimeError(f"embedding endpoint returned no 'embedding': {body!r}")
        return [float(x) for x in vector]
