import hashlib
from database import get_db_connection


def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest()

def init_auth_db():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Recrear tabla para ajustar nombres de columnas según fase 3
        cursor.execute("""
            IF OBJECT_ID('Tbl_Usuarios', 'U') IS NOT NULL DROP TABLE Tbl_Usuarios;
            CREATE TABLE Tbl_Usuarios (
                id INT PRIMARY KEY IDENTITY(1,1),
                username NVARCHAR(50) UNIQUE NOT NULL,
                password_hash NVARCHAR(255) NOT NULL,
                rol NVARCHAR(20) DEFAULT 'USER'
            )
        """)
        conn.commit()
        
        users_to_seed = [
            ("jaes_admin", "Industrial.2026", "ADMIN"),
            ("ing_01", "Ing.2026", "USER"),
            ("ing_02", "Ing.2026", "USER"),
        ]
        
        for user, password, role in users_to_seed:
            hashed = hash_password(password)
            cursor.execute("INSERT INTO Tbl_Usuarios (username, password_hash, rol) VALUES (?, ?, ?)", (user, hashed, role))
        
        conn.commit()
    finally:
        conn.close()