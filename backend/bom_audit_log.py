def registrar_log(cursor, id_revision: int, accion: str, detalle: str, motivo: str = ""):
    """Inserta un registro en Tbl_Log_Cambios_Ingenieria. Llamar dentro de una transacción abierta."""
    try:
        cursor.execute(
            "INSERT INTO Tbl_Log_Cambios_Ingenieria (ID_Revision, Accion, Detalle_Cambio, Motivo) VALUES (?, ?, ?, ?)",
            (id_revision, accion, detalle[:500], motivo[:300] if motivo else "")
        )
    except Exception:
        pass  # No interrumpir operación principal si falla el log