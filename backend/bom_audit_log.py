from typing import Optional


def registrar_log(
    cursor,
    id_revision: int,
    accion: str,
    detalle: str,
    motivo: str = "",
    usuario: Optional[str] = None,
):
    """Inserta un registro en Tbl_Log_Cambios_Ingenieria. Llamar dentro de una transacción abierta."""
    u = ((usuario or "").strip() or "Operador_Desconocido")[:100]
    try:
        cursor.execute(
            "INSERT INTO Tbl_Log_Cambios_Ingenieria "
            "(ID_Revision, Usuario, Accion, Detalle_Cambio, Motivo) VALUES (?, ?, ?, ?, ?)",
            (id_revision, u, accion, detalle[:500], motivo[:300] if motivo else ""),
        )
    except Exception:
        pass  # No interrumpir operación principal si falla el log