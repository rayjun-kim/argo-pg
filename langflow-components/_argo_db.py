"""Shared database helpers for ARGO components.

Connection settings come from environment variables (set in the Helm chart):
    ARGO_PG_HOST, ARGO_PG_PORT, ARGO_PG_DB, ARGO_PG_USER, ARGO_PG_PASSWORD

The default user is `argo_langflow`, which has the privileged role grants
required to call run_agent / fn_next_step / fn_submit_result on behalf of
any agent.
"""

from __future__ import annotations

import json
import os
from contextlib import contextmanager
from typing import Any

import psycopg2
import psycopg2.extras


def _conn_kwargs() -> dict[str, Any]:
    return {
        "host":     os.getenv("ARGO_PG_HOST", "argo-pg-rw"),
        "port":     int(os.getenv("ARGO_PG_PORT", "5432")),
        "dbname":   os.getenv("ARGO_PG_DB",   "argo"),
        "user":     os.getenv("ARGO_PG_USER", "argo_langflow"),
        "password": os.getenv("ARGO_PG_PASSWORD", ""),
        "connect_timeout": int(os.getenv("ARGO_PG_TIMEOUT", "5")),
    }


@contextmanager
def get_conn():
    """Context manager that yields a psycopg2 connection."""
    conn = psycopg2.connect(**_conn_kwargs())
    try:
        yield conn
    finally:
        conn.close()


def call_function(sql: str, params: tuple = ()) -> Any:
    """Execute a single SELECT calling an ARGO function. Returns the first column of the first row."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            row = cur.fetchone()
            conn.commit()
            return row[0] if row else None


def call_function_all(sql: str, params: tuple = ()) -> list[dict[str, Any]]:
    """Execute a SELECT and return all rows as dicts."""
    with get_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            rows = cur.fetchall()
            conn.commit()
            return [dict(r) for r in rows]


def execute(sql: str, params: tuple = ()) -> None:
    """Execute a non-returning statement."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
        conn.commit()


def vector_literal(embedding: list[float]) -> str:
    """Format a Python list as a pgvector text literal: '[1.0,2.0,...]'"""
    return "[" + ",".join(f"{x:.8f}" for x in embedding) + "]"


def to_json(value: Any) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value)
