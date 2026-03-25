"""Resolución del actor humano para auditoría: JWT Bearer > X-Usuario > fallback."""
from __future__ import annotations

from typing import Optional

from jwt_tokens import subject_from_authorization


def resolve_actor_user(
    authorization: Optional[str] = None,
    x_usuario: Optional[str] = None,
    max_len: int = 100,
) -> str:
    sub = subject_from_authorization(authorization)
    if sub:
        return sub[:max_len]
    u = (x_usuario or "").strip()
    if u:
        return u[:max_len]
    return "Sistema"
