import hashlib

from database import get_db_connection


def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest()


def init_auth_db():
    """No elimina Tbl_Usuarios. Solo inserta usuarios semilla si la tabla está vacía."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT COUNT(*) FROM dbo.Tbl_Usuarios")
        n = int(cursor.fetchone()[0] or 0)
        if n > 0:
            return

        users_to_seed = [
            ("jaes_admin", "Industrial.2026", "ADMIN"),
            ("ing_01", "Ing.2026", "USER"),
            ("ing_02", "Ing.2026", "USER"),
        ]

        for user, password, role in users_to_seed:
            hashed = hash_password(password)
            cursor.execute(
                "INSERT INTO dbo.Tbl_Usuarios (username, password_hash, rol) VALUES (?, ?, ?)",
                (user, hashed, role),
            )

        conn.commit()
    except Exception as e:
        print(f"init_auth_db (Tbl_Usuarios no sembrada o tabla ausente): {e}")
    finally:
        conn.close()
