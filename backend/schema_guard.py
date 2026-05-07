"""Comprobaciones de esquema sin DDL en runtime (cuando IM_ALLOW_RUNTIME_DDL=0)."""
from __future__ import annotations

from typing import Any


def table_exists(cursor: Any, table: str, schema: str = "dbo") -> bool:
    cursor.execute(
        """
        SELECT 1
        FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        """,
        (schema, table),
    )
    return cursor.fetchone() is not None


def column_exists(cursor: Any, table: str, column: str, schema: str = "dbo") -> bool:
    cursor.execute(
        """
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?
        """,
        (schema, table, column),
    )
    return cursor.fetchone() is not None
