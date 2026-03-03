import pyodbc
import hashlib
import sys

# La misma cadena de conexión usada en server.py
CONNECTION_STRING = "Driver={SQL Server};Server=DESKTOP-5M2IQ5S;Database=master;Trusted_Connection=yes;"

def hash_password(password: str) -> str:
    """Hashea la clave usando SHA-256."""
    return hashlib.sha256(password.encode()).hexdigest()

def crear_admin():
    print("========================================")
    print("   CREACIÓN DE ADMINISTRADOR MAESTRO   ")
    print("========================================\n")
    
    username = input("Ingresa el username para el Admin: ").strip()
    if not username:
        print("El username no puede estar vacío.")
        return
        
    password = input("Ingresa la contraseña para el Admin: ").strip()
    if not password:
        print("La contraseña no puede estar vacía.")
        return
        
    try:
        print("\nConectando a SQL Server...")
        conn = pyodbc.connect(CONNECTION_STRING)
        cursor = conn.cursor()
        
        # Validar si el usuario ya existe
        cursor.execute("SELECT id FROM Tbl_Usuarios WHERE username = ?", (username,))
        usuario_existente = cursor.fetchone()
        
        if usuario_existente:
            print(f"El usuario '{username}' ya existe. Vamos a actualizar su contraseña y rol a ADMIN.")
            hashed = hash_password(password)
            cursor.execute("UPDATE Tbl_Usuarios SET password_hash = ?, rol = 'ADMIN' WHERE username = ?", (hashed, username))
        else:
            print(f"Creando nuevo usuario: {username}")
            hashed = hash_password(password)
            cursor.execute("INSERT INTO Tbl_Usuarios (username, password_hash, rol) VALUES (?, ?, 'ADMIN')", (username, hashed))
            
        conn.commit()
        print("\n[OK] ¡Usuario Guardado Correctamente!")
        print(f"Username : {username}")
        print(f"Role     : ADMIN")
        print(f"Hash     : {hashed[:15]}...")
        
    except Exception as e:
        print(f"\n[X] Error crítico en la Base de Datos: {e}")
    finally:
        try:
            conn.close()
        except:
            pass
            
if __name__ == "__main__":
    crear_admin()
