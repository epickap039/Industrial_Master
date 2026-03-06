import sqlite3
import hashlib

# Apuntando a la base de datos local que está usando FastAPI
DB_PATH = "industrial_manager.db" 

print("========================================")
print("   CREACIÓN DE ADMINISTRADOR (SQLite)   ")
print("========================================")

username = input("Ingresa el username para el Admin: ")
password = input("Ingresa la contraseña para el Admin: ")

# Encriptar contraseña en SHA-256
password_hash = hashlib.sha256(password.encode()).hexdigest()

try:
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    # Asegurarnos de que la tabla exista
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS Tbl_Usuarios (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            rol TEXT NOT NULL
        )
    ''')

    # Insertar el usuario
    cursor.execute('''
        INSERT INTO Tbl_Usuarios (username, password_hash, rol)
        VALUES (?, ?, 'ADMIN')
    ''', (username, password_hash))

    conn.commit()
    print(f"\n✅ ¡Éxito! El usuario '{username}' ha sido guardado en la base de datos LOCAL (industrial_manager.db).")
    
except sqlite3.IntegrityError:
    print(f"\n[X] Error: El usuario '{username}' ya existe en la base local.")
except Exception as e:
    print(f"\n[X] Error crítico: {e}")
finally:
    if 'conn' in locals():
        conn.close()